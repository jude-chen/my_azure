<#
DISCLAIMER:
The information contained in this script and any accompanying materials (including, but not limited to, sample code) is provided “AS IS” and “WITH ALL FAULTS.” Microsoft makes NO GUARANTEES OR WARRANTIES OF ANY KIND, WHETHER EXPRESS OR IMPLIED, including but not limited to implied warranties of merchantability or fitness for a particular purpose.

The entire risk arising out of the use or performance of the script remains with you. In no event shall Microsoft, its authors, or anyone else involved in the creation, production, or delivery of the script be liable for any damages whatsoever (including, without limitation, damages for loss of business profits, business interruption, loss of business information, or other pecuniary loss) arising out of the use of or inability to use the script, even if Microsoft has been advised of the possibility of such damages.
#>

param (
    [switch]$dryRun,
    [string]$subscriptionId,
    [string]$tenantId
)

# Login to Azure
# Connect-AzAccount

if ($dryRun) {
    Write-Host "Dry-Run mode enabled. No changes will be made." -ForegroundColor Yellow
}
else {
    Write-Host "Dry-Run mode disabled. Changes will be applied." -ForegroundColor Red
}

# CSV log file path
$logFile = "AzureHybridBenefit_VMSS_Log.csv"

# Initialize log file with headers
"Timestamp,SubscriptionName,SubscriptionId,ResourceGroup,VMSSName,Status" | Out-File -FilePath $logFile

# Get subscriptions
if ($tenantId) {
    if ($subscriptionId) {
        $subscriptions = @(Get-AzSubscription -SubscriptionId $subscriptionId -TenantId $tenantId)
    }
    else {
        $subscriptions = Get-AzSubscription -TenantId $tenantId
    }
}
else {
    if ($subscriptionId) {
        $subscriptions = @(Get-AzSubscription -SubscriptionId $subscriptionId)
    }
    else {
        $subscriptions = Get-AzSubscription
    }
}

foreach ($sub in $subscriptions) {
    Write-Host "`nProcessing Subscription: $($sub.Name) ($($sub.Id))" -ForegroundColor Cyan

    # Set the current subscription
    Set-AzContext -SubscriptionId $sub.Id

    # Get all VM Scale Sets in this subscription
    $vmssList = Get-AzVmss

    foreach ($vmss in $vmssList) {
        $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Write-Host "VMSS: $($vmss.Name) in RG: $($vmss.ResourceGroupName)" -ForegroundColor Green

        # Check if OS type is Windows and AHB is not enabled
        if ($vmss.VirtualMachineProfile.StorageProfile.OsDisk.OsType -eq "Windows" -and ($null -eq $vmss.VirtualMachineProfile.LicenseType -or $vmss.VirtualMachineProfile.LicenseType -eq "None")) {
            if ($dryRun) {
                Write-Host "[Dry-Run] Would enable Azure Hybrid Benefit for VMSS: $($vmss.Name)" -ForegroundColor Yellow
                "$timestamp,$($sub.Name),$($sub.Id),$($vmss.ResourceGroupName),$($vmss.Name),Dry-Run" | Out-File -FilePath $logFile -Append
            }
            else {
                try {
                    # Enable Azure Hybrid Benefit
                    $vmss.VirtualMachineProfile.LicenseType = "Windows_Server"
                    Update-AzVmss -ResourceGroupName $vmss.ResourceGroupName -Name $vmss.Name -VirtualMachineScaleSet $vmss
                    Write-Host "Successfully updated VMSS: $($vmss.Name)" -ForegroundColor Yellow
                    "$timestamp,$($sub.Name),$($sub.Id),$($vmss.ResourceGroupName),$($vmss.Name),Success" | Out-File -FilePath $logFile -Append
                }
                catch {
                    Write-Host "Failed to update VMSS: $($vmss.Name). Error: $($_.Exception.Message)" -ForegroundColor Red
                    "$timestamp,$($sub.Name),$($sub.Id),$($vmss.ResourceGroupName),$($vmss.Name),Failed" | Out-File -FilePath $logFile -Append
                }
            }
        }
        else {
            Write-Host "Skipping VMSS: $($vmss.Name) (OS is not Windows or AHB has already been enabled)" -ForegroundColor DarkGray
        }
    }
}

Write-Host "`nScript completed. Log file saved at: $logFile" -ForegroundColor Cyan
