<#
DISCLAIMER:
The information contained in this script and any accompanying materials (including, but not limited to, sample code) is provided "AS IS" and "WITH ALL FAULTS." Microsoft makes NO GUARANTEES OR WARRANTIES OF ANY KIND, WHETHER EXPRESS OR IMPLIED, including but not limited to implied warranties of merchantability or fitness for a particular purpose.

The entire risk arising out of the use or performance of the script remains with you. In no event shall Microsoft, its authors, or anyone else involved in the creation, production, or delivery of the script be liable for any damages whatsoever (including, without limitation, damages for loss of business profits, business interruption, loss of business information, or other pecuniary loss) arising out of the use of or inability to use the script, even if Microsoft has been advised of the possibility of such damages.

.SYNOPSIS
    Exports RBAC role assignments from all management group scopes in a tenant.

.DESCRIPTION
    This script enumerates all management groups in a tenant, retrieves both active and eligible
    PIM role assignments for each management group scope, and exports flattened results—including
    assignment state (Active Permanent, Active Time-Bound, Eligible Permanent, Eligible Time-Bound)
    and end time—to a CSV file.

.PARAMETER TenantId
    Azure tenant ID to query.

.PARAMETER OutputPath
    Output CSV path. Defaults to a timestamped file in the current directory.

.PARAMETER ForceLogin
    Forces an interactive login even if an existing context already matches the tenant.

.EXAMPLE
    .\Export-MgRbacRoleAssignments.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.EXAMPLE
    .\Export-MgRbacRoleAssignments.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -OutputPath ".\mg-rbac.csv"

.NOTES
    Requires modules: Az.Accounts, Az.Resources
    Requires read access to Microsoft.Authorization/roleAssignmentSchedules and
    Microsoft.Authorization/roleEligibilitySchedules at management group scope.
    Principal display name resolution requires Microsoft Graph directory read access.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TenantId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = (Join-Path -Path (Get-Location) -ChildPath ("mg-rbac-role-assignments-{0}.csv" -f (Get-Date -Format "yyyyMMdd-HHmmss"))),

    [Parameter()]
    [switch]$ForceLogin
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-AzSession {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetTenantId,

        [Parameter(Mandatory = $true)]
        [bool]$ForceInteractiveLogin
    )

    $context = Get-AzContext -ErrorAction SilentlyContinue
    $needsLogin = $ForceInteractiveLogin

    if (-not $context) {
        $needsLogin = $true
    }
    elseif ($context.Tenant.Id -ne $TargetTenantId) {
        $needsLogin = $true
    }

    if ($needsLogin) {
        Write-Host "Connecting to Azure tenant $TargetTenantId ..." -ForegroundColor Cyan
        Connect-AzAccount -Tenant $TargetTenantId | Out-Null
    }

    $verifiedContext = Get-AzContext
    if (-not $verifiedContext -or $verifiedContext.Tenant.Id -ne $TargetTenantId) {
        throw "Unable to establish Azure context for tenant '$TargetTenantId'."
    }

    Write-Host "Connected as $($verifiedContext.Account.Id) in tenant $($verifiedContext.Tenant.Id)" -ForegroundColor Green
}

function Get-AllManagementGroups {
    $apiVersion = "2023-04-01"
    $path = "/providers/Microsoft.Management/managementGroups?api-version=$apiVersion"

    Write-Host "Retrieving management groups..." -ForegroundColor Cyan
    $response = Invoke-AzRestMethod -Method GET -Path $path
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        throw "Management group query failed with status code $($response.StatusCode)."
    }

    $payload = $response.Content | ConvertFrom-Json
    return @($payload.value)
}

function Get-AssignmentPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Assignment,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    $property = $Assignment.PSObject.Properties[$PropertyName]
    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

function Get-PimSchedules {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Scope,

        [Parameter(Mandatory = $true)]
        [ValidateSet("roleAssignmentSchedules", "roleEligibilitySchedules", "roleAssignmentScheduleInstances", "roleEligibilityScheduleInstances")]
        [string]$ResourceType
    )

    $apiVersion = "2020-10-01"
    $items = [System.Collections.Generic.List[object]]::new()
    $nextLink = "$Scope/providers/Microsoft.Authorization/${ResourceType}?api-version=$apiVersion"

    while ($nextLink) {
        try {
            if ($nextLink -match "^https?://") {
                $response = Invoke-AzRestMethod -Method GET -Uri $nextLink -ErrorAction SilentlyContinue
            }
            else {
                $response = Invoke-AzRestMethod -Method GET -Path $nextLink -ErrorAction SilentlyContinue
            }
        }
        catch { break }

        if ($null -eq $response -or $response.StatusCode -lt 200 -or $response.StatusCode -ge 300) { break }

        $payload = $response.Content | ConvertFrom-Json
        $pageItems = Get-AssignmentPropertyValue -Assignment $payload -PropertyName "value"
        if ($pageItems) {
            foreach ($item in $pageItems) { $items.Add($item) }
        }
        $nextLink = Get-AssignmentPropertyValue -Assignment $payload -PropertyName "nextLink"
    }

    return , $items.ToArray()
}

function Select-PreferredInstance {
    param(
        [Parameter()]
        [object]$Existing,

        [Parameter(Mandatory = $true)]
        [object]$Candidate
    )

    if (-not $Existing) {
        return $Candidate
    }

    $existingEnd = Get-AssignmentPropertyValue -Assignment $Existing.properties -PropertyName "endDateTime"
    $candidateEnd = Get-AssignmentPropertyValue -Assignment $Candidate.properties -PropertyName "endDateTime"

    # Prefer permanent over time-bound when multiple records exist for the same principal/role.
    if (-not $candidateEnd -and $existingEnd) {
        return $Candidate
    }

    if ($candidateEnd -and -not $existingEnd) {
        return $Existing
    }

    if ($candidateEnd -and $existingEnd) {
        if ([datetime]$candidateEnd -gt [datetime]$existingEnd) {
            return $Candidate
        }
    }

    return $Existing
}

function Get-CachedRoleDefinitionName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RoleDefinitionId
    )

    if ($script:RoleDefNameCache.ContainsKey($RoleDefinitionId)) {
        return $script:RoleDefNameCache[$RoleDefinitionId]
    }

    try {
        $encodedPath = [uri]::EscapeUriString("$RoleDefinitionId")
        $path = "$encodedPath`?api-version=2022-04-01"
        $response = Invoke-AzRestMethod -Method GET -Path $path -ErrorAction SilentlyContinue
        if ($response.StatusCode -eq 200) {
            $roleDef = $response.Content | ConvertFrom-Json
            $name = $roleDef.properties.roleName
            $script:RoleDefNameCache[$RoleDefinitionId] = $name
            return $name
        }
    }
    catch {}

    $name = $RoleDefinitionId.Split('/')[-1]
    $script:RoleDefNameCache[$RoleDefinitionId] = $name
    return $name
}

function Get-CachedPrincipalInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PrincipalId
    )

    if ($script:PrincipalInfoCache.ContainsKey($PrincipalId)) {
        return $script:PrincipalInfoCache[$PrincipalId]
    }

    $info = [PSCustomObject]@{ DisplayName = $null; SignInName = $null }

    try {
        $response = Invoke-AzRestMethod -Method GET -Uri "https://graph.microsoft.com/v1.0/directoryObjects/$PrincipalId" -ErrorAction SilentlyContinue
        if ($response.StatusCode -eq 200) {
            $obj = $response.Content | ConvertFrom-Json
            $info.DisplayName = $obj.displayName
            $info.SignInName  = $obj.userPrincipalName
        }
    }
    catch {}

    $script:PrincipalInfoCache[$PrincipalId] = $info
    return $info
}

function Resolve-AssignmentState {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Schedule,

        [Parameter(Mandatory = $true)]
        [bool]$IsEligible
    )

    $expType = (Get-AssignmentPropertyValue -Assignment $Schedule.properties -PropertyName "expiration") |
        ForEach-Object { if ($_ -is [PSObject]) { $_.type } else { $null } }

    if (-not $expType) {
        $expObj = Get-AssignmentPropertyValue -Assignment $Schedule.properties -PropertyName "expiration"
        if ($expObj) {
            $expType = Get-AssignmentPropertyValue -Assignment $expObj -PropertyName "type"
        }
    }

    $isPermanent = [string]::IsNullOrWhiteSpace([string]$expType) -or $expType -eq "NoExpiration"

    if ($IsEligible) {
        if ($isPermanent) { return "Eligible Permanent" }
        else { return "Eligible Time-Bound" }
    }

    if ($isPermanent) { return "Active Permanent" }
    return "Active Time-Bound"
}

function Resolve-EndTime {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Schedule
    )

    $expObj = Get-AssignmentPropertyValue -Assignment $Schedule.properties -PropertyName "expiration"
    if (-not $expObj) { return $null }

    $expType = Get-AssignmentPropertyValue -Assignment $expObj -PropertyName "type"
    if ($expType -in @("AfterDateTime", "AfterDuration")) {
        return Get-AssignmentPropertyValue -Assignment $expObj -PropertyName "endDateTime"
    }
    return $null
}

Ensure-AzSession -TargetTenantId $TenantId -ForceInteractiveLogin ([bool]$ForceLogin)

$managementGroups = Get-AllManagementGroups
if (-not $managementGroups -or $managementGroups.Count -eq 0) {
    Write-Warning "No management groups found in tenant $TenantId."
    return
}

Write-Host "Found $($managementGroups.Count) management group(s)." -ForegroundColor Green

$rows = New-Object System.Collections.Generic.List[object]
$script:RoleDefNameCache  = @{}
$script:PrincipalInfoCache = @{}

foreach ($mg in $managementGroups) {
    $mgName        = $mg.name
    $mgDisplayName = $mg.properties.displayName
    $scope         = "/providers/Microsoft.Management/managementGroups/$mgName"

    Write-Host "Collecting role assignments for MG: $mgDisplayName ($mgName)" -ForegroundColor Yellow

    # Build PIM active-assignment lookup keyed by principalId|roleDefinitionId-guid
    $activeSchedules = Get-PimSchedules -Scope $scope -ResourceType "roleAssignmentSchedules"
    $pimLookup = @{}
    foreach ($sch in $activeSchedules) {
        $roleDefGuid = $sch.properties.roleDefinitionId.Split('/')[-1]
        $key = "$($sch.properties.principalId)|$roleDefGuid"
        $pimLookup[$key] = $sch
    }

    # Active assignment instances hold authoritative endDateTime.
    $activeInstances = Get-PimSchedules -Scope $scope -ResourceType "roleAssignmentScheduleInstances"
    $activeInstanceLookup = @{}
    foreach ($ins in $activeInstances) {
        if ($ins.properties.scope -ne $scope) { continue }
        $roleDefGuid = $ins.properties.roleDefinitionId.Split('/')[-1]
        $key = "$($ins.properties.principalId)|$roleDefGuid"
        $activeInstanceLookup[$key] = Select-PreferredInstance -Existing $activeInstanceLookup[$key] -Candidate $ins
    }

    # Active assignments (direct RBAC) – enriched with PIM state / end time
    $assignments = @(Get-AzRoleAssignment -Scope $scope -ErrorAction SilentlyContinue)
    foreach ($assignment in $assignments) {
        if ($assignment.Scope -ne $scope) { continue }

        $roleDefGuid = $assignment.RoleDefinitionId.Split('/')[-1]
        $key         = "$($assignment.ObjectId)|$roleDefGuid"
        $pimSchedule = $pimLookup[$key]
        $pimInstance = $activeInstanceLookup[$key]

        if ($pimInstance) {
            $endTime = Get-AssignmentPropertyValue -Assignment $pimInstance.properties -PropertyName "endDateTime"
            if ($endTime) {
                $state = "Active Time-Bound"
            }
            else {
                $state = "Active Permanent"
            }
        }
        elseif ($pimSchedule) {
            $state   = Resolve-AssignmentState -Schedule $pimSchedule -IsEligible $false
            $endTime = Resolve-EndTime -Schedule $pimSchedule
        }
        else {
            $state   = "Active Permanent"
            $endTime = $null
        }

        $rows.Add([PSCustomObject]@{
            TenantId                   = $TenantId
            ManagementGroupName        = $mgName
            ManagementGroupDisplayName = $mgDisplayName
            Scope                      = $assignment.Scope
            RoleAssignmentId           = $assignment.RoleAssignmentId
            RoleDefinitionId           = $assignment.RoleDefinitionId
            RoleDefinitionName         = $assignment.RoleDefinitionName
            PrincipalId                = $assignment.ObjectId
            PrincipalType              = $assignment.ObjectType
            PrincipalDisplayName       = $assignment.DisplayName
            PrincipalSignInName        = $assignment.SignInName
            CanDelegate                = (Get-AssignmentPropertyValue -Assignment $assignment -PropertyName "CanDelegate")
            Condition                  = (Get-AssignmentPropertyValue -Assignment $assignment -PropertyName "Condition")
            ConditionVersion           = (Get-AssignmentPropertyValue -Assignment $assignment -PropertyName "ConditionVersion")
            Description                = (Get-AssignmentPropertyValue -Assignment $assignment -PropertyName "Description")
            CreatedOn                  = (Get-AssignmentPropertyValue -Assignment $assignment -PropertyName "CreatedOn")
            UpdatedOn                  = (Get-AssignmentPropertyValue -Assignment $assignment -PropertyName "UpdatedOn")
            CreatedBy                  = (Get-AssignmentPropertyValue -Assignment $assignment -PropertyName "CreatedBy")
            UpdatedBy                  = (Get-AssignmentPropertyValue -Assignment $assignment -PropertyName "UpdatedBy")
            AssignmentState            = $state
            EndTime                    = $endTime
        })
    }

    # Eligible assignments – only exist in PIM, not returned by Get-AzRoleAssignment
    $eligibleSchedules = Get-PimSchedules -Scope $scope -ResourceType "roleEligibilitySchedules"
    $eligibleInstances = Get-PimSchedules -Scope $scope -ResourceType "roleEligibilityScheduleInstances"
    $eligibleInstanceByName = @{}
    $eligibleInstanceByPrincipalRole = @{}
    foreach ($ins in $eligibleInstances) {
        if ($ins.properties.scope -ne $scope) { continue }

        $eligibleInstanceByName[$ins.name] = Select-PreferredInstance -Existing $eligibleInstanceByName[$ins.name] -Candidate $ins

        $roleDefGuid = $ins.properties.roleDefinitionId.Split('/')[-1]
        $key = "$($ins.properties.principalId)|$roleDefGuid"
        $eligibleInstanceByPrincipalRole[$key] = Select-PreferredInstance -Existing $eligibleInstanceByPrincipalRole[$key] -Candidate $ins
    }

    foreach ($sch in $eligibleSchedules) {
        # Skip inherited schedules; keep only those created directly at this MG scope
        if ($sch.properties.scope -ne $scope) { continue }

        $roleDefGuid = $sch.properties.roleDefinitionId.Split('/')[-1]
        $scheduleKey = "$($sch.properties.principalId)|$roleDefGuid"
        $eligInstance = $eligibleInstanceByName[$sch.name]
        if (-not $eligInstance) {
            $eligInstance = $eligibleInstanceByPrincipalRole[$scheduleKey]
        }

        $roleDefName = Get-CachedRoleDefinitionName -RoleDefinitionId $sch.properties.roleDefinitionId
        $principal   = Get-CachedPrincipalInfo -PrincipalId $sch.properties.principalId

        if ($eligInstance) {
            $endTime = Get-AssignmentPropertyValue -Assignment $eligInstance.properties -PropertyName "endDateTime"
            if ($endTime) {
                $state = "Eligible Time-Bound"
            }
            else {
                $state = "Eligible Permanent"
            }
        }
        else {
            $state   = Resolve-AssignmentState -Schedule $sch -IsEligible $true
            $endTime = Resolve-EndTime -Schedule $sch
        }

        $rows.Add([PSCustomObject]@{
            TenantId                   = $TenantId
            ManagementGroupName        = $mgName
            ManagementGroupDisplayName = $mgDisplayName
            Scope                      = $sch.properties.scope
            RoleAssignmentId           = $sch.name
            RoleDefinitionId           = $sch.properties.roleDefinitionId
            RoleDefinitionName         = $roleDefName
            PrincipalId                = $sch.properties.principalId
            PrincipalType              = $sch.properties.principalType
            PrincipalDisplayName       = $principal.DisplayName
            PrincipalSignInName        = $principal.SignInName
            CanDelegate                = $null
            Condition                  = (Get-AssignmentPropertyValue -Assignment $sch.properties -PropertyName "condition")
            ConditionVersion           = (Get-AssignmentPropertyValue -Assignment $sch.properties -PropertyName "conditionVersion")
            Description                = (Get-AssignmentPropertyValue -Assignment $sch.properties -PropertyName "description")
            CreatedOn                  = (Get-AssignmentPropertyValue -Assignment $sch.properties -PropertyName "createdOn")
            UpdatedOn                  = (Get-AssignmentPropertyValue -Assignment $sch.properties -PropertyName "updatedOn")
            CreatedBy                  = (Get-AssignmentPropertyValue -Assignment $sch.properties -PropertyName "createdBy")
            UpdatedBy                  = (Get-AssignmentPropertyValue -Assignment $sch.properties -PropertyName "updatedBy")
            AssignmentState            = $state
            EndTime                    = $endTime
        })
    }
}

$outputDirectory = Split-Path -Path $OutputPath -Parent
if ($outputDirectory -and -not (Test-Path -Path $outputDirectory)) {
    New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
}

$rows |
    Sort-Object ManagementGroupName, RoleDefinitionName, PrincipalDisplayName |
    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host "Export complete. Rows: $($rows.Count)" -ForegroundColor Green
Write-Host "CSV path: $OutputPath" -ForegroundColor Green