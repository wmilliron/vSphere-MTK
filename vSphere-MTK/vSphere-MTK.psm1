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

function Get-IPInfo {
    [cmdletbinding()]
    param (
     [parameter(ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)][string[]]$ComputerName = $env:computername
    )
    
    begin {}
    process {
     foreach ($Computer in $ComputerName) {
      if(Test-Connection -ComputerName $Computer -Count 1 -ea 0) {
       try {
        $nics = Get-WmiObject Win32_NetworkAdapterConfiguration -ComputerName $Computer -EA Stop | Where-Object {$_.IPEnabled}
        $Output = @()
       } catch {
            Write-Warning "Error occurred while querying $computer."
            Continue
       }
       foreach ($nic in $nics) {
          $nicName = (Get-WmiObject Win32_NetworkAdapter -ComputerName $Computer | Where-Object {$_.DeviceID -eq $nic.Index}).NetConnectionID
          if ($nicName){
            $IPAddress  = $nic.IpAddress
            $IPAddressCount = ($nic.IPAddress).count
            $SubnetMask  = $nic.IPSubnet[0]
            $DefaultGateway = $nic.DefaultIPGateway
            $DNSServers  = $nic.DNSServerSearchOrder
            $WINS1 = $nic.WINSPrimaryServer
            $WINS2 = $nic.WINSSecondaryServer   
            $WINS = @($WINS1,$WINS2)         
            $IsDHCPEnabled = $false
            If($nic.DHCPEnabled) {
              $IsDHCPEnabled = $true
            }
            $MACAddress  = $nic.MACAddress
            $OutputObj  = New-Object -Type PSObject
            $OutputObj | Add-Member -MemberType NoteProperty -Name ComputerName -Value $Computer.ToUpper()
            $OutputObj | Add-Member -MemberType NoteProperty -Name NICName -Value $nicName
            $OutputObj | Add-Member -MemberType NoteProperty -Name IPAddress -Value ($IPAddress -join ",")
            $OutputObj | Add-Member -MemberType NoteProperty -Name IPAddressCount -Value $IPAddressCount
            $OutputObj | Add-Member -MemberType NoteProperty -Name SubnetMask -Value $SubnetMask
            $OutputObj | Add-Member -MemberType NoteProperty -Name Gateway -Value ($DefaultGateway -join ",")      
            $OutputObj | Add-Member -MemberType NoteProperty -Name IsDHCPEnabled -Value $IsDHCPEnabled
            $OutputObj | Add-Member -MemberType NoteProperty -Name DNSServers -Value ($DNSServers -join ",")     
            $OutputObj | Add-Member -MemberType NoteProperty -Name WINSServers -Value ($WINS -join ",")        
            $OutputObj | Add-Member -MemberType NoteProperty -Name MACAddress -Value $MACAddress
            $OutputObj
            $Output += $OutputObj
          }
        }
      $Output | Export-Csv -Path .\$ComputerName-IPInfo.csv -NoTypeInformation
      }
     }
    }
    end {}
}

function Remove-GhostDevices {
<#
.SYNOPSIS
   Removes ghost devices from your system
 
.DESCRIPTION
    This script will remove ghost devices from your system.  These are devices that are present but have a "InstallState" as false.  These devices are typically shown as 'faded'
    in Device Manager, when you select "Show hidden and devices" from the view menu.  This script has been tested on Windows 2008 R2 SP2 with PowerShell 3.0, 5.1 and Server 2012R2
    with Powershell 4.0.  There is no warranty with this script.  Please use cautiously as removing devices is a destructive process without an undo. Original credit for this script
    goes to Alexander Boersch with further modifications by Trentent Tye (https://theorypc.ca/2017/06/28/remove-ghost-devices-natively-with-powershell/).
 
.PARAMETER filterByFriendlyName 
This parameter will exclude devices that match the partial name provided. This paramater needs to be specified in an array format for all the friendly names you want to be excluded from removal.
"Intel" will match "Intel(R) Xeon(R) CPU E5-2680 0 @ 2.70GHz". "Loop" will match "Microsoft Loopback Adapter".
 
.PARAMETER filterByClass 
This parameter will exclude devices that match the class name provided. This paramater needs to be specified in an array format for all the class names you want to be excluded from removal.
This is an exact string match so "Disk" will not match "DiskDrive".
 
.PARAMETER listDevicesOnly 
listDevicesOnly will output a table of all devices found in this system.
 
.PARAMETER listGhostDevicesOnly 
listGhostDevicesOnly will output a table of all 'ghost' devices found in this system.
 
.EXAMPLE
Lists all devices
. Remove-GhostDevices -listDevicesOnly
 
.EXAMPLE
Save the list of devices as an object
$Devices = . Remove-GhostDevices -listDevicesOnly
 
.EXAMPLE
Lists all 'ghost' devices
. Remove-GhostDevices -listGhostDevicesOnly
 
.EXAMPLE
Save the list of 'ghost' devices as an object
$ghostDevices = . Remove-GhostDevices -listGhostDevicesOnly
 
.EXAMPLE
Remove all ghost devices EXCEPT any devices that have "Intel" or "Citrix" in their friendly name
. Remove-GhostDevices -filterByFriendlyName @("Intel","Citrix")
 
.EXAMPLE
Remove all ghost devices EXCEPT any devices that are apart of the classes "LegacyDriver" or "Processor"
. Remove-GhostDevices -filterByClass @("LegacyDriver","Processor")
 
.EXAMPLE 
Remove all ghost devices EXCEPT for devices with a friendly name of "Intel" or "Citrix" or with a class of "LegacyDriver" or "Processor"
. Remove-GhostDevices -filterByClass @("LegacyDriver","Processor") -filterByFriendlyName @("Intel","Citrix")
 
.NOTES
Permission level has not been tested.  It is assumed you will need to have sufficient rights to uninstall devices from device manager for this script to run properly.
#>
 
Param(
    [array]$FilterByClass,
    [array]$FilterByFriendlyName,
    [switch]$listDevicesOnly,
    [switch]$listGhostDevicesOnly
  )
   
  #parameter futzing
  $removeDevices = $true
  if ($FilterByClass -ne $null) {
      write-host "FilterByClass: $FilterByClass"
  }
   
  if ($FilterByFriendlyName -ne $null) {
      write-host "FilterByFriendlyName: $FilterByFriendlyName"
  }
   
  if ($listDevicesOnly -eq $true) {
      write-host "List devices without removal: $listDevicesOnly"
      $removeDevices = $false
  }
   
  if ($listGhostDevicesOnly -eq $true) {
      write-host "List ghost devices without removal: $listGhostDevicesOnly"
      $removeDevices = $false
  }
   
   
   
  $setupapi = @"
using System;
using System.Diagnostics;
using System.Text;
using System.Runtime.InteropServices;
namespace Win32
{
    public static class SetupApi
    {
        // 1st form using a ClassGUID only, with Enumerator = IntPtr.Zero
        [DllImport("setupapi.dll", CharSet = CharSet.Auto)]
        public static extern IntPtr SetupDiGetClassDevs(
            ref Guid ClassGuid,
            IntPtr Enumerator,
            IntPtr hwndParent,
            int Flags
        );
    
        // 2nd form uses an Enumerator only, with ClassGUID = IntPtr.Zero
        [DllImport("setupapi.dll", CharSet = CharSet.Auto)]
        public static extern IntPtr SetupDiGetClassDevs(
            IntPtr ClassGuid,
            string Enumerator,
            IntPtr hwndParent,
            int Flags
        );
        
        [DllImport("setupapi.dll", CharSet = CharSet.Auto, SetLastError = true)]
        public static extern bool SetupDiEnumDeviceInfo(
            IntPtr DeviceInfoSet,
            uint MemberIndex,
            ref SP_DEVINFO_DATA DeviceInfoData
        );
    
        [DllImport("setupapi.dll", SetLastError = true)]
        public static extern bool SetupDiDestroyDeviceInfoList(
            IntPtr DeviceInfoSet
        );
        [DllImport("setupapi.dll", CharSet = CharSet.Auto, SetLastError = true)]
        public static extern bool SetupDiGetDeviceRegistryProperty(
            IntPtr deviceInfoSet,
            ref SP_DEVINFO_DATA deviceInfoData,
            uint property,
            out UInt32 propertyRegDataType,
            byte[] propertyBuffer,
            uint propertyBufferSize,
            out UInt32 requiredSize
        );
        [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Auto)]
        public static extern bool SetupDiGetDeviceInstanceId(
            IntPtr DeviceInfoSet,
            ref SP_DEVINFO_DATA DeviceInfoData,
            StringBuilder DeviceInstanceId,
            int DeviceInstanceIdSize,
            out int RequiredSize
        );

    
        [DllImport("setupapi.dll", CharSet = CharSet.Auto, SetLastError = true)]
        public static extern bool SetupDiRemoveDevice(IntPtr DeviceInfoSet,ref SP_DEVINFO_DATA DeviceInfoData);
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct SP_DEVINFO_DATA
    {
        public uint cbSize;
        public Guid classGuid;
        public uint devInst;
        public IntPtr reserved;
    }
    [Flags]
    public enum DiGetClassFlags : uint
    {
        DIGCF_DEFAULT       = 0x00000001,  // only valid with DIGCF_DEVICEINTERFACE
        DIGCF_PRESENT       = 0x00000002,
        DIGCF_ALLCLASSES    = 0x00000004,
        DIGCF_PROFILE       = 0x00000008,
        DIGCF_DEVICEINTERFACE   = 0x00000010,
    }
    public enum SetupDiGetDeviceRegistryPropertyEnum : uint
    {
        SPDRP_DEVICEDESC          = 0x00000000, // DeviceDesc (R/W)
        SPDRP_HARDWAREID          = 0x00000001, // HardwareID (R/W)
        SPDRP_COMPATIBLEIDS           = 0x00000002, // CompatibleIDs (R/W)
        SPDRP_UNUSED0             = 0x00000003, // unused
        SPDRP_SERVICE             = 0x00000004, // Service (R/W)
        SPDRP_UNUSED1             = 0x00000005, // unused
        SPDRP_UNUSED2             = 0x00000006, // unused
        SPDRP_CLASS               = 0x00000007, // Class (R--tied to ClassGUID)
        SPDRP_CLASSGUID           = 0x00000008, // ClassGUID (R/W)
        SPDRP_DRIVER              = 0x00000009, // Driver (R/W)
        SPDRP_CONFIGFLAGS         = 0x0000000A, // ConfigFlags (R/W)
        SPDRP_MFG             = 0x0000000B, // Mfg (R/W)
        SPDRP_FRIENDLYNAME        = 0x0000000C, // FriendlyName (R/W)
        SPDRP_LOCATION_INFORMATION    = 0x0000000D, // LocationInformation (R/W)
        SPDRP_PHYSICAL_DEVICE_OBJECT_NAME = 0x0000000E, // PhysicalDeviceObjectName (R)
        SPDRP_CAPABILITIES        = 0x0000000F, // Capabilities (R)
        SPDRP_UI_NUMBER           = 0x00000010, // UiNumber (R)
        SPDRP_UPPERFILTERS        = 0x00000011, // UpperFilters (R/W)
        SPDRP_LOWERFILTERS        = 0x00000012, // LowerFilters (R/W)
        SPDRP_BUSTYPEGUID         = 0x00000013, // BusTypeGUID (R)
        SPDRP_LEGACYBUSTYPE           = 0x00000014, // LegacyBusType (R)
        SPDRP_BUSNUMBER           = 0x00000015, // BusNumber (R)
        SPDRP_ENUMERATOR_NAME         = 0x00000016, // Enumerator Name (R)
        SPDRP_SECURITY            = 0x00000017, // Security (R/W, binary form)
        SPDRP_SECURITY_SDS        = 0x00000018, // Security (W, SDS form)
        SPDRP_DEVTYPE             = 0x00000019, // Device Type (R/W)
        SPDRP_EXCLUSIVE           = 0x0000001A, // Device is exclusive-access (R/W)
        SPDRP_CHARACTERISTICS         = 0x0000001B, // Device Characteristics (R/W)
        SPDRP_ADDRESS             = 0x0000001C, // Device Address (R)
        SPDRP_UI_NUMBER_DESC_FORMAT       = 0X0000001D, // UiNumberDescFormat (R/W)
        SPDRP_DEVICE_POWER_DATA       = 0x0000001E, // Device Power Data (R)
        SPDRP_REMOVAL_POLICY          = 0x0000001F, // Removal Policy (R)
        SPDRP_REMOVAL_POLICY_HW_DEFAULT   = 0x00000020, // Hardware Removal Policy (R)
        SPDRP_REMOVAL_POLICY_OVERRIDE     = 0x00000021, // Removal Policy Override (RW)
        SPDRP_INSTALL_STATE           = 0x00000022, // Device Install State (R)
        SPDRP_LOCATION_PATHS          = 0x00000023, // Device Location Paths (R)
        SPDRP_BASE_CONTAINERID        = 0x00000024  // Base ContainerID (R)
    }
}
"@
  Add-Type -TypeDefinition $setupapi
      
      #Array for all removed devices report
      $removeArray = @()
      #Array for all devices report
      $array = @()
   
      $setupClass = [Guid]::Empty
      #Get all devices
      $devs = [Win32.SetupApi]::SetupDiGetClassDevs([ref]$setupClass, [IntPtr]::Zero, [IntPtr]::Zero, [Win32.DiGetClassFlags]::DIGCF_ALLCLASSES)
   
      #Initialise Struct to hold device info Data
      $devInfo = new-object Win32.SP_DEVINFO_DATA
      $devInfo.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($devInfo)
   
      #Device Counter
      $devCount = 0
      #Enumerate Devices
      while([Win32.SetupApi]::SetupDiEnumDeviceInfo($devs, $devCount, [ref]$devInfo)){
      
          #Will contain an enum depending on the type of the registry Property, not used but required for call
          $propType = 0
          #Buffer is initially null and buffer size 0 so that we can get the required Buffer size first
          [byte[]]$propBuffer = $null
          $propBufferSize = 0
          #Get Buffer size
          [Win32.SetupApi]::SetupDiGetDeviceRegistryProperty($devs, [ref]$devInfo, [Win32.SetupDiGetDeviceRegistryPropertyEnum]::SPDRP_FRIENDLYNAME, [ref]$propType, $propBuffer, 0, [ref]$propBufferSize) | Out-null
          #Initialize Buffer with right size
          [byte[]]$propBuffer = New-Object byte[] $propBufferSize
   
          #Get HardwareID
          $propTypeHWID = 0
          [byte[]]$propBufferHWID = $null
          $propBufferSizeHWID = 0
          [Win32.SetupApi]::SetupDiGetDeviceRegistryProperty($devs, [ref]$devInfo, [Win32.SetupDiGetDeviceRegistryPropertyEnum]::SPDRP_HARDWAREID, [ref]$propTypeHWID, $propBufferHWID, 0, [ref]$propBufferSizeHWID) | Out-null
          [byte[]]$propBufferHWID = New-Object byte[] $propBufferSizeHWID
   
          #Get DeviceDesc (this name will be used if no friendly name is found)
          $propTypeDD = 0
          [byte[]]$propBufferDD = $null
          $propBufferSizeDD = 0
          [Win32.SetupApi]::SetupDiGetDeviceRegistryProperty($devs, [ref]$devInfo, [Win32.SetupDiGetDeviceRegistryPropertyEnum]::SPDRP_DEVICEDESC, [ref]$propTypeDD, $propBufferDD, 0, [ref]$propBufferSizeDD) | Out-null
          [byte[]]$propBufferDD = New-Object byte[] $propBufferSizeDD
   
          #Get Install State
          $propTypeIS = 0
          [byte[]]$propBufferIS = $null
          $propBufferSizeIS = 0
          [Win32.SetupApi]::SetupDiGetDeviceRegistryProperty($devs, [ref]$devInfo, [Win32.SetupDiGetDeviceRegistryPropertyEnum]::SPDRP_INSTALL_STATE, [ref]$propTypeIS, $propBufferIS, 0, [ref]$propBufferSizeIS) | Out-null
          [byte[]]$propBufferIS = New-Object byte[] $propBufferSizeIS
   
          #Get Class
          $propTypeCLSS = 0
          [byte[]]$propBufferCLSS = $null
          $propBufferSizeCLSS = 0
          [Win32.SetupApi]::SetupDiGetDeviceRegistryProperty($devs, [ref]$devInfo, [Win32.SetupDiGetDeviceRegistryPropertyEnum]::SPDRP_CLASS, [ref]$propTypeCLSS, $propBufferCLSS, 0, [ref]$propBufferSizeCLSS) | Out-null
          [byte[]]$propBufferCLSS = New-Object byte[] $propBufferSizeCLSS
          [Win32.SetupApi]::SetupDiGetDeviceRegistryProperty($devs, [ref]$devInfo,[Win32.SetupDiGetDeviceRegistryPropertyEnum]::SPDRP_CLASS, [ref]$propTypeCLSS, $propBufferCLSS, $propBufferSizeCLSS, [ref]$propBufferSizeCLSS)  | out-null
          $Class = [System.Text.Encoding]::Unicode.GetString($propBufferCLSS)
   
          #Read FriendlyName property into Buffer
          if(![Win32.SetupApi]::SetupDiGetDeviceRegistryProperty($devs, [ref]$devInfo,[Win32.SetupDiGetDeviceRegistryPropertyEnum]::SPDRP_FRIENDLYNAME, [ref]$propType, $propBuffer, $propBufferSize, [ref]$propBufferSize)){
              [Win32.SetupApi]::SetupDiGetDeviceRegistryProperty($devs, [ref]$devInfo,[Win32.SetupDiGetDeviceRegistryPropertyEnum]::SPDRP_DEVICEDESC, [ref]$propTypeDD, $propBufferDD, $propBufferSizeDD, [ref]$propBufferSizeDD)  | out-null
              $FriendlyName = [System.Text.Encoding]::Unicode.GetString($propBufferDD)
              #The friendly Name ends with a weird character
              if ($FriendlyName.Length -ge 1) {
                  $FriendlyName = $FriendlyName.Substring(0,$FriendlyName.Length-1)
              }
          } else {
              #Get Unicode String from Buffer
              $FriendlyName = [System.Text.Encoding]::Unicode.GetString($propBuffer)
              #The friendly Name ends with a weird character
              if ($FriendlyName.Length -ge 1) {
                  $FriendlyName = $FriendlyName.Substring(0,$FriendlyName.Length-1)
              }
          }
   
          #InstallState returns true or false as an output, not text
          $InstallState = [Win32.SetupApi]::SetupDiGetDeviceRegistryProperty($devs, [ref]$devInfo,[Win32.SetupDiGetDeviceRegistryPropertyEnum]::SPDRP_INSTALL_STATE, [ref]$propTypeIS, $propBufferIS, $propBufferSizeIS, [ref]$propBufferSizeIS)
   
          # Read HWID property into Buffer
          if(![Win32.SetupApi]::SetupDiGetDeviceRegistryProperty($devs, [ref]$devInfo,[Win32.SetupDiGetDeviceRegistryPropertyEnum]::SPDRP_HARDWAREID, [ref]$propTypeHWID, $propBufferHWID, $propBufferSizeHWID, [ref]$propBufferSizeHWID)){
              #Ignore if Error
              $HWID = ""
          } else {
              #Get Unicode String from Buffer
              $HWID = [System.Text.Encoding]::Unicode.GetString($propBufferHWID)
              #trim out excess names and take first object
              $HWID = $HWID.split([char]0x0000)[0].ToUpper()
          }
   
          #all detected devices list
          $obj = New-Object System.Object
          $obj | Add-Member -type NoteProperty -name FriendlyName -value $FriendlyName
          $obj | Add-Member -type NoteProperty -name HWID -value $HWID
          $obj | Add-Member -type NoteProperty -name InstallState -value $InstallState
          $obj | Add-Member -type NoteProperty -name Class -value $Class
          if ($array.count -le 0) {
              #for some reason the script will blow by the first few entries without displaying the output
              #this brief pause seems to let the objects get created/displayed so that they are in order.
              Start-Sleep 1
          }
          $array += @($obj)
   
          <#
          We need to execute the filtering at this point because we are in the current device context
          where we can execute an action (eg, removal).
          InstallState : False == ghosted device
          #>
          $matchFilter = $false
          if ($removeDevices -eq $true) {
              #we want to remove devices so lets check the filters...
              if ($FilterByClass -ne $null) {
                  foreach ($ClassFilter in $FilterByClass) {
                      if ($ClassFilter -eq $Class) {
                          Write-verbose "Class filter match $ClassFilter, skipping"
                          $matchFilter = $true
                      }
                  }
              }
              if ($FilterByFriendlyName -ne $null) {
                  foreach ($FriendlyNameFilter in $FilterByFriendlyName) {
                      if ($FriendlyName -like '*'+$FriendlyNameFilter+'*') {
                          Write-verbose "FriendlyName filter match $FriendlyName, skipping"
                          $matchFilter = $true
                      }
                  }
              }
              if ($InstallState -eq $False) {
                  if ($matchFilter -eq $false) {
                      Write-Host "Attempting to removing device $FriendlyName" -ForegroundColor Yellow
                      $removeObj = New-Object System.Object
                      $removeObj | Add-Member -type NoteProperty -name FriendlyName -value $FriendlyName
                      $removeObj | Add-Member -type NoteProperty -name HWID -value $HWID
                      $removeObj | Add-Member -type NoteProperty -name InstallState -value $InstallState
                      $removeObj | Add-Member -type NoteProperty -name Class -value $Class
                      $removeArray += @($removeObj)
                      if([Win32.SetupApi]::SetupDiRemoveDevice($devs, [ref]$devInfo)){
                          Write-Host "Removed device $FriendlyName"  -ForegroundColor Green
                      } else {
                          Write-Host "Failed to remove device $FriendlyName" -ForegroundColor Red
                      }
                  } else {
                      write-host "Filter matched. Skipping $FriendlyName" -ForegroundColor Yellow
                  }
              }
          }
          $devcount++
      }
      
      #output objects so you can take the output from the script
      if ($listDevicesOnly) {
          $allDevices = $array | Sort-Object -Property FriendlyName | Format-Table
          $allDevices
          write-host "Total devices found       : $($array.count)"
          $ghostDevices = ($array | Where-Object {$_.InstallState -eq $false} | Sort-Object -Property FriendlyName)
          write-host "Total ghost devices found : $($ghostDevices.count)"
          return $allDevices | out-null
      }
   
      if ($listGhostDevicesOnly) {
          $ghostDevices = ($array | Where-Object {$_.InstallState -eq $false} | Sort-Object -Property FriendlyName)
          $ghostDevices | Format-Table
          write-host "Total ghost devices found : $($ghostDevices.count)"
          return $ghostDevices | out-null
      }
   
      if ($removeDevices -eq $true) {
          write-host "Removed devices:"
          $removeArray  | Sort-Object -Property FriendlyName | Format-Table
          write-host "Total removed devices     : $($removeArray.count)"
          return $removeArray | out-null
      }
}

