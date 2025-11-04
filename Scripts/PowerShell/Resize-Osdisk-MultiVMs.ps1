<#
DISCLAIMER:
The information contained in this script and any accompanying materials (including, but not limited to, sample code) is provided “AS IS” and “WITH ALL FAULTS.” Microsoft makes NO GUARANTEES OR WARRANTIES OF ANY KIND, WHETHER EXPRESS OR IMPLIED, including but not limited to implied warranties of merchantability or fitness for a particular purpose.

The entire risk arising out of the use or performance of the script remains with you. In no event shall Microsoft, its authors, or anyone else involved in the creation, production, or delivery of the script be liable for any damages whatsoever (including, without limitation, damages for loss of business profits, business interruption, loss of business information, or other pecuniary loss) arising out of the use of or inability to use the script, even if Microsoft has been advised of the possibility of such damages.
#>

param(
    # the path to the file that contains the list of VMs with VM name, resource group name, and subscription ID, separated by commas
    [Parameter(Mandatory = $true)]
    [string]$VMListFilePath,
    # The original OS disk size in GB for verification purpose
    [Parameter(Mandatory = $true)]
    [int]$OriginalDiskSizeGB,
    # The new OS disk size in GB
    [Parameter(Mandatory = $true)]
    [int]$NewDiskSizeGB,
    # Optional: expand the file system (C: drive) after resizing the OS disk
    [Parameter(Mandatory = $true)]
    [switch]$ExpandFileSystem
)

[string[]]$VMList = Get-Content $VMListFilePath

ForEach ($VMInfo in $VMList) {
    $VMInfoArray = $VMInfo.Split(",")
    $VMName = $VMInfoArray[0]
    $ResourceGroupName = $VMInfoArray[1]
    $SubId = $VMInfoArray[2]

    Write-Output "VMName: $VMName" -Verbose
    Write-Output "ResourceGroupName: $ResourceGroupName" -Verbose
    Write-Output "SubscriptionId: $SubId" -Verbose

    # Connect to the subscription
    Set-AzContext -Subscription $SubId
    # Get the VM object
    $VM = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName

    # Get the OS disk object
    $OSDisk = $VM.StorageProfile.OsDisk

    # Verify the original disk size
    if ($OSDisk.DiskSizeGB -ne $OriginalDiskSizeGB) {
        Write-Error "The original disk size of VM $VMName is not $OriginalDiskSizeGB GB. The script will not process this VM."
        continue
    }

    # Shutdown and deallocate the VM
    Write-Output "Shutting down the VM $VMName and resizing the OS disk..." -Verbose
    Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Force

    # Resize the OS disk
    $Disk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $OSDisk.Name
    $Disk.DiskSizeGB = $NewDiskSizeGB
    $Disk | Update-AzDisk

    # Start the VM
    Write-Output "Starting the VM $VMName..." -Verbose
    Start-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName

    If ($ExpandFileSystem) {
        # Expand the file system
        $ScriptBlock = {
            param(
                [parameter(Mandatory = $true)][string]$DriveLetter
            )

            $Size = Get-PartitionSupportedSize -DriveLetter $DriveLetter
            Resize-Partition -DriveLetter $DriveLetter -Size $Size.SizeMax
        }
        $Script = [scriptblock]::create($ScriptBlock)
        Write-Output "Expanding the C: drive on the VM $VMName..."
        $Result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VMName -CommandId 'RunPowerShellScript' -ScriptString $Script -Parameter @{'DriveLetter' = "C" }
        # Debug information
        Write-Output "Resize file system command status: $($Result.Value.Status)"
        Write-Output "Resize file system command message: $($Result.Value[0].Message)"
        Write-Output "Resize file system command error: $($Result.Value[1].Message)"
    }

    Write-Output "OS disk of VM $VMName has been resized from $OriginalDiskSizeGB GB to $NewDiskSizeGB GB."
}
