# Login to Azure
Connect-AzAccount -Identity

# Define your subscription IDs
$subscriptionIds = @("xxxxxxxxxxxxxxxxxxxxxxxxxxx") # Add your subscription IDs here

# Define the retention period in days
$retentionDays = 14

foreach ($subscriptionId in $subscriptionIds) {
    # Select the subscription
    Select-AzSubscription -SubscriptionId $subscriptionId
    # Get all unattached managed disks
    $unattachedDisks = Get-AzDisk | Where-Object { $_.ManagedBy -eq $null }
    Write-Output "Found $($unattachedDisks.Count) unattached disks in subscription: $subscriptionId"
    foreach ($disk in $unattachedDisks) {
        # Get the activity log for the disk resource for the past $retentionDays days
        Write-Output "Checking activity logs for disk: $($disk.Name) in subscription: $subscriptionId"
        $activityLogs = Get-AzActivityLog -ResourceId $disk.Id -StartTime $((Get-Date).AddDays(-$retentionDays))
        # To be more precise, filter the logs by the category "Administrative"
        $administrativeActivityLogs = $activityLogs | Where-Object { $_.Category -eq "Administrative" }
        if ($administrativeActivityLogs.Count -eq 0) {
            Write-Output "Disk $($disk.Name) has no activity in the last $retentionDays days, it will be deleted!"
            # Create a snapshot of the disk
            $snapshotConfig = New-AzSnapshotConfig -SourceUri $disk.Id -Location $disk.Location -CreateOption Copy -SkuName Standard_LRS
            $snapshotName = "$($disk.Name)-snapshot"
            New-AzSnapshot -ResourceGroupName $disk.ResourceGroupName -SnapshotName $snapshotName -Snapshot $snapshotConfig
            Write-Output "Created snapshot for disk: $($disk.Name) in subscription: $subscriptionId"
            # Delete the unattached disk if no activity in the last $retentionDays days
            Remove-AzDisk -ResourceGroupName $disk.ResourceGroupName -DiskName $disk.Name -Force
            Write-Output "Deleted unattached disk: $($disk.Name) in subscription: $subscriptionId"
        }
        else {
            Write-Output "Disk $($disk.Name) has activity in the last $retentionDays days and will not be deleted."
        }
    }
}