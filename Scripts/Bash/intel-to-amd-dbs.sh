#!/usr/bin/env bash

# DISCLAIMER:
# The information contained in this script and any accompanying materials (including, but not limited to, sample code) is provided “AS IS” and “WITH ALL FAULTS.” Microsoft makes NO GUARANTEES OR WARRANTIES OF ANY KIND, WHETHER EXPRESS OR IMPLIED, including but not limited to implied warranties of merchantability or fitness for a particular purpose.
#
# The entire risk arising out of the use or performance of the script remains with you. In no event shall Microsoft, its authors, or anyone else involved in the creation, production, or delivery of the script be liable for any damages whatsoever (including, without limitation, damages for loss of business profits, business interruption, loss of business information, or other pecuniary loss) arising out of the use of or inability to use the script, even if Microsoft has been advised of the possibility of such damages.

# CSV-driven conversion of Azure Database for MySQL/PostgreSQL Flexible Servers from Intel to AMD (same size)
# - Reads CSV: subscriptionId,resourceGroup,serverName
# - Auto-detects service (postgres | mysql) per row
# - Replica-aware: updates replicas first, then primary
# - Cross-subscription replicas supported
# - Dry-run by default. Set APPLY=1 to execute.
# Requirements: az CLI, jq
# Usage:
#   INPUT=./targets.csv bash csv-intel-to-amd-flexibleserver.sh
#   APPLY=1 START_STOPPED=1 STRICT=0 INPUT=./targets.csv bash csv-intel-to-amd-flexibleserver.sh

set -euo pipefail

INPUT=${INPUT:-"./targets.csv"} # CSV: subscriptionId,resourceGroup,serverName
APPLY=${APPLY:-0}               # 0=dry-run, 1=apply
START_STOPPED=${START_STOPPED:-0} # 1=start stopped server for change then stop back
STRICT=${STRICT:-0}             # 1=only touch servers present in CSV; 0=also include their replicas (recommended)
LOG=${LOG:-"./db-intel-to-amd-$(date +%F_%H%M%S).csv"}

if [[ ! -f "$INPUT" ]]; then
  echo "Input CSV not found: $INPUT" >&2
  exit 1
fi
echo "subscription,service,resourceGroup,server,role,primaryId,location,tier,currentSku,vCores,targetSku,action,result,notes" > "$LOG"

# ---------- Helpers ----------
is_amd_sku() { [[ "$1" =~ _[DE][0-9]*a[^_]*_v[0-9]+$ ]]; }   # Standard_D8as_v5 / Standard_D8ads_v5 / Standard_E16as_v5
get_family_letter() { [[ "$1" =~ Standard_([DE]) ]] && echo "${BASH_REMATCH[1]}"; }

vcores_from_json() { jq -r '.sku.capacity // .properties.vCores // empty' <<<"$1"; }

detect_service() {
  # Determine if name in RG is postgres or mysql flexible server
  local sub="$1" rg="$2" name="$3"
  az account set -s "$sub" >/dev/null
  if az postgres flexible-server show -g "$rg" -n "$name" -o none 2>/dev/null; then
    echo "postgres"; return 0
  fi
  if az mysql flexible-server show -g "$rg" -n "$name" -o none 2>/dev/null; then
    echo "mysql"; return 0
  fi
  echo "" # unknown
}

show_server_json() {
  local service="$1" rg="$2" name="$3"
  az "$service" flexible-server show -g "$rg" -n "$name" -o json
}

list_replicas_json() {
  local service="$1" rg="$2" name="$3"
  az "$service" flexible-server replica list -g "$rg" -n "$name" -o json
}

sub_from_id() { [[ "$1" =~ /subscriptions/([^/]+)/ ]] && echo "${BASH_REMATCH[1]}"; }
rg_from_id()  { [[ "$1" =~ /resourceGroups/([^/]+)/ ]] && echo "${BASH_REMATCH[1]}"; }
name_from_id(){ [[ "$1" =~ /flexibleServers/([^/]+)$ ]] && echo "${BASH_REMATCH[1]}"; }

find_target_sku() {
  # Args: service, location, tier, family(D|E), vcores
  local service="$1" loc="$2" tier="$3" family="$4" vcores="$5"
  local skus
  if [[ "$service" == "postgres" ]]; then
    skus="$(az postgres flexible-server list-skus -l "$loc" -o json)"
  else
    skus="$(az mysql flexible-server list-skus -l "$loc" -o json)"
  fi
  echo "$skus" | jq -r --arg tier "$tier" --arg family "$family" --argjson v "$vcores" '
    .[] | select(.tier == $tier)
    | select(.name | test("Standard_"+$family+".*a.*_v[0-9]+"))
    | select((
        (.capabilities // [])
        | map(select(.name=="vCores") | .value)[0]
        // .size // .capacity // empty
      ) | tonumber? == $v)
    | .name
  ' | head -n 1
}

update_one() {
  # Args: sub, service, rg, name, role, primaryId
  local sub="$1" service="$2" rg="$3" name="$4" role="$5" primaryId="$6"

  az account set -s "$sub" >/dev/null

  local js sku tier vcores loc state family target result notes
  js="$(show_server_json "$service" "$rg" "$name")" || {
    echo "$sub,$service,$rg,$name,$role,$primaryId,,,,,,none,ERROR,Not found" >> "$LOG"
    return 0
  }
  sku="$(jq -r '.sku.name' <<<"$js")"
  tier="$(jq -r '.sku.tier' <<<"$js")"
  vcores="$(vcores_from_json "$js")"
  loc="$(jq -r '.location' <<<"$js")"
  state="$(jq -r '.state // .properties.state // "Unknown"' <<<"$js")"
  family="$(get_family_letter "$sku")"

  if [[ "$service" == "postgres" && "$tier" =~ [Hh]yperscale ]]; then
    echo "$sub,$service,$rg,$name,$role,$primaryId,$loc,$tier,$sku,$vcores,,skip,Skipped,Hyperscale (Citus)" >> "$LOG"
    return 0
  fi
  if [[ -z "$sku" || -z "$tier" || -z "$vcores" || -z "$family" ]]; then
    echo "$sub,$service,$rg,$name,$role,$primaryId,$loc,$tier,$sku,$vcores,,none,ERROR,Missing sku/tier/vCores/family" >> "$LOG"
    return 0
  fi
  if is_amd_sku "$sku"; then
    echo "$sub,$service,$rg,$name,$role,$primaryId,$loc,$tier,$sku,$vcores,,noop,Already AMD," >> "$LOG"
    return 0
  fi

  target="$(find_target_sku "$service" "$loc" "$tier" "$family" "$vcores" || true)"
  if [[ -z "$target" ]]; then
    echo "$sub,$service,$rg,$name,$role,$primaryId,$loc,$tier,$sku,$vcores,,skip,NoMatch,No AMD match in $loc for $tier $family $vcores vCores" >> "$LOG"
    return 0
  fi

  if [[ "$APPLY" -eq 1 ]]; then
    local prev="$state"
    if [[ "$state" == "Stopped" && "$START_STOPPED" -eq 1 ]]; then
      az "$service" flexible-server start -g "$rg" -n "$name" >/dev/null || true
    elif [[ "$state" == "Stopped" && "$START_STOPPED" -ne 1 ]]; then
      echo "$sub,$service,$rg,$name,$role,$primaryId,$loc,$tier,$sku,$vcores,$target,skip,Skipped (stopped),Set START_STOPPED=1 to auto-start" >> "$LOG"
      return 0
    fi

    if az "$service" flexible-server update -g "$rg" -n "$name" --sku-name "$target" >/dev/null; then
      result="UPDATED"
      notes=""
    else
      result="ERROR"
      notes="Update failed"
    fi
    if [[ "$START_STOPPED" -eq 1 && "$prev" == "Stopped" ]]; then
      az "$service" flexible-server stop -g "$rg" -n "$name" >/dev/null || true
    fi
  else
    result="DRY-RUN"; notes=""
  fi

  echo "$sub,$service,$rg,$name,$role,$primaryId,$loc,$tier,$sku,$vcores,$target,update --sku-name $target,$result,$notes" >> "$LOG"
  echo "[$service][$role] $rg/$name ($loc): $sku → $target [$tier, ${vcores} vCores] : $result"
}

process_primary_with_replicas() {
  # Args: sub, rg, name
  local psub="$1" prg="$2" pname="$3"

  # detect service
  local svc; svc="$(detect_service "$psub" "$prg" "$pname")"
  if [[ -z "$svc" ]]; then
    echo "$psub,,${prg},${pname},Unknown,,,,,,none,ERROR,Service not found (neither Postgres nor MySQL)" >> "$LOG"
    return 0
  fi

  # list replicas
  az account set -s "$psub" >/dev/null
  local reps; reps="$(list_replicas_json "$svc" "$prg" "$pname" || echo '[]')"
  local pid; pid="$(az "$svc" flexible-server show -g "$prg" -n "$pname" --query id -o tsv 2>/dev/null || true)"

  # Update replicas first
  local rid rsub rrg rname
  for rid in $(jq -r '.[].id' <<<"$reps"); do
    rsub="$(sub_from_id "$rid")"
    rrg="$(rg_from_id "$rid")"
    rname="$(name_from_id "$rid")"

    if [[ -z "$rsub" || -z "$rrg" || -z "$rname" ]]; then
      echo "$psub,$svc,$prg,$pname,Primary,$pid,,,,,,WARN,WARN,Replica metadata incomplete: $rid" >> "$LOG"
      continue
    fi

    if [[ "$STRICT" -eq 1 ]]; then
      # Only process replicas if they are explicitly present in the CSV input
      if ! grep -qE "^[^,]*${rsub}[^,]*,${rrg},${rname}$" <(tail -n +2 "$INPUT"); then
        echo "$rsub,$svc,$rrg,$rname,Replica,$pid,,,,,,skip,OutOfScope,STRICT=1 (replica not in CSV)" >> "$LOG"
        continue
      fi
    fi

    update_one "$rsub" "$svc" "$rrg" "$rname" "Replica" "$pid"
  done

  # Now update the primary
  update_one "$psub" "$svc" "$prg" "$pname" "Primary" "$pid"
}

# ---------- Main: read CSV ----------
# Skip header; accept commas inside quotes by using simple CSV read with awk fallback if needed.
# For robustness, use python-like parsing via jq? Stay in bash: assume no commas in values.
tail -n +2 "$INPUT" | while IFS=, read -r SUB RG NAME; do
  # Trim whitespace and possible surrounding quotes
  SUB="${SUB//\"/}"; RG="${RG//\"/}"; NAME="${NAME//\"/}"
  SUB="$(echo "$SUB" | xargs)"; RG="$(echo "$RG" | xargs)"; NAME="$(echo "$NAME" | xargs)"
  [[ -z "$SUB" || -z "$RG" || -z "$NAME" ]] && continue
  process_primary_with_replicas "$SUB" "$RG" "$NAME"
done

echo "Done. CSV log: $LOG"