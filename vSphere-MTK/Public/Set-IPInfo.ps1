function Set-IPInfo{
    [cmdletbinding()]
    param (
        [Parameter(Mandatory=$True)][String]$VMName,
        [Parameter()][String[]]$ConfigurationPath
    )
    begin{
        Import-Module VMware.PowerCLI
        #Ensure connection to vSphere
        if ($global:DefaultVIServers.IsConnected -eq $True){
            $VCName = $global:DefaultVIServers.Name
            Write-Host "Already connected to $VCName. Continuing..."
        }
        else {
            Connect-VIServer
        }
        #Verify VM Exists
        $Exists = Get-Vm -name $VMName -ErrorAction SilentlyContinue
        if ($Exists){  
            Write-Host "$VMName found."
        }  
        else {  
            Write-Host "VM named $VMName does not exist. Exiting..." -ForegroundColor Red
            Return
        }
    }
    process{      
        #Verifies the provided configuration path
        if (Test-Path $ConfigurationPath){
            $IPData = Import-Csv -Path $ConfigurationPath
        }
        else{
            Write-Error -Message "$ConfigurationPath cannot be reached. Exiting."
            Return
        }

        $NICCount = $IPData.count
        $AdapterCount = (Get-NetworkAdapter -VM $VMName).count
        if ($NICCount -ne $AdapterCount){
            Write-Error -Message "The number of adapters required by the provided configuration file does not match the number of adapters on the VM."
            return
        }
        #Harvests the Network Adapter data from the VM
        $cred = Get-Credential -Message "Please enter credentials with administrative access to the virtual machine's operating system."
        $code = @'
            Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object{$_.IPEnabled -eq $true} | Select-Object * 
'@
        $Invoke = @{
            VM = "$VMName"
            ScriptType = 'PowerShell'
            ScriptText = $code
            GuestUser = $cred.UserName
            GuestPassword = $cred.Password
        }

            $Adapters = (Invoke-VMScriptPlus @Invoke -ErrorAction Stop).ScriptOutput
            $nl = [System.Environment]::NewLine
            $Adapters = ($Adapters).Trim()
            $Adapters = ($Adapters -Split("$nl$nl"))
            $OSNICCount = $Adapters.count

        #The below values are used for debugging
        write-host "Config file NICCount is $NICCount"
        write-host "Vsphere adapter count is $AdapterCount"
        write-host "OS NIC count is $OSNICCount"

        #Compares the extracted adapter count to the VM-NIC count before proceeding.
        if ($NICCount -ne $Adapters.count){
            Write-Error -Message "The number of adapters required by the provided configuration file does not match the number of adapters queried from inside the Windows vm."
            return
        }
        
        #Attempts to set IP configuration
        try{
            for ($i=0; $i -lt $Adapters.count; $i++){
                $ip = ($IPData[$i].IPAddress)
                $subnet = ($IPData[$i].SubnetMask)
                $gateway = ($IPData[$i].Gateway)
                $dns = ($IPData[$i].DNSServers)
                $code = @"
                $adapter = Get-WmiObject Win32NetworkAdapterConfiguration | Where-Object{$_.InterfaceIndex -eq $Adapters[$i].Index} 
                $adapter.EnableStatic($ip,$subnet)
                $adapter.SetGateways($gateway)
                $adapter.SetDNSServerSearchOrder($dns)
                $adapter.SetDynamicDNSRegistration("TRUE")
"@
                Invoke-VMScriptPlus @Invoke -ErrorAction Stop
            }
        }
        catch{
            Write-Error -Message "Unable to invoke the code to set network configuration."
            return
        }   
    }
    end{}
}