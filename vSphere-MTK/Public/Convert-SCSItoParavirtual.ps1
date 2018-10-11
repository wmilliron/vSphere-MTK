function Convert-SCSItoParavirtual {
    <#
    .SYNOPSIS
        This script will convert the SCSI adapter of a Windows VM running on VMware to be Paravirtual.
    .DESCRIPTION
        Prerequisites:
            1. Powershell 3.0 or newer
            2. PowerCLI
            3. Run the script as a user with administrative permissions within the OS of the VM being altered. If that same account does not have permissions to vCenter, a prompt for credentials will appear during runtime.
            4. VMware tools must be installed, updated, and running on the target VM.
        Assumptions:
            1. The target VM is connected to a network that is routable from the machine running the script.
            2. All WinRM ports are open to the target VM.
    .PARAMETER VMName
        Required parameter. Specify the name of the target VM for SCSI controller conversion. If the VM name has spaces, wrap it in quotation marks (Example ConvertSCSItoParaVirtual.ps1 -VMName "App Server 1" -vCenter vcsa01.domain.com).
    .PARAMETER vCenter
        Required parameter. Specify the name of the vCenter server appliance (or ESXi host) that the target VM resides on.
    .EXAMPLE
        Usage: ConvertSCSItoParavirtual.ps1 -VMName "appserver1" -vCenter vcsa01.domain.com
    .NOTES
        Author: wmilliron
        Date: 8/2018
        Future releases will include
        *Multi-VM conversions
        *Bug fixes
    #>

    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True)][String]$VMName,
        [Parameter(Mandatory=$True)][String]$vCenter
    )
    
    begin{
        Import-Module VMware.VimAutomation.Core
        Set-PowerCLIConfiguration -InvalidCertificateAction Prompt -Scope Session -Confirm:$false
        Clear-Host
        #Connects to the vCenter server, if the user running the script does not have permissions, a credential prompt will appear
        Write-Host "PS Module has been loaded. Please enter credentials for your vSphere environment if prompted..."
        Connect-VIServer -Server $vCenter -ErrorAction Stop
        Clear-Host
    }
    process{
        #Check to ensure the VM exists, and that the running user can connect to it via remote powershell
        $Exists = Get-Vm -name $VMName -ErrorAction SilentlyContinue  
        if ($Exists){  
            $vm = get-vm -name $VMName
            $vmview = $vm | Get-View
            $DNSName = ($vm).Guest.HostName
            if ([bool](Test-WSMan -ComputerName $DNSName -ErrorAction SilentlyContinue)  ) {
                Write-Host "The VM $VMName exists and is reachable" -ForegroundColor Green
            }
            else {
                Write-Host "The VM $VMName exists, but cannot be reached via remote powershell" -ForegroundColor Red
                Return
            }
        }  
        else {  
            Write-Host "VM named $VMName does not exist. Exiting..." -ForegroundColor Red
            Return
        }

        #Shut down the VM, then wait to confirm the change in power state to poweredoff
        if ($vm.Powerstate -eq "PoweredOn" -and $vmview.Guest.ToolsStatus -ne "toolsNotInstalled"){
            Write-Host "Verified the VM is powered on and has VMware tools installed. Proceeding with the shutdown."
            Shutdown-VMGuest -VM $VMName
            do{
                Write-Host "Waiting for $VMName to reach a powered off state..."

                #Checking the power state of the machine
                $vm = Get-VM -name $VMName
                Start-Sleep -s 5
            }
            until($vm.PowerState -eq "PoweredOff")
            Write-Host "`n `n `n$VMName is now powered off. Starting the SCSI conversion process. The VM will reboot multiple times during the procedure. `n`n" -ForegroundColor Gray
        }
        else {
            Write-Host "The VM is either not in a powered on state, or does not have VMware tools installed." -ForegroundColor Red
            Return
        }

        #Adds a new 1GB disk to a new Paravirtual controller
        Get-VM $VMName | New-HardDisk -CapacityGB 1 | New-ScsiController -Type ParaVirtual -ErrorAction Stop
        Start-Sleep -s 5

        #Starts the VM, and waits for the boot process to complete by verifying that VMtools is running.
        Start-VM -VM $VMName
        Write-Host "Waiting for VM to boot..." -ForegroundColor Gray
        Start-Sleep -s 20
        do {
            $vm = Get-VM -name $VMName
            $toolsStatus = $vm.extensionData.Guest.ToolsStatus
            Start-Sleep -s 5
        } until ($toolsStatus -eq "toolsOK")

        Invoke-Command -ComputerName $VMName  -ScriptBlock{ 
            $OS = (Get-CimInstance -ClassName Win32_OperatingSystem).Caption
            #Uses storage cmdlets on 2012 (including r2) and 2016 servers
            if ($OS -like "*2012*" -or $OS -like "*2016*") {
                #Takes the offline disk of less than 2GB in size, brings it online, and partitions as GPT
                Get-Disk | Where-Object{$_.isOffline -eq $true -and $_.Size -lt 2147483648} | Set-Disk -IsOffline $false
                Write-Host "Disk has been brought online." -ForegroundColor Green
            }
            elseif ($OS -like "*2008*") {
                $OfflineDisk = ("list disk" | diskpart | Where-Object {$_ -match "offline" -and $_ -match "1024 MB"}).subString(2,6)
                #The $DiskPartCmd variable cannot have white space before the commands in the array, hench the lack of indent
                $DiskPartCmd = @"
select $OfflineDisk
attributes disk clear readonly 
online disk 
attributes disk clear readonly 
"@
                $DiskPartCmd | diskpart
            
                #Verify the disk has been brought online
                Start-Sleep -s 5
                if(($VerifyDisk = "list disk" | diskpart | Where-Object {$_ -match "offline" -and $_ -match "1024 MB"})) 
                    { 
                        Write-Output "Failed to bring the following disk online:" 
                        $OfflineDisk
                        Return
                    } 
                    else 
                    {
                        Write-Output "Disk is now online." 
                        $VerifyDisk
                    }
            }
        }
        Start-Sleep -s 5

        #Shut down the VM, then wait to confirm the change in power state to poweredoff
        Shutdown-VMGuest -VM $VMName -Confirm:$false
        do{
            Write-Host "Waiting for $VMName to reach a powered off state..."
            #Checking the power state of the machine
            $vm = Get-VM -name $VMName
            Start-Sleep -s 5
        }
        until($vm.PowerState -eq "PoweredOff")
        Start-Sleep -s 5

        Get-HardDisk -VM $VMName | Where-Object{$_.CapacityGB -eq "1"} | Remove-HardDisk -DeletePermanently -Confirm:$false -ErrorAction Stop
        Get-VM $VMName | Get-ScsiController | Set-ScsiController -Type ParaVirtual -ErrorAction Stop
        Start-Sleep -s 5
        Start-VM $VMName
        Start-Sleep -s 20
        do {
            $vm = Get-VM -name $VMName
            $toolsStatus = $vm.extensionData.Guest.ToolsStatus
            Start-Sleep -s 5
        } until ($toolsStatus -eq "toolsOK")
        Write-Host "`n `n `n The conversion to a Paravirtual SCSI controller is complete!" -ForegroundColor Green
    }
    end{}
}