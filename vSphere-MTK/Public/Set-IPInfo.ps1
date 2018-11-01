function Set-IPInfo{
    [cmdletbinding()]
    param (
        [Parameter(Mandatory=$True)][String]$VMName,
        [Parameter()][String[]]$ConfigurationPath
    )
    begin{
        Import-Module VMware.PowerCLI
        #Ensure connection to vSphere
        try{
            Get-VIServer -ErrorAction stop
        }
        catch{
            Connect-VIServer -Message "Please connect to vSphere.."
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
        $Invoke = @{
            VM = "$VMName"
            ScriptType = 'PowerShell'
            ScriptText = $code
            GuestUser = $cred.UserName
            GuestPassword = $cred.Password
        }
        try{
            $code = @'
            Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object{$_.IPEnabled -eq $true}
'@

            $Adapters = Invoke-VMScriptPlus @Invoke -ErrorAction Stop 
        }
        catch{
            Write-Error -Message "Unable to collect the NIC information from the VM"
            return
        }
        try{
            for ($i=0; $i -le $Adapters.count; $i++){
                $ip = ($IPData[$i].IPAddress)
                $subnet = ($IPData[$i].SubnetMask)
                $gateway = ($IPData[$i].Gateway)
                $dns = ($IPData[$i].DNSServers)
                $code = @"
                $Adapters[$i].EnableStatic($ip,$subnet)
                $Adapters[$i].SetGateways($gateway)
                $Adapters[$i].SetDNSServerSearchOrder($dns)
                $Adapters[$i].SetDynamicDNSRegistration("TRUE")
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