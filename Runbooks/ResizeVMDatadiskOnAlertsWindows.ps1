[OutputType("PSAzureOperationResponse")]
param
(
    [Parameter (Mandatory = $false)]
    [object] $WebhookData
)
$ErrorActionPreference = "stop"

if ($WebhookData) {
    # Get the data object from WebhookData
    $WebhookBody = (ConvertFrom-Json -InputObject $WebhookData.RequestBody)

    # Get the info needed to identify the VM (depends on the payload schema)
    $schemaId = $WebhookBody.schemaId
    Write-Output "schemaId: $schemaId" -Verbose
    if ($schemaId -eq "azureMonitorCommonAlertSchema") {
        # This is the common Metric Alert schema (released March 2019)
        $Essentials = [object] ($WebhookBody.data).essentials
        # Get the first target only as this script doesn't handle multiple
        $alertTargetIdArray = (($Essentials.alertTargetIds)[0]).Split("/")
        $SubId = ($alertTargetIdArray)[2]
        $ResourceGroupName = ($alertTargetIdArray)[4]
        $ResourceType = ($alertTargetIdArray)[6] + "/" + ($alertTargetIdArray)[7]
        $ResourceName = ($alertTargetIdArray)[-1]
        # Add the resource ID of the impacted VM
        $ResourceId = ($Essentials.alertTargetIds)[0]
        $status = $Essentials.monitorCondition
        # Add the disk drive letter
        $AlertContext = [object] ($WebhookBody.data).alertContext
        $Drive = (($AlertContext.condition.allOf[0].dimensions) | Where-Object { $_.name -eq "Disk" }).value
        $DriveLetter = $Drive.Split(":")[0]
    }
    elseif ($schemaId -eq "AzureMonitorMetricAlert") {
        # This is the near-real-time Metric Alert schema
        $AlertContext = [object] ($WebhookBody.data).context
        $SubId = $AlertContext.subscriptionId
        $ResourceGroupName = $AlertContext.resourceGroupName
        $ResourceType = $AlertContext.resourceType
        $ResourceName = $AlertContext.resourceName
        $status = ($WebhookBody.data).status
    }
    elseif ($schemaId -eq "Microsoft.Insights/activityLogs") {
        # This is the Activity Log Alert schema
        $AlertContext = [object] (($WebhookBody.data).context).activityLog
        $SubId = $AlertContext.subscriptionId
        $ResourceGroupName = $AlertContext.resourceGroupName
        $ResourceType = $AlertContext.resourceType
        $ResourceName = (($AlertContext.resourceId).Split("/"))[-1]
        $status = ($WebhookBody.data).status
    }
    elseif ($schemaId -eq $null) {
        # This is the original Metric Alert schema
        $AlertContext = [object] $WebhookBody.context
        $SubId = $AlertContext.subscriptionId
        $ResourceGroupName = $AlertContext.resourceGroupName
        $ResourceType = $AlertContext.resourceType
        $ResourceName = $AlertContext.resourceName
        $status = $WebhookBody.status
    }
    else {
        # Schema not supported
        Write-Error "The alert data schema - $schemaId - is not supported."
    }

    Write-Output "status: $status" -Verbose
    if (($status -eq "Activated") -or ($status -eq "Fired")) {
        Write-Output "resourceType: $ResourceType" -Verbose
        Write-Output "resourceName: $ResourceName" -Verbose
        Write-Output "resourceGroupName: $ResourceGroupName" -Verbose
        Write-Output "subscriptionId: $SubId" -Verbose
        Write-Output "ResourceId: $ResourceId" -Verbose
        Write-Output "Drive: $Drive" -Verbose
        Write-Output "DriveLetter: $DriveLetter" -Verbose

        Write-Output "Logging in to Azure..."
        try {
            Write-Output "Logging in to Azure using Managed Identity..."
            Connect-AzAccount -Identity -Subscription $SubId
        }
        catch {
            Write-Error -Message $_.Exception
            throw $_.Exception
        }

        # Get the location info of the affected disk from OS volume/disk drive
        # Example location string: "Integrated : Bus 0 : Device 63667 : Function 30747 : Adapter 1 : Port 0 : Target 0 : LUN 0"
        $ScriptBlock = {
            param(
                [parameter(Mandatory = $true)][string]$DriveLetter
            )

            $DiskPath = (Get-Partition | Where-Object DriveLetter -eq $DriveLetter).DiskPath;
            Write-Output (Get-Disk -Path $DiskPath).Location
        }
        $Script = [scriptblock]::create($ScriptBlock)
        Write-Output "Getting disk location info..."
        $Result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $ResourceName -CommandId 'RunPowerShellScript' -ScriptString $Script -Parameter @{'DriveLetter' = $DriveLetter }
        # Debug information
        Write-Output "Get disk location command status: $($Result.Value.Status)"
        Write-Output "Get disk location command message: $($Result.Value[0].Message)"
        Write-Output "Get disk location command error: $($Result.Value[1].Message)"

        $DiskLocationArray = $Result.Value[0].Message.Split(":").Trim()
        Write-Output "DiskLocationArray: $DiskLocationArray" -Verbose

        if ($DiskLocationArray[4] -eq "Adapter 0") {
            Write-Error "It appears the affected disk is an OS disk, cannot expand the OS disk without stopping the VM."
        }
        else {
            $LunId = $DiskLocationArray[-1].Split(" ")[-1]
            $AffectedVM = Get-AzVM -ResourceId $ResourceId
            $DiskName = ($AffectedVM.StorageProfile.DataDisks | Where-Object Lun -eq $LunId).Name
            $Disk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $DiskName
            $DiskSizesArray = @(4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32767)
            $CurrentDiskSize = $Disk.DiskSizeGB
            $NewDiskSize = $DiskSizesArray[($DiskSizesArray.IndexOf($CurrentDiskSize) + 1)]
            $Disk.DiskSizeGB = $NewDiskSize
            $Disk | Update-AzDisk
            Write-Output "Disk $DiskName has been resized from $CurrentDiskSize GB to $NewDiskSize GB."

            # Expand the volume on the affected VM
            $ScriptBlock = {
                param(
                    [parameter(Mandatory = $true)][string]$DriveLetter
                )

                $Size = Get-PartitionSupportedSize -DriveLetter $DriveLetter
                Resize-Partition -DriveLetter $DriveLetter -Size $Size.SizeMax
            }
            $Script = [scriptblock]::create($ScriptBlock)
            Write-Output "Expanding the volume on the affected VM..."
            $Result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $ResourceName -CommandId 'RunPowerShellScript' -ScriptString $Script -Parameter @{'DriveLetter' = $DriveLetter }
            # Debug information
            Write-Output "Resize partition command status: $($Result.Value.Status)"
            Write-Output "Resize partition command message: $($Result.Value[0].Message)"
            Write-Output "Resize partition command error: $($Result.Value[1].Message)"
        }
    }
    else {
        # The alert status was not 'Activated' or 'Fired' so no action taken
        Write-Output ("No action taken. Alert status: " + $status) -Verbose
    }
}
else {
    # Error
    Write-Error "This runbook is meant to be started from an Azure alert webhook only."
}