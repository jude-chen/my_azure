<#
DISCLAIMER:
The information contained in this script and any accompanying materials (including, but not limited to, sample code) is provided "AS IS" and "WITH ALL FAULTS." Microsoft makes NO GUARANTEES OR WARRANTIES OF ANY KIND, WHETHER EXPRESS OR IMPLIED, including but not limited to implied warranties of merchantability or fitness for a particular purpose.

The entire risk arising out of the use or performance of the script remains with you. In no event shall Microsoft, its authors, or anyone else involved in the creation, production, or delivery of the script be liable for any damages whatsoever (including, without limitation, damages for loss of business profits, business interruption, loss of business information, or other pecuniary loss) arising out of the use of or inability to use the script, even if Microsoft has been advised of the possibility of such damages.

.SYNOPSIS
    Exports active Azure Policy assignments from all management group scopes in a tenant.

.DESCRIPTION
    This script enumerates all management groups in a tenant and queries policy assignments
    at each management group scope using Azure Resource Manager REST APIs.

    By default, all policy assignments at management group scope are exported,
    including assignments with enforcementMode = DoNotEnforce.

    Use -ExcludeDoNotEnforce to export only assignments with enforcementMode = Default.

.PARAMETER TenantId
    Azure tenant ID to query. Defaults to "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxx".

.PARAMETER OutputPath
    Output CSV path. Defaults to a timestamped file in the current directory.

.PARAMETER ExcludeDoNotEnforce
    Excludes assignments in DoNotEnforce mode. By default these are included.

.PARAMETER ForceLogin
    Forces an interactive login even if an existing context already matches the tenant.

.EXAMPLE
    .\Export-MgActivePolicyAssignments.ps1

.EXAMPLE
    .\Export-MgActivePolicyAssignments.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxx" -OutputPath ".\mg-policy-assignments.csv"

.EXAMPLE
    .\Export-MgActivePolicyAssignments.ps1 -ExcludeDoNotEnforce

.NOTES
    Requires modules: Az.Accounts, Az.Resources
    Reader access at management group scope is required to query policy assignments.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TenantId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = (Join-Path -Path (Get-Location) -ChildPath ("mg-active-policy-assignments-{0}.csv" -f (Get-Date -Format "yyyyMMdd-HHmmss"))),

    [Parameter()]
    [switch]$ExcludeDoNotEnforce,

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

Ensure-AzSession -TargetTenantId $TenantId -ForceInteractiveLogin ([bool]$ForceLogin)

$managementGroups = Get-AllManagementGroups
if (-not $managementGroups -or $managementGroups.Count -eq 0) {
    Write-Warning "No management groups found in tenant $TenantId."
    return
}

Write-Host "Found $($managementGroups.Count) management group(s)." -ForegroundColor Green

$rows = New-Object System.Collections.Generic.List[object]
foreach ($mg in $managementGroups) {
    $mgName = $mg.name
    $mgDisplayName = $mg.properties.displayName
    $scope = "/providers/Microsoft.Management/managementGroups/$mgName"

    Write-Host "Collecting policy assignments for MG: $mgDisplayName ($mgName)" -ForegroundColor Yellow

    $assignments = @(Get-AzPolicyAssignment -Scope $scope -ErrorAction SilentlyContinue)

    foreach ($assignment in $assignments) {
        if ($assignment.Scope -ne $scope) {
            # Keep only policy assignments created directly at this management group scope.
            continue
        }

        $enforcementMode = $assignment.EnforcementMode
        if (-not $enforcementMode) {
            $enforcementMode = "Default"
        }

        if ($ExcludeDoNotEnforce -and $enforcementMode -eq "DoNotEnforce") {
            continue
        }

        $notScopes = ""
        if ($null -ne $assignment.NotScope) {
            $notScopes = (@($assignment.NotScope | Where-Object { $null -ne $_ } | ForEach-Object { $_.ToString() }) -join ";")
        }

        $rows.Add([PSCustomObject]@{
            TenantId                   = $TenantId
            ManagementGroupName        = $mgName
            ManagementGroupDisplayName = $mgDisplayName
            AssignmentName             = $assignment.Name
            AssignmentDisplayName      = $assignment.DisplayName
            AssignmentDescription      = $assignment.Description
            AssignmentScope            = $assignment.Scope
            EnforcementMode            = $enforcementMode
            PolicyDefinitionId         = $assignment.PolicyDefinitionId
            NotScopes                  = $notScopes
            ParametersJson             = ($assignment.Parameter | ConvertTo-Json -Depth 50 -Compress)
            MetadataJson               = ($assignment.Metadata | ConvertTo-Json -Depth 50 -Compress)
            ResourceId                 = $assignment.Id
            ResourceType               = $assignment.Type
            Location                   = $assignment.Location
        })
    }
}

$outputDirectory = Split-Path -Path $OutputPath -Parent
if ($outputDirectory -and -not (Test-Path -Path $outputDirectory)) {
    New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
}

$rows |
    Sort-Object ManagementGroupName, AssignmentDisplayName |
    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host "Export complete. Rows: $($rows.Count)" -ForegroundColor Green
Write-Host "CSV path: $OutputPath" -ForegroundColor Green