
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
$logFile = "AzureHybridBenefitLog.csv"

# Initialize log file with headers
"Timestamp,SubscriptionName,SubscriptionId,ResourceGroup,VMName,Status" | Out-File -FilePath $logFile

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

    # Get all Windows Server VMs in this subscription
    $vms = Get-AzVM | Where-Object { $_.StorageProfile.OSDisk.OsType -eq "Windows" -and ($_.LicenseType -eq $null -or $_.LicenseType -eq "None") }

    foreach ($vm in $vms) {
        $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Write-Host "VM: $($vm.Name) in RG: $($vm.ResourceGroupName)" -ForegroundColor Green

        if ($dryRun) {
            Write-Host "[Dry-Run] Would enable Azure Hybrid Benefit for VM: $($vm.Name)" -ForegroundColor Yellow
            "$timestamp,$($sub.Name),$($sub.Id),$($vm.ResourceGroupName),$($vm.Name),Dry-Run" | Out-File -FilePath $logFile -Append
        }
        else {
            try {
                # Enable Azure Hybrid Benefit
                $vm.LicenseType = "Windows_Server"
                Update-AzVM -ResourceGroupName $vm.ResourceGroupName -VM $vm
                Write-Host "Successfully updated VM: $($vm.Name)" -ForegroundColor Yellow
                "$timestamp,$($sub.Name),$($sub.Id),$($vm.ResourceGroupName),$($vm.Name),Success" | Out-File -FilePath $logFile -Append
            }
            catch {
                Write-Host "Failed to update VM: $($vm.Name). Error: $($_.Exception.Message)" -ForegroundColor Red
                "$timestamp,$($sub.Name),$($sub.Id),$($vm.ResourceGroupName),$($vm.Name),Failed" | Out-File -FilePath $logFile -Append
            }
        }
    }
}

Write-Host "`nScript completed. Log file saved at: $logFile" -ForegroundColor Cyan
