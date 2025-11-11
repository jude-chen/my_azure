#!/usr/bin/env bash

# DISCLAIMER:
# The information contained in this script and any accompanying materials (including, but not limited to, sample code) is provided “AS IS” and “WITH ALL FAULTS.” Microsoft makes NO GUARANTEES OR WARRANTIES OF ANY KIND, WHETHER EXPRESS OR IMPLIED, including but not limited to implied warranties of merchantability or fitness for a particular purpose.
#
# The entire risk arising out of the use or performance of the script remains with you. In no event shall Microsoft, its authors, or anyone else involved in the creation, production, or delivery of the script be liable for any damages whatsoever (including, without limitation, damages for loss of business profits, business interruption, loss of business information, or other pecuniary loss) arising out of the use of or inability to use the script, even if Microsoft has been advised of the possibility of such damages.

# Tag Orphan/Idle Azure Resources Across All Subscriptions
# Author: (your team)
# Requires: Azure CLI 2.50+ and access to all target subscriptions

set -o errexit
set -o pipefail
set -o nounset

########################
# Configuration
########################
# Tag to write (key/value). Adjust to your org’s standard, e.g., "CleanupCandidate" / "true".
TAG_KEY="${TAG_KEY:-CleanupCandidate}"
TAG_PREFIX="${TAG_PREFIX:-orphan}"  # value becomes: orphan:<reason>, e.g., orphan:unattached-disk
APPLY_TAGS="${APPLY_TAGS:-false}"   # set to "true" to actually write tags
# Optional: limit to a management group scope by uncommenting and setting MG_ID
# MG_ID="my-mg-id"

# Colors for output
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log() { echo -e "${YELLOW}[INFO]${NC} $*"; }
ok()  { echo -e "${GREEN}[OK]${NC}   $*"; }
warn(){ echo -e "${RED}[WARN]${NC} $*"; }

tag_resource () {
  local id="$1"
  local reason="$2"
  local value="${TAG_PREFIX}:${reason}"

  if [[ "${APPLY_TAGS}" == "true" ]]; then
    if az resource update --ids "$id" --set "tags.${TAG_KEY}=${value}" --only-show-errors >/dev/null; then
      ok "Tagged: ${id}  (${TAG_KEY}=${value})"
    else
      warn "Failed to tag: ${id} — check permissions/provider support"
    fi
  else
    ok "DRY-RUN would tag: ${id}  (${TAG_KEY}=${value})"
  fi
}

exists_resource () {
  # returns 0 if resource exists, else non-zero
  local rid="$1"
  az resource show --ids "$rid" --only-show-errors >/dev/null 2>&1
}

########################
# Discovery Functions
########################

find_stopped_vms () {
  # VM powerState requires --show-details
  az vm list -d --query "[?powerState!='VM deallocated' && powerState!='VM running'].id" -o tsv
}

find_deallocated_vms () {
  az vm list -d --query "[?powerState=='VM deallocated'].id" -o tsv
}

find_unattached_disks () {
  az disk list --query "[?(managedBy == '' || managedBy == null) && contains(to_string(tags), 'kubernetes.io-created-for-pvc') == false && contains(to_string(tags), 'ASR-ReplicaDisk') == false && contains(to_string(tags), 'asrseeddisk') == false && contains(to_string(tags), 'RSVaultBackup') == false && diskState != 'ActiveSAS'].id" -o tsv
}

find_unattached_public_ips () {
  # public IPs not attached to a NIC or LB
  az network public-ip list --query "[?ipConfiguration==null && natGateway==null && publicIPAllocationMethod == 'Static'].id" -o tsv
}

find_unattached_nat_gateways () {
  # NAT Gateways with no subnets attached
  az network nat gateway list --query "[?subnets==null || length(subnets)==\`0\`].id" -o tsv
}

find_idle_expressroute_circuits () {
  # Heuristic: circuits with no peerings
  az network express-route list --query "[?peerings==null || length(peerings)==\`0\` || serviceProviderProvisioningState=='NotProvisioned'].id" -o tsv || true
}

find_idle_private_dns_zones () {
  # Zones with only default records and no VNet links
  # numberOfRecordSets includes SOA + NS (usually 2); use <=2 as "default-only"
  local zones
  local link_count
  zones=$(az network private-dns zone list --query "[?numberOfRecordSets<=\`2\`].[name,resourceGroup,id]" -o tsv)
  while IFS=$'\t' read -r zname zrg zid; do
    [[ -z "${zid}" ]] && continue
    # Check for VNet links
    link_count=$(az network private-dns link vnet list -g "${zrg}" -z "${zname}" --query "length(@)" -o tsv || echo "0")
    if [[ "${link_count}" == "0" ]]; then
      echo "${zid}"
    fi
  done <<< "${zones}"
}

find_idle_private_endpoints () {
  # Idle if no approved private link service connections
  # (Either zero connections, or all connections not 'Approved')
  local eps
  local approved
  eps=$(az network private-endpoint list -o tsv --query "[].[id,name,privateLinkServiceConnections]")
  while IFS=$'\t' read -r id name conns; do
    [[ -z "${id}" ]] && continue
    # If conns is '[]' (empty), mark idle
    if [[ "${conns}" == "[]" ]]; then
      echo "${id}"
      continue
    fi
    # Otherwise, check if there is any Approved connection
    approved=$(az network private-endpoint show --ids "${id}" \
      --query "contains(privateLinkServiceConnections[].privateLinkServiceConnectionState.status, 'Approved')" -o tsv 2>/dev/null || echo "false")
    if [[ "${approved}" != "true" ]]; then
      echo "${id}"
    fi
  done <<< "${eps}"
}

find_orphan_backups () {
  # Protected items whose source resource no longer exists
  # Iterate all Recovery Services vaults and test each item’s sourceResourceId
  local vaults v
  local items
  local src
  vaults=$(az backup vault list --query "[].{name:name,rg:resourceGroup}" -o tsv || true)
  while IFS=$'\t' read -r vname vrg; do
    [[ -z "${vname}" ]] && continue
    # List items; include deleted if you want to surface soft-deleted as well
    items=$(az backup item list --vault-name "${vname}" -g "${vrg}" --query "[].id" -o tsv || true)
    while IFS= read -r item_id; do
      [[ -z "${item_id}" ]] && continue
      # Fetch sourceResourceId via REST (CLI 'show' varies by workload)
      # Using generic az resource show to retrieve properties
      src=$(az resource show --ids "${item_id}" --query "properties.sourceResourceId" -o tsv 2>/dev/null || echo "")
      if [[ -z "${src}" ]]; then
        # No source recorded -> treat as orphan candidate
        echo "${item_id}"
      else
        if ! exists_resource "${src}"; then
          echo "${item_id}"
        fi
      fi
    done <<< "${items}"
  done <<< "${vaults}"
}

find_idle_sql_pools () {
  # Synapse Dedicated SQL pools that are Paused
  # Also tag Azure SQL elastic pools with 0 databases as "idle" candidates
  # Synapse workspaces in this subscription:
  local wslist
  wslist=$(az synapse workspace list --query "[].name" -o tsv 2>/dev/null || true)
  for ws in ${wslist}; do
    az synapse sql pool list --workspace-name "${ws}" \
      --query "[?status=='Paused'].id" -o tsv 2>/dev/null || true
  done

  # Azure SQL elastic pools with zero DBs
  az sql elastic-pool list --query "[?databaseCount==\`0\`].id" -o tsv 2>/dev/null || true
}

########################
# Main
########################

# Iterate subscriptions (optionally constrain by MG)
subs_query="[?state=='Enabled'].id"
if [[ -n "${MG_ID:-}" ]]; then
  log "Enumerating subscriptions in management group ${MG_ID}"
  mapfile -t SUBS < <(az account management-group subscription list --name "${MG_ID}" --query "[].name" -o tsv)
else
  mapfile -t SUBS < <(az account list --query "${subs_query}" -o tsv)
fi

log "Found ${#SUBS[@]} enabled subscription(s). APPLY_TAGS=${APPLY_TAGS}, TAG=${TAG_KEY}"

for sub in "${SUBS[@]}"; do
  echo
  log "=== Subscription: ${sub} ==="
  az account set --subscription "${sub}"

  # 1) VMs stopped
  while IFS= read -r id; do [[ -n "$id" ]] && tag_resource "$id" "vm-stopped"; done < <(find_stopped_vms)

  # 2) VMs deallocated
  while IFS= read -r id; do [[ -n "$id" ]] && tag_resource "$id" "vm-deallocated"; done < <(find_deallocated_vms)

  # 3) Unattached managed disks
  while IFS= read -r id; do [[ -n "$id" ]] && tag_resource "$id" "unattached-disk"; done < <(find_unattached_disks)

  # 4) Orphan backups (protected items)
  while IFS= read -r id; do [[ -n "$id" ]] && tag_resource "$id" "orphan-backup"; done < <(find_orphan_backups)

  # 5) Unattached Public IPs
  while IFS= read -r id; do [[ -n "$id" ]] && tag_resource "$id" "unattached-publicip"; done < <(find_unattached_public_ips)

  # 6) Unattached NAT Gateways
  while IFS= read -r id; do [[ -n "$id" ]] && tag_resource "$id" "unattached-natgw"; done < <(find_unattached_nat_gateways)

  # 7) Idle ExpressRoute circuits (no peerings)
  while IFS= read -r id; do [[ -n "$id" ]] && tag_resource "$id" "idle-expressroute"; done < <(find_idle_expressroute_circuits)

  # 8) Idle Private DNS zones (no VNet links & default-only records)
  while IFS= read -r id; do [[ -n "$id" ]] && tag_resource "$id" "idle-privatedns-zone"; done < <(find_idle_private_dns_zones)

  # 9) Idle Private Endpoints
  while IFS= read -r id; do [[ -n "$id" ]] && tag_resource "$id" "idle-private-endpoint"; done < <(find_idle_private_endpoints)

  # 10) Idle SQL Pools (Synapse paused, SQL elastic pools with 0 DBs)
  while IFS= read -r id; do [[ -n "$id" ]] && tag_resource "$id" "idle-sql-pool"; done < <(find_idle_sql_pools)

done

echo
ok "Completed. Set APPLY_TAGS=true to persist tags (current: ${APPLY_TAGS})."
echo "Tip: restrict scope by Management Group with MG_ID, or by AZURE_DEFAULTS_* envs."

# Usage Examples:
#   Dry Run (Preview)
#   ./tag-orphan-resources.sh
#
#   Apply Tags
#   TAG_KEY="CleanupCandidate" TAG_PREFIX="orphan" APPLY_TAGS=true ./tag-orphan-resources.sh
#
#   Limit scope to a management group (optional):
#   MG_ID="contoso-mg" APPLY_TAGS=true ./tag-orphan-resources.sh