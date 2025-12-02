#!/usr/bin/env bash

# DISCLAIMER:
# The information contained in this script and any accompanying materials (including, but not limited to, sample code) is provided "AS IS" and "WITH ALL FAULTS." Microsoft makes NO GUARANTEES OR WARRANTIES OF ANY KIND, WHETHER EXPRESS OR IMPLIED, including but not limited to implied warranties of merchantability or fitness for a particular purpose.
#
# The entire risk arising out of the use or performance of the script remains with you. In no event shall Microsoft, its authors, or anyone else involved in the creation, production, or delivery of the script be liable for any damages whatsoever (including, without limitation, damages for loss of business profits, business interruption, loss of business information, or other pecuniary loss) arising out of the use of or inability to use the script, even if Microsoft has been advised of the possibility of such damages.

# Tag Orphan/Idle Azure Resources Using Azure Resource Graph (ARG)
# Author: (your team)
# Requires: Azure CLI 2.50+ with az graph extension and access to all target subscriptions

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
# Optional: limit to a management group scope
MG_ID="${MG_ID:-}"
# Optional: exclude specific resource groups (comma-separated list)
EXCLUDE_RGS="${EXCLUDE_RGS:-}"
# Optional: error log file path
ERROR_LOG="${ERROR_LOG:-errors.log}"

# Colors for output
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log() { echo -e "${YELLOW}[INFO]${NC} $*"; }
ok()  { echo -e "${GREEN}[OK]${NC}   $*"; }
warn(){ echo -e "${RED}[WARN]${NC} $*"; }

# Initialize error log file
: > "${ERROR_LOG}"
log "Error log file: ${ERROR_LOG}"

tag_resource () {
  local id="$1"
  local reason="$2"
  local value="${TAG_PREFIX}:${reason}"

  if [[ "${APPLY_TAGS}" == "true" ]]; then
    if az resource update --ids "$id" --set "tags.${TAG_KEY}=${value}" --only-show-errors 2>>"${ERROR_LOG}" >/dev/null; then
      ok "Tagged: ${id}  (${TAG_KEY}=${value})"
    else
      warn "Failed to tag: ${id} — check permissions/provider support"
    fi
  else
    ok "DRY-RUN would tag: ${id}  (${TAG_KEY}=${value})"
  fi
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

run_arg_query () {
  local query="$1"
  local subscriptions="$2"

  if [[ -n "${MG_ID}" ]]; then
    az graph query -q "${query}" --management-groups "${MG_ID}" --query "data[].id" -o tsv 2>>"${ERROR_LOG}" || true
  elif [[ -n "${subscriptions}" ]]; then
    echo "Running query ${query}" >> "${ERROR_LOG}"
    az graph query -q "${query}" --subscriptions ${subscriptions} --query "data[].id" -o tsv 2>>"${ERROR_LOG}" || true
  else
    az graph query -q "${query}" --query "data[].id" -o tsv 2>>"${ERROR_LOG}" || true
  fi
}

########################
# Discovery Functions Using ARG
########################

find_stopped_vms () {
  local query="
    Resources
    | where type =~ 'microsoft.compute/virtualmachines'
    | extend powerState = tostring(properties.extended.instanceView.powerState.code)
    | where powerState =~ 'PowerState/stopped' or powerState == '' or isnull(powerState)
    | project id
  "
  run_arg_query "${query}" "${1:-}"
}

find_deallocated_vms () {
  local query="
    Resources
    | where type =~ 'microsoft.compute/virtualmachines'
    | extend powerState = tostring(properties.extended.instanceView.powerState.code)
    | where powerState =~ 'PowerState/deallocated'
    | project id
  "
  run_arg_query "${query}" "${1:-}"
}

find_unattached_disks () {
  local query="
    Resources
    | where type =~ 'microsoft.compute/disks'
    | where properties.diskState == 'Unattached' or isnull(managedBy) or managedBy == ''
    | where tags !contains 'kubernetes.io-created-for-pvc'
    | where tags !contains 'ASR-ReplicaDisk'
    | where tags !contains 'asrseeddisk'
    | where tags !contains 'RSVaultBackup'
    | project id
  "
  run_arg_query "${query}" "${1:-}"
}

find_old_snapshots () {
  local query="
    Resources
    | where type =~ 'microsoft.compute/snapshots'
    | where todatetime(properties.timeCreated) < ago(30d)
    | project id
  "
  run_arg_query "${query}" "${1:-}"
}

find_unattached_public_ips () {
  local query="
    Resources
    | where type =~ 'microsoft.network/publicipaddresses'
    | where isnull(properties.ipConfiguration) and isnull(properties.natGateway)
    | project id
  "
  run_arg_query "${query}" "${1:-}"
}

find_unattached_nat_gateways () {
  local query="
    Resources
    | where type =~ 'microsoft.network/natgateways'
    | where isnull(properties.subnets) or array_length(properties.subnets) == 0
    | project id
  "
  run_arg_query "${query}" "${1:-}"
}

find_idle_expressroute_circuits () {
  local query="
    Resources
    | where type =~ 'microsoft.network/expressroutecircuits'
    | where isnull(properties.peerings) or array_length(properties.peerings) == 0
       or properties.serviceProviderProvisioningState =~ 'NotProvisioned'
    | project id
  "
  run_arg_query "${query}" "${1:-}"
}

find_idle_private_dns_zones () {
  local query="
    Resources
    | where type =~ 'microsoft.network/privatednszones'
    | where properties.numberOfVirtualNetworkLinks == 0
    | project id
  "
  run_arg_query "${query}" "${1:-}"
}

find_idle_private_endpoints () {
  local query="
    Resources
    | where type =~ 'microsoft.network/privateendpoints'
    | extend connection = iff(array_length(properties.manualPrivateLinkServiceConnections) > 0, properties.manualPrivateLinkServiceConnections[0], properties.privateLinkServiceConnections[0])
    | extend stateEnum = tostring(connection.properties.privateLinkServiceConnectionState.status)
    | where stateEnum == 'Disconnected'
    | project id
  "
  run_arg_query "${query}" "${1:-}"
}

find_idle_synapse_sql_pools () {
  # Synapse Dedicated SQL pools that are Paused
  local synapse_query="
    Resources
    | where type =~ 'microsoft.synapse/workspaces/sqlpools'
    | where properties.status =~ 'Paused'
    | project id
  "
  run_arg_query "${synapse_query}" "${1:-}"
}

find_idle_elastic_pools () {
  # Azure SQL elastic pools with 0 databases
  # Note: ARG doesn't easily provide database count per elastic pool
  # This requires a more complex query or separate API calls
  # For now, we'll identify elastic pools and check them separately
  local elastic_pool_query="
    Resources
    | where type =~ 'microsoft.sql/servers/elasticpools'
    | extend elasticPoolId = tolower(tostring(id)), elasticPoolName = name, elasticPoolRG = resourceGroup,skuName=tostring(sku.name),skuTier=tostring(sku.tier),skuCapacity=tostring(sku.capacity)
    | join kind=leftouter (
        Resources
        | where type =~ 'microsoft.sql/servers/databases'
        | extend elasticPoolId = tolower(tostring(properties.elasticPoolId))
      ) on elasticPoolId
    | summarize databaseCount = countif(isnotempty(elasticPoolId1)) by elasticPoolId, elasticPoolName,serverResourceGroup=resourceGroup,name,skuName,skuTier,skuCapacity,elasticPoolRG
    | where databaseCount == 0
    | project elasticPoolId
  "
  run_arg_query "${elastic_pool_query}" "${1:-}"
}

########################
# Main
########################

# Check if az graph extension is installed
if ! az extension list --query "[?name=='resource-graph'].name" -o tsv | grep -q "resource-graph"; then
  log "Installing Azure Resource Graph extension..."
  az extension add --name resource-graph 2>>"${ERROR_LOG}" || {
    warn "Failed to install resource-graph extension. Please install it manually: az extension add --name resource-graph"
    exit 1
  }
fi

# Determine subscription scope
SUBSCRIPTION_LIST=""
if [[ -z "${MG_ID}" ]]; then
  log "Enumerating enabled subscriptions..."
  mapfile -t SUBS < <(az account list --query "[?state=='Enabled'].id" -o tsv)
  SUBSCRIPTION_LIST="${SUBS[*]}"
  log "Found ${#SUBS[@]} enabled subscription(s)"
else
  log "Using management group scope: ${MG_ID}"
fi

log "APPLY_TAGS=${APPLY_TAGS}, TAG=${TAG_KEY}"
[[ -n "${EXCLUDE_RGS}" ]] && log "Excluding resource groups: ${EXCLUDE_RGS}"

# 1) VMs stopped
log "Checking for stopped VMs..."
while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  # Extract resource group from ID and check exclusion
  rg=$(echo "$id" | grep -oP '/resourceGroups/\K[^/]+' || echo "")
  [[ -n "${rg}" ]] && is_rg_excluded "${rg}" && continue
  tag_resource "$id" "vm-stopped"
done < <(find_stopped_vms "${SUBSCRIPTION_LIST}")

# 2) VMs deallocated
log "Checking for deallocated VMs..."
while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  rg=$(echo "$id" | grep -oP '/resourceGroups/\K[^/]+' || echo "")
  [[ -n "${rg}" ]] && is_rg_excluded "${rg}" && continue
  tag_resource "$id" "vm-deallocated"
done < <(find_deallocated_vms "${SUBSCRIPTION_LIST}")

# 3) Unattached managed disks
log "Checking for unattached managed disks..."
while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  rg=$(echo "$id" | grep -oP '/resourceGroups/\K[^/]+' || echo "")
  [[ -n "${rg}" ]] && is_rg_excluded "${rg}" && continue
  tag_resource "$id" "unattached-disk"
done < <(find_unattached_disks "${SUBSCRIPTION_LIST}")

# 4) Old snapshots (older than 30 days)
log "Checking for old snapshots (>30 days)..."
while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  rg=$(echo "$id" | grep -oP '/resourceGroups/\K[^/]+' || echo "")
  [[ -n "${rg}" ]] && is_rg_excluded "${rg}" && continue
  tag_resource "$id" "old-snapshot"
done < <(find_old_snapshots "${SUBSCRIPTION_LIST}")

# 5) Unattached Public IPs
log "Checking for unattached public IPs..."
while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  rg=$(echo "$id" | grep -oP '/resourceGroups/\K[^/]+' || echo "")
  [[ -n "${rg}" ]] && is_rg_excluded "${rg}" && continue
  tag_resource "$id" "unattached-publicip"
done < <(find_unattached_public_ips "${SUBSCRIPTION_LIST}")

# 6) Unattached NAT Gateways
log "Checking for unattached NAT gateways..."
while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  rg=$(echo "$id" | grep -oP '/resourceGroups/\K[^/]+' || echo "")
  [[ -n "${rg}" ]] && is_rg_excluded "${rg}" && continue
  tag_resource "$id" "unattached-natgw"
done < <(find_unattached_nat_gateways "${SUBSCRIPTION_LIST}")

# 7) Idle ExpressRoute circuits (no peerings)
log "Checking for idle ExpressRoute circuits..."
while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  rg=$(echo "$id" | grep -oP '/resourceGroups/\K[^/]+' || echo "")
  [[ -n "${rg}" ]] && is_rg_excluded "${rg}" && continue
  tag_resource "$id" "idle-expressroute"
done < <(find_idle_expressroute_circuits "${SUBSCRIPTION_LIST}")

# 8) Idle Private DNS zones (no VNet links & default-only records)
log "Checking for idle private DNS zones..."
while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  rg=$(echo "$id" | grep -oP '/resourceGroups/\K[^/]+' || echo "")
  [[ -n "${rg}" ]] && is_rg_excluded "${rg}" && continue
  tag_resource "$id" "idle-privatedns-zone"
done < <(find_idle_private_dns_zones "${SUBSCRIPTION_LIST}")

# 9) Idle Private Endpoints
log "Checking for idle private endpoints..."
while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  rg=$(echo "$id" | grep -oP '/resourceGroups/\K[^/]+' || echo "")
  [[ -n "${rg}" ]] && is_rg_excluded "${rg}" && continue
  tag_resource "$id" "idle-private-endpoint"
done < <(find_idle_private_endpoints "${SUBSCRIPTION_LIST}")

# 10) Idle Synapse SQL Pools (Paused)
log "Checking for idle Synapse SQL pools..."
while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  rg=$(echo "$id" | grep -oP '/resourceGroups/\K[^/]+' || echo "")
  [[ -n "${rg}" ]] && is_rg_excluded "${rg}" && continue
  tag_resource "$id" "idle-synapse-sql-pool"
done < <(find_idle_synapse_sql_pools "${SUBSCRIPTION_LIST}")

# 11) Idle Elastic Pools (0 databases)
log "Checking for idle elastic pools..."
while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  rg=$(echo "$id" | grep -oP '/resourceGroups/\K[^/]+' || echo "")
  [[ -n "${rg}" ]] && is_rg_excluded "${rg}" && continue
  tag_resource "$id" "idle-elastic-pool"
done < <(find_idle_elastic_pools "${SUBSCRIPTION_LIST}")

echo
ok "Completed. Set APPLY_TAGS=true to persist tags (current: ${APPLY_TAGS})."
echo "Check ${ERROR_LOG} for any errors encountered during execution."

# Usage Examples:
#   Dry Run (Preview)
#   ./tag-orphan-resources-arg.sh
#
#   Apply Tags
#   TAG_KEY="CleanupCandidate" TAG_PREFIX="orphan" APPLY_TAGS=true ./tag-orphan-resources-arg.sh
#
#   Limit scope to a management group:
#   MG_ID="contoso-mg" APPLY_TAGS=true ./tag-orphan-resources-arg.sh
#
#   Exclude specific resource groups (comma-separated, supports wildcards):
#   EXCLUDE_RGS="NetworkWatcherRG,MC_*,databricks-*" APPLY_TAGS=true ./tag-orphan-resources-arg.sh
#
#   Specify custom error log file:
#   ERROR_LOG="/var/log/azure-orphan-errors.log" ./tag-orphan-resources-arg.sh
