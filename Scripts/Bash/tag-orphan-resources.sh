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
# Tag to write (key/value). Adjust to your org's standard, e.g., "CleanupCandidate" / "true".
TAG_KEY="${TAG_KEY:-CleanupCandidate}"
TAG_PREFIX="${TAG_PREFIX:-orphan}"  # value becomes: orphan:<reason>, e.g., orphan:unattached-disk
APPLY_TAGS="${APPLY_TAGS:-false}"   # set to "true" to actually write tags
# Optional: limit to a management group scope by uncommenting and setting MG_ID
# MG_ID="my-mg-id"
# Optional: exclude specific resource groups (comma-separated list)
EXCLUDE_RGS="${EXCLUDE_RGS:-}"
# Optional: error log file path
ERROR_LOG="${ERROR_LOG:-errors.log}"

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

is_rg_excluded () {
  # Check if a resource group name should be excluded
  local rg_name="$1"
  [[ -z "${EXCLUDE_RGS}" ]] && return 1  # No exclusions defined

  # Split comma-separated list and check each pattern
  IFS=',' read -ra EXCLUDE_LIST <<< "${EXCLUDE_RGS}"
  for pattern in "${EXCLUDE_LIST[@]}"; do
    pattern=$(echo "${pattern}" | xargs)  # Trim whitespace
    [[ -z "${pattern}" ]] && continue
    # Support wildcards using bash pattern matching
    if [[ "${rg_name}" == ${pattern} ]]; then
      return 0  # Excluded
    fi
  done
  return 1  # Not excluded
}

########################
# Discovery Functions
########################

find_stopped_vms () {
  # VM powerState requires --show-details
  # Iterate through all resource groups to list VMs
  local rgs
  rgs=$(az group list --query "[].name" -o tsv)
  local rg_count=0

  while IFS= read -r rg; do
    [[ -z "${rg}" ]] && continue
    is_rg_excluded "${rg}" && continue
    ((rg_count++))
    echo -n "." >&2  # Progress indicator
    az vm list -d -g "${rg}" --query "[?powerState=='VM stopped' || powerState=='' || powerState==null].id" -o tsv 2>>"${ERROR_LOG}" || true
  done <<< "${rgs}"
  [[ ${rg_count} -gt 0 ]] && echo >&2  # Newline after progress dots
}

find_deallocated_vms () {
  # Iterate through all resource groups to list VMs
  local rgs
  rgs=$(az group list --query "[].name" -o tsv)
  local rg_count=0

  while IFS= read -r rg; do
    [[ -z "${rg}" ]] && continue
    is_rg_excluded "${rg}" && continue
    ((rg_count++))
    echo -n "." >&2  # Progress indicator
    az vm list -d -g "${rg}" --query "[?powerState=='VM deallocated'].id" -o tsv 2>>"${ERROR_LOG}" || true
  done <<< "${rgs}"
  [[ ${rg_count} -gt 0 ]] && echo >&2  # Newline after progress dots
}

find_unattached_disks () {
  # Query disks that are Unattached and exclude system/managed disks
  # Azure CLI 2.79.0+ requires --resource-group, so iterate through all RGs
  local rgs
  rgs=$(az group list --query "[].name" -o tsv)
  local rg_count=0

  while IFS= read -r rg; do
    [[ -z "${rg}" ]] && continue
    is_rg_excluded "${rg}" && continue
    ((rg_count++))
    echo -n "." >&2  # Progress indicator
    az disk list -g "${rg}" --query "[?(diskState=='Unattached' || managedBy==null || managedBy=='') && contains(to_string(tags), 'kubernetes.io-created-for-pvc')==\`false\` && contains(to_string(tags), 'ASR-ReplicaDisk')==\`false\` && contains(to_string(tags), 'asrseeddisk')==\`false\` && contains(to_string(tags), 'RSVaultBackup')==\`false\`].id" -o tsv 2>>"${ERROR_LOG}" || true
  done <<< "${rgs}"
  [[ ${rg_count} -gt 0 ]] && echo >&2  # Newline after progress dots
}

find_old_snapshots () {
  # Find managed disk snapshots older than 30 days
  local cutoff_seconds
  local snapshots

  # Calculate epoch seconds for 30 days ago
  cutoff_seconds=$(date -u -d '30 days ago' +%s 2>>"${ERROR_LOG}" || date -u -v-30d +%s 2>>"${ERROR_LOG}")

  # List all snapshots with their creation time
  snapshots=$(az snapshot list --query "[].{id:id,created:timeCreated}" -o tsv)

  while IFS=$'\t' read -r snap_id created_time; do
    [[ -z "${snap_id}" ]] && continue
    [[ -z "${created_time}" ]] && continue

    # Convert ISO 8601 timestamp to epoch seconds for reliable comparison
    # Remove any timezone suffix and convert
    created_seconds=$(date -u -d "${created_time}" +%s 2>>"${ERROR_LOG}" || date -u -jf "%Y-%m-%dT%H:%M:%S" "${created_time%.*}" +%s 2>>"${ERROR_LOG}" || echo "0")

    if [[ ${created_seconds} -gt 0 && ${created_seconds} -lt ${cutoff_seconds} ]]; then
      echo "${snap_id}"
    fi
  done <<< "${snapshots}"
}

find_unattached_public_ips () {
  # public IPs not attached to a NIC, LB, or NAT Gateway
  # Include both Static and Dynamic unattached IPs
  az network public-ip list --query "[?ipConfiguration==null && natGateway==null].id" -o tsv
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
  # Check both privateLinkServiceConnections and manualPrivateLinkServiceConnections
  local eps
  local approved
  local manual_approved
  eps=$(az network private-endpoint list --query "[].[id,name]" -o tsv)
  while IFS=$'\t' read -r id name; do
    [[ -z "${id}" ]] && continue

    # Check both automatic and manual connections for Approved status
    approved=$(az network private-endpoint show --ids "${id}" \
      --query "contains(privateLinkServiceConnections[].privateLinkServiceConnectionState.status, 'Approved')" -o tsv 2>>"${ERROR_LOG}" || echo "false")
    manual_approved=$(az network private-endpoint show --ids "${id}" \
      --query "contains(manualPrivateLinkServiceConnections[].privateLinkServiceConnectionState.status, 'Approved')" -o tsv 2>>"${ERROR_LOG}" || echo "false")

    # Mark as idle if neither connection type has Approved status
    if [[ "${approved}" != "true" && "${manual_approved}" != "true" ]]; then
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
      src=$(az resource show --ids "${item_id}" --query "properties.sourceResourceId" -o tsv 2>>"${ERROR_LOG}" || echo "")
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
  wslist=$(az synapse workspace list --query "[].name" -o tsv 2>>"${ERROR_LOG}" || true)
  for ws in ${wslist}; do
    az synapse sql pool list --workspace-name "${ws}" \
      --query "[?status=='Paused'].id" -o tsv 2>>"${ERROR_LOG}" || true
  done

  # Azure SQL elastic pools - first find all SQL servers
  local servers
  servers=$(az sql server list --query "[].[name,resourceGroup]" -o tsv 2>>"${ERROR_LOG}" || true)
  while IFS=$'\t' read -r server_name rg; do
    [[ -z "${server_name}" ]] && continue

    # List elastic pools in this server
    local pools
    pools=$(az sql elastic-pool list -g "${rg}" -s "${server_name}" \
      --query "[].[id,name]" -o tsv 2>>"${ERROR_LOG}" || true)

    while IFS=$'\t' read -r pool_id pool_name; do
      [[ -z "${pool_id}" ]] && continue

      # Count databases in this elastic pool
      local db_count
      db_count=$(az sql db list -g "${rg}" -s "${server_name}" \
        --query "length([?elasticPoolName=='${pool_name}'])" -o tsv 2>>"${ERROR_LOG}" || echo "1")

      if [[ "${db_count}" == "0" ]]; then
        echo "${pool_id}"
      fi
    done <<< "${pools}"
  done <<< "${servers}"
}

########################
# Main
########################

# Initialize error log file
: > "${ERROR_LOG}"
log "Error log file: ${ERROR_LOG}"

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
  log "Checking for stopped VMs..."
  while IFS= read -r id; do [[ -n "$id" ]] && tag_resource "$id" "vm-stopped"; done < <(find_stopped_vms)

  # 2) VMs deallocated
  log "Checking for deallocated VMs..."
  while IFS= read -r id; do [[ -n "$id" ]] && tag_resource "$id" "vm-deallocated"; done < <(find_deallocated_vms)

  # 3) Unattached managed disks
  log "Checking for unattached managed disks..."
  while IFS= read -r id; do [[ -n "$id" ]] && tag_resource "$id" "unattached-disk"; done < <(find_unattached_disks)

  # 4) Old snapshots (older than 30 days)
  log "Checking for old snapshots (>30 days)..."
  while IFS= read -r id; do [[ -n "$id" ]] && tag_resource "$id" "old-snapshot"; done < <(find_old_snapshots)

  # 5) Orphan backups (protected items)
  log "Checking for orphan backup items..."
  while IFS= read -r id; do [[ -n "$id" ]] && tag_resource "$id" "orphan-backup"; done < <(find_orphan_backups)

  # 6) Unattached Public IPs
  log "Checking for unattached public IPs..."
  while IFS= read -r id; do [[ -n "$id" ]] && tag_resource "$id" "unattached-publicip"; done < <(find_unattached_public_ips)

  # 7) Unattached NAT Gateways
  log "Checking for unattached NAT gateways..."
  while IFS= read -r id; do [[ -n "$id" ]] && tag_resource "$id" "unattached-natgw"; done < <(find_unattached_nat_gateways)

  # 8) Idle ExpressRoute circuits (no peerings)
  log "Checking for idle ExpressRoute circuits..."
  while IFS= read -r id; do [[ -n "$id" ]] && tag_resource "$id" "idle-expressroute"; done < <(find_idle_expressroute_circuits)

  # 9) Idle Private DNS zones (no VNet links & default-only records)
  log "Checking for idle private DNS zones..."
  while IFS= read -r id; do [[ -n "$id" ]] && tag_resource "$id" "idle-privatedns-zone"; done < <(find_idle_private_dns_zones)

  # 10) Idle Private Endpoints
  log "Checking for idle private endpoints..."
  while IFS= read -r id; do [[ -n "$id" ]] && tag_resource "$id" "idle-private-endpoint"; done < <(find_idle_private_endpoints)

  # 11) Idle SQL Pools (Synapse paused, SQL elastic pools with 0 DBs)
  log "Checking for idle SQL pools..."
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
#
#   Exclude specific resource groups (comma-separated, supports wildcards):
#   EXCLUDE_RGS="NetworkWatcherRG,MC_*,databricks-*" APPLY_TAGS=true ./tag-orphan-resources.sh
#
#   Specify custom error log file:
#   ERROR_LOG="/var/log/azure-orphan-errors.log" ./tag-orphan-resources.sh