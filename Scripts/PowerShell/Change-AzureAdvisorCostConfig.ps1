<#
DISCLAIMER:
The information contained in this script and any accompanying materials (including, but not limited to, sample code) is provided “AS IS” and “WITH ALL FAULTS.” Microsoft makes NO GUARANTEES OR WARRANTIES OF ANY KIND, WHETHER EXPRESS OR IMPLIED, including but not limited to implied warranties of merchantability or fitness for a particular purpose.

The entire risk arising out of the use or performance of the script remains with you. In no event shall Microsoft, its authors, or anyone else involved in the creation, production, or delivery of the script be liable for any damages whatsoever (including, without limitation, damages for loss of business profits, business interruption, loss of business information, or other pecuniary loss) arising out of the use of or inability to use the script, even if Microsoft has been advised of the possibility of such damages.

.SYNOPSIS
    Changes Azure Advisor cost recommendation configuration settings across all subscriptions in the tenant.

.DESCRIPTION
    This script iterates through all Azure subscriptions in the current tenant and applies
    Azure Advisor cost recommendation configuration settings to each subscription.

.PARAMETER Exclude
    Whether to exclude the subscription from cost recommendations. Default is $false.

.PARAMETER LowCpuThreshold
    The CPU threshold percentage for identifying underutilized VMs. Valid values: 5, 10, 15, 20, or 100 (disabled). Default is "100".

.PARAMETER Duration
    The look-back period in days for analyzing VM usage. Valid values: 7, 14, 21, 30, 60, 90. Default is "14".

.PARAMETER WhatIf
    Shows what would happen if the script runs without making actual changes.

.EXAMPLE
    .\Change-AzureAdvisorCostConfig.ps1
    Applies default settings (exclude=$false, lowCpuThreshold=100, duration=14) to all subscriptions.

.EXAMPLE
    .\Change-AzureAdvisorCostConfig.ps1 -LowCpuThreshold "20" -Duration "30"
    Sets CPU threshold to 20% and look-back period to 30 days for all subscriptions.

.EXAMPLE
    .\Change-AzureAdvisorCostConfig.ps1 -WhatIf
    Shows which subscriptions would be updated without making changes.

.NOTES
    Author: Azure Administrator
    Requires: Az.Accounts module
    API Version: 2025-01-01
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [bool]$Exclude = $false,

    [Parameter()]
    [ValidateSet("5", "10", "15", "20", "100")]
    [string]$LowCpuThreshold = "100",

    [Parameter()]
    [ValidateSet("7", "14", "21", "30", "60", "90")]
    [string]$Duration = "14"
)

# Ensure we're connected to Azure
try {
    $context = Get-AzContext
    if (-not $context) {
        Write-Error "Not connected to Azure. Please run Connect-AzAccount first."
        exit 1
    }
    Write-Host "Connected to Azure as: $($context.Account.Id)" -ForegroundColor Green
    Write-Host "Tenant ID: $($context.Tenant.Id)" -ForegroundColor Green
}
catch {
    Write-Error "Failed to get Azure context: $_"
    exit 1
}

# Get all subscriptions in the tenant
Write-Host "`nRetrieving all subscriptions in the tenant..." -ForegroundColor Cyan
try {
    $subscriptions = Get-AzSubscription -TenantId $context.Tenant.Id | Where-Object { $_.State -eq "Enabled" }
    Write-Host "Found $($subscriptions.Count) enabled subscription(s)" -ForegroundColor Green
}
catch {
    Write-Error "Failed to retrieve subscriptions: $_"
    exit 1
}

if ($subscriptions.Count -eq 0) {
    Write-Warning "No enabled subscriptions found in the tenant."
    exit 0
}

# Prepare the configuration payload
$payload = @{
    properties = @{
        exclude         = $Exclude
        lowCpuThreshold = $LowCpuThreshold
        duration        = $Duration
    }
} | ConvertTo-Json -Depth 5

Write-Host "`nConfiguration to apply:" -ForegroundColor Cyan
Write-Host "  Exclude: $Exclude"
Write-Host "  Low CPU Threshold: $LowCpuThreshold%"
Write-Host "  Duration: $Duration days"
Write-Host ""

# Track results
$results = @{
    Success = @()
    Failed  = @()
    Skipped = @()
}

# Apply configuration to each subscription
foreach ($subscription in $subscriptions) {
    $subId = $subscription.Id
    $subName = $subscription.Name

    if ($PSCmdlet.ShouldProcess("$subName ($subId)", "Update Azure Advisor cost configuration")) {
        Write-Host "Processing subscription: $subName ($subId)..." -ForegroundColor Yellow

        try {
            $response = Invoke-AzRestMethod `
                -Method PUT `
                -Path "/subscriptions/$subId/providers/Microsoft.Advisor/configurations/default?api-version=2025-01-01" `
                -Payload $payload

            if ($response.StatusCode -in 200, 201, 202) {
                Write-Host "  ✓ Successfully updated configuration" -ForegroundColor Green
                $results.Success += [PSCustomObject]@{
                    SubscriptionId   = $subId
                    SubscriptionName = $subName
                    StatusCode       = $response.StatusCode
                }
            }
            else {
                Write-Host "  ✗ Failed with status code: $($response.StatusCode)" -ForegroundColor Red
                $errorContent = $response.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($errorContent.error.message) {
                    Write-Host "    Error: $($errorContent.error.message)" -ForegroundColor Red
                }
                $results.Failed += [PSCustomObject]@{
                    SubscriptionId   = $subId
                    SubscriptionName = $subName
                    StatusCode       = $response.StatusCode
                    Error            = $errorContent.error.message
                }
            }
        }
        catch {
            Write-Host "  ✗ Exception occurred: $_" -ForegroundColor Red
            $results.Failed += [PSCustomObject]@{
                SubscriptionId   = $subId
                SubscriptionName = $subName
                StatusCode       = "Exception"
                Error            = $_.Exception.Message
            }
        }
    }
    else {
        $results.Skipped += [PSCustomObject]@{
            SubscriptionId   = $subId
            SubscriptionName = $subName
        }
    }
}

# Display summary
Write-Host "`n" + "=" * 60 -ForegroundColor Cyan
Write-Host "SUMMARY" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "Total subscriptions processed: $($subscriptions.Count)"
Write-Host "  Successful: $($results.Success.Count)" -ForegroundColor Green
Write-Host "  Failed: $($results.Failed.Count)" -ForegroundColor $(if ($results.Failed.Count -gt 0) { "Red" } else { "Green" })
Write-Host "  Skipped: $($results.Skipped.Count)" -ForegroundColor $(if ($results.Skipped.Count -gt 0) { "Yellow" } else { "Green" })

# Output detailed results if there were failures
if ($results.Failed.Count -gt 0) {
    Write-Host "`nFailed subscriptions:" -ForegroundColor Red
    $results.Failed | Format-Table -AutoSize
}

# Return results object for further processing if needed
return [PSCustomObject]@{
    TotalSubscriptions = $subscriptions.Count
    SuccessCount       = $results.Success.Count
    FailedCount        = $results.Failed.Count
    SkippedCount       = $results.Skipped.Count
    SuccessDetails     = $results.Success
    FailedDetails      = $results.Failed
    SkippedDetails     = $results.Skipped
}
