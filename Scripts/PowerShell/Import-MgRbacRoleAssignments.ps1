<#
DISCLAIMER:
The information contained in this script and any accompanying materials (including, but not limited to, sample code) is provided "AS IS" and "WITH ALL FAULTS." Microsoft makes NO GUARANTEES OR WARRANTIES OF ANY KIND, WHETHER EXPRESS OR IMPLIED, including but not limited to implied warranties of merchantability or fitness for a particular purpose.

The entire risk arising out of the use or performance of the script remains with you. In no event shall Microsoft, its authors, or anyone else involved in the creation, production, or delivery of the script be liable for any damages whatsoever (including, without limitation, damages for loss of business profits, business interruption, loss of business information, or other pecuniary loss) arising out of the use of or inability to use the script, even if Microsoft has been advised of the possibility of such damages.

.SYNOPSIS
    Imports management-group RBAC assignments from CSV and creates assignments.

.DESCRIPTION
    This script reads a CSV file and applies role assignments at management group scope.
    It supports assignment modes:
      - Active Permanent       (direct RBAC via New-AzRoleAssignment)
      - Active Time-Bound      (PIM schedule request)
      - Eligible Permanent     (PIM eligibility schedule request)
      - Eligible Time-Bound    (PIM eligibility schedule request)

    The CSV template can be generated using -GenerateTemplateOnly.

.PARAMETER TenantId
    Azure tenant ID where assignments will be created.

.PARAMETER CsvPath
    Input CSV path.

.PARAMETER ForceLogin
    Forces an interactive login even if existing context matches the tenant.

.PARAMETER ContinueOnError
    Continue processing additional rows when one row fails.

.PARAMETER GenerateTemplateOnly
    Creates a CSV template at CsvPath and exits.

.EXAMPLE
    .\Import-MgRbacRoleAssignments.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -CsvPath ".\mg-rbac-assignments-input.csv"

.EXAMPLE
    .\Import-MgRbacRoleAssignments.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -CsvPath ".\mg-rbac-assignments-template.csv" -GenerateTemplateOnly

.NOTES
    Required modules: Az.Accounts, Az.Resources
    PIM assignment/eligibility schedule request creation requires appropriate role and permission at management group scope.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Medium")]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$CsvPath,

    [Parameter()]
    [switch]$ForceLogin,

    [Parameter()]
    [switch]$ContinueOnError,

    [Parameter()]
    [switch]$GenerateTemplateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RequiredCsvColumns = @(
    "TenantId",
    "TargetManagementGroupName",
    "PrincipalId",
    "PrincipalType",
    "RoleDefinitionId",
    "RoleDefinitionName",
    "AssignmentState",
    "StartTime",
    "EndTime",
    "Condition",
    "ConditionVersion",
    "Description",
    "CanDelegate",
    "SkipIfExists"
)

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

function Write-CsvTemplate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $templateRow = [PSCustomObject]@{
        TenantId                  = "00000000-0000-0000-0000-000000000000"
        TargetManagementGroupName = "contoso-platform"
        PrincipalId               = "11111111-1111-1111-1111-111111111111"
        PrincipalType             = "User"
        RoleDefinitionId          = "b24988ac-6180-42a0-ab88-20f7382dd24c"
        RoleDefinitionName        = "Contributor"
        AssignmentState           = "Active Permanent"
        StartTime                 = ""
        EndTime                   = ""
        Condition                 = ""
        ConditionVersion          = ""
        Description               = "Imported by CSV"
        CanDelegate               = "False"
        SkipIfExists              = "True"
    }

    $outputDirectory = Split-Path -Path $Path -Parent
    if ($outputDirectory -and -not (Test-Path -Path $outputDirectory)) {
        New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
    }

    $templateRow | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    Write-Host "Template generated: $Path" -ForegroundColor Green
}

function Test-HasCsvColumns {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Row
    )

    foreach ($column in $RequiredCsvColumns) {
        if (-not ($Row.PSObject.Properties.Name -contains $column)) {
            throw "CSV missing required column '$column'."
        }
    }
}

function ConvertTo-NullableDateTime {
    param(
        [Parameter()]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [string]$FieldName
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    try {
        return [datetime]::Parse($Value).ToUniversalTime()
    }
    catch {
        throw "Invalid datetime format in field '$FieldName': '$Value'. Use ISO format, for example 2026-05-11T00:00:00Z."
    }
}

function ConvertTo-BoolOrDefault {
    param(
        [Parameter()]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [bool]$DefaultValue,

        [Parameter(Mandatory = $true)]
        [string]$FieldName
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $DefaultValue
    }

    switch -Regex ($Value.Trim()) {
        "^(1|true|yes|y)$" { return $true }
        "^(0|false|no|n)$" { return $false }
        default { throw "Invalid boolean value in field '$FieldName': '$Value'. Use True or False." }
    }
}

function ConvertTo-NullIfWhiteSpace {
    param(
        [Parameter()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    return $Value.Trim()
}

function Resolve-RoleDefinitionGuid {
    param(
        [Parameter()]
        [string]$RoleDefinitionId,

        [Parameter()]
        [string]$RoleDefinitionName
    )

    if (-not [string]::IsNullOrWhiteSpace($RoleDefinitionId)) {
        $trimmed = $RoleDefinitionId.Trim()
        if ($trimmed -match "^[0-9a-fA-F-]{36}$") {
            return $trimmed
        }

        return $trimmed.Split("/")[-1]
    }

    if (-not [string]::IsNullOrWhiteSpace($RoleDefinitionName)) {
        $role = Get-AzRoleDefinition -Name $RoleDefinitionName -ErrorAction Stop | Select-Object -First 1
        if (-not $role) {
            throw "Role definition '$RoleDefinitionName' not found."
        }
        return $role.Id
    }

    throw "Either RoleDefinitionId or RoleDefinitionName must be provided."
}

function New-PimScheduleRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Scope,

        [Parameter(Mandatory = $true)]
        [ValidateSet("roleAssignmentScheduleRequests", "roleEligibilityScheduleRequests")]
        [string]$RequestResourceType,

        [Parameter(Mandatory = $true)]
        [string]$PrincipalId,

        [Parameter(Mandatory = $true)]
        [string]$RoleDefinitionGuid,

        [Parameter(Mandatory = $true)]
        [datetime]$StartDateTime,

        [Parameter()]
        [Nullable[datetime]]$EndDateTime,

        [Parameter()]
        [string]$Description,

        [Parameter()]
        [string]$Condition,

        [Parameter()]
        [string]$ConditionVersion
    )

    $requestId = [guid]::NewGuid().ToString()
    $path = "$Scope/providers/Microsoft.Authorization/$RequestResourceType/$requestId?api-version=2020-10-01"

    $expiration = if ($EndDateTime) {
        @{
            type        = "AfterDateTime"
            endDateTime = $EndDateTime.Value.ToString("o")
        }
    }
    else {
        @{ type = "NoExpiration" }
    }

    $body = @{
        properties = @{
            principalId      = $PrincipalId
            roleDefinitionId = "/providers/Microsoft.Authorization/roleDefinitions/$RoleDefinitionGuid"
            requestType      = "AdminAssign"
            justification    = if ([string]::IsNullOrWhiteSpace($Description)) { "Imported from CSV" } else { $Description }
            scheduleInfo     = @{
                startDateTime = $StartDateTime.ToString("o")
                expiration    = $expiration
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Condition)) {
        $body.properties.condition = $Condition
    }

    if (-not [string]::IsNullOrWhiteSpace($Condition) -and -not [string]::IsNullOrWhiteSpace($ConditionVersion)) {
        $body.properties.conditionVersion = $ConditionVersion
    }

    $jsonBody = $body | ConvertTo-Json -Depth 10
    $response = Invoke-AzRestMethod -Method PUT -Path $path -Payload $jsonBody
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        throw "PIM request failed with status code $($response.StatusCode). Response: $($response.Content)"
    }

    return $requestId
}

function Get-AssignmentScopeFromManagementGroupName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ManagementGroupName
    )

    return "/providers/Microsoft.Management/managementGroups/$ManagementGroupName"
}

if ($GenerateTemplateOnly) {
    Write-CsvTemplate -Path $CsvPath
    return
}

Ensure-AzSession -TargetTenantId $TenantId -ForceInteractiveLogin ([bool]$ForceLogin)

if (-not (Test-Path -Path $CsvPath)) {
    throw "CSV file not found: $CsvPath"
}

$rows = Import-Csv -Path $CsvPath
if (-not $rows -or $rows.Count -eq 0) {
    throw "CSV has no data rows: $CsvPath"
}

Write-Verbose "Loaded $($rows.Count) row(s) from CSV: $CsvPath"

Test-HasCsvColumns -Row $rows[0]

$results = New-Object System.Collections.Generic.List[object]
$rowIndex = 0

foreach ($row in $rows) {
    $rowIndex++
    $status = "Success"
    $message = ""

    try {
        Write-Verbose ("Row {0}: Starting. MG='{1}', PrincipalId='{2}', PrincipalType='{3}', RoleDefinitionId='{4}', RoleDefinitionName='{5}', AssignmentState='{6}'" -f $rowIndex, $row.TargetManagementGroupName, $row.PrincipalId, $row.PrincipalType, $row.RoleDefinitionId, $row.RoleDefinitionName, $row.AssignmentState)

        if (-not [string]::IsNullOrWhiteSpace($row.TenantId) -and $row.TenantId -ne $TenantId) {
            throw "Row tenant '$($row.TenantId)' does not match script TenantId '$TenantId'."
        }

        if ([string]::IsNullOrWhiteSpace($row.TargetManagementGroupName)) {
            throw "TargetManagementGroupName is required."
        }

        if ([string]::IsNullOrWhiteSpace($row.PrincipalId)) {
            throw "PrincipalId is required."
        }

        if ([string]::IsNullOrWhiteSpace($row.AssignmentState)) {
            throw "AssignmentState is required."
        }

        $state = $row.AssignmentState.Trim()
        if ($state -notin @("Active Permanent", "Active Time-Bound", "Eligible Permanent", "Eligible Time-Bound")) {
            throw "Unsupported AssignmentState '$state'."
        }

        $scope = Get-AssignmentScopeFromManagementGroupName -ManagementGroupName $row.TargetManagementGroupName.Trim()
        $roleDefinitionGuid = Resolve-RoleDefinitionGuid -RoleDefinitionId $row.RoleDefinitionId -RoleDefinitionName $row.RoleDefinitionName
        $startTime = ConvertTo-NullableDateTime -Value $row.StartTime -FieldName "StartTime"
        $endTime = ConvertTo-NullableDateTime -Value $row.EndTime -FieldName "EndTime"

        if (-not $startTime) {
            $startTime = (Get-Date).ToUniversalTime()
        }

        if ($state -match "Time-Bound" -and -not $endTime) {
            throw "EndTime is required for '$state'."
        }

        if ($endTime -and $endTime.Value -le $startTime.Value) {
            throw "EndTime must be later than StartTime."
        }

        $canDelegate = ConvertTo-BoolOrDefault -Value $row.CanDelegate -DefaultValue $false -FieldName "CanDelegate"
        $skipIfExists = ConvertTo-BoolOrDefault -Value $row.SkipIfExists -DefaultValue $true -FieldName "SkipIfExists"
        $condition = ConvertTo-NullIfWhiteSpace -Value $row.Condition
        $conditionVersion = ConvertTo-NullIfWhiteSpace -Value $row.ConditionVersion
        $description = ConvertTo-NullIfWhiteSpace -Value $row.Description

        Write-Verbose ("Row {0}: Normalized values. Scope='{1}', RoleDefinitionGuid='{2}', StartTime='{3}', EndTime='{4}', CanDelegate='{5}', SkipIfExists='{6}'" -f $rowIndex, $scope, $roleDefinitionGuid, $startTime, $endTime, $canDelegate, $skipIfExists)

        if (-not $condition -and $conditionVersion) {
            throw "ConditionVersion is set but Condition is empty. Either provide both values or leave both empty."
        }

        if ($state -eq "Active Permanent") {
            $existing = Get-AzRoleAssignment -ObjectId $row.PrincipalId -Scope $scope -ErrorAction SilentlyContinue |
                Where-Object { $_.RoleDefinitionId.Split("/")[-1] -eq $roleDefinitionGuid } |
                Select-Object -First 1

            if ($existing -and $skipIfExists) {
                $message = "Skipped: active assignment already exists."
                Write-Verbose "Row ${rowIndex}: $message"
            }
            else {
                $target = "$scope | Principal=$($row.PrincipalId) | Role=$roleDefinitionGuid"
                if ($PSCmdlet.ShouldProcess($target, "Create permanent active role assignment")) {
                    $assignmentParams = @{
                        ObjectId         = $row.PrincipalId
                        Scope            = $scope
                        RoleDefinitionId = $roleDefinitionGuid
                        ErrorAction      = "Stop"
                    }

                    if ($condition) {
                        $assignmentParams.Condition = $condition
                    }

                    if ($condition -and $conditionVersion) {
                        $assignmentParams.ConditionVersion = $conditionVersion
                    }

                    if ($description) {
                        $assignmentParams.Description = $description
                    }

                    if ($canDelegate) {
                        $cmdParameters = (Get-Command New-AzRoleAssignment).Parameters
                        if ($cmdParameters.ContainsKey("AllowDelegation")) {
                            $assignmentParams.AllowDelegation = $true
                        }
                        elseif ($cmdParameters.ContainsKey("CanDelegate")) {
                            $assignmentParams.CanDelegate = $true
                        }
                    }

                    New-AzRoleAssignment @assignmentParams | Out-Null
                }
                $message = "Active permanent assignment created."
                Write-Verbose "Row ${rowIndex}: $message"
            }
        }
        elseif ($state -eq "Active Time-Bound") {
            $target = "$scope | Principal=$($row.PrincipalId) | Role=$roleDefinitionGuid"
            if ($PSCmdlet.ShouldProcess($target, "Create time-bound active PIM schedule request")) {
                $requestId = New-PimScheduleRequest -Scope $scope -RequestResourceType "roleAssignmentScheduleRequests" -PrincipalId $row.PrincipalId -RoleDefinitionGuid $roleDefinitionGuid -StartDateTime $startTime.Value -EndDateTime $endTime -Description $description -Condition $condition -ConditionVersion $conditionVersion
                $message = "Active time-bound request submitted. RequestId=$requestId"
                Write-Verbose "Row ${rowIndex}: $message"
            }
        }
        elseif ($state -eq "Eligible Permanent") {
            $target = "$scope | Principal=$($row.PrincipalId) | Role=$roleDefinitionGuid"
            if ($PSCmdlet.ShouldProcess($target, "Create permanent eligible PIM schedule request")) {
                $requestId = New-PimScheduleRequest -Scope $scope -RequestResourceType "roleEligibilityScheduleRequests" -PrincipalId $row.PrincipalId -RoleDefinitionGuid $roleDefinitionGuid -StartDateTime $startTime.Value -EndDateTime $null -Description $description -Condition $condition -ConditionVersion $conditionVersion
                $message = "Eligible permanent request submitted. RequestId=$requestId"
                Write-Verbose "Row ${rowIndex}: $message"
            }
        }
        else {
            $target = "$scope | Principal=$($row.PrincipalId) | Role=$roleDefinitionGuid"
            if ($PSCmdlet.ShouldProcess($target, "Create time-bound eligible PIM schedule request")) {
                $requestId = New-PimScheduleRequest -Scope $scope -RequestResourceType "roleEligibilityScheduleRequests" -PrincipalId $row.PrincipalId -RoleDefinitionGuid $roleDefinitionGuid -StartDateTime $startTime.Value -EndDateTime $endTime -Description $description -Condition $condition -ConditionVersion $conditionVersion
                $message = "Eligible time-bound request submitted. RequestId=$requestId"
                Write-Verbose "Row ${rowIndex}: $message"
            }
        }

        $results.Add([PSCustomObject]@{
            RowNumber                 = $rowIndex
            TenantId                  = $TenantId
            TargetManagementGroupName = $row.TargetManagementGroupName
            PrincipalId               = $row.PrincipalId
            RoleDefinitionId          = $roleDefinitionGuid
            AssignmentState           = $state
            Status                    = $status
            Message                   = $message
            CanDelegate               = $canDelegate
        })

        Write-Verbose "Row ${rowIndex}: Completed with status '$status'."
    }
    catch {
        $status = "Failed"
        $message = $_.Exception.Message

        $results.Add([PSCustomObject]@{
            RowNumber                 = $rowIndex
            TenantId                  = $TenantId
            TargetManagementGroupName = $row.TargetManagementGroupName
            PrincipalId               = $row.PrincipalId
            RoleDefinitionId          = $row.RoleDefinitionId
            AssignmentState           = $row.AssignmentState
            Status                    = $status
            Message                   = $message
            CanDelegate               = $null
        })

        Write-Verbose "Row ${rowIndex}: Failed. $message"
        Write-Error "Row $rowIndex failed: $message"
        if (-not $ContinueOnError) {
            break
        }
    }
}

$summary = $results | Group-Object Status | Sort-Object Name
foreach ($group in $summary) {
    Write-Host ("{0}: {1}" -f $group.Name, $group.Count) -ForegroundColor Cyan
}

$failed = @($results | Where-Object { $_.Status -eq "Failed" })
if ($failed.Count -gt 0) {
    Write-Warning "Completed with failures."
}
else {
    Write-Host "Import completed successfully." -ForegroundColor Green
}
