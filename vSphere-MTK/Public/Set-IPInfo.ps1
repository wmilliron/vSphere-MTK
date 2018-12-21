function Set-IPInfo{
    [cmdletbinding()]
    param (
        [Parameter(Mandatory=$True)][String]$VMName,
        [Parameter()][String[]]$ConfigurationPath
    )
    begin{
        # Performs connection and parameter checks before proceeding with function
        
        Import-Module VMware.PowerCLI
    
        #Ensure connection to vSphere
        if ($global:DefaultVIServers.IsConnected -eq $True){
            $VCName = $global:DefaultVIServers.Name
            Write-Verbose -Message "Connected to $VCName."
        }
        else {
            Connect-VIServer
        }
        #Verify VM Exists
        $Exists = Get-Vm -name $VMName -ErrorAction SilentlyContinue
        if ($Exists){
            Write-Verbose -Message "The VM $VMName exists in $VCName."
        }  
        else {  
            Write-Error -Message "VM named $VMName does not exist. Exiting..." -ForegroundColor Red
            Return
        }
    }
    process{      
        #Verifies the provided configuration path
        if (Test-Path $ConfigurationPath){
            $IPData = Import-Csv -Path $ConfigurationPath
        }
        else {
            Write-Error -Message "$ConfigurationPath cannot be reached. Exiting..."
            Return
        }

        $NICCount = $IPData.count
        $AdapterCount = (Get-NetworkAdapter -VM $VMName).count
        if ($NICCount -ne $AdapterCount){
            Write-Error -Message "The number of adapters required by the provided configuration file does not match the number of adapters on the VM."
            return
        }
        #Harvests the Network Adapter data from the VM
        $cred = Get-Credential -Message "Please enter credentials with administrative access to $VMName."
        $code = @'
            Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object{$_.IPEnabled -eq $true} | Select-Object Index,Description,IPAddress,IPEnabled | ConvertTo-CSV -NoTypeInformation
'@
        $Invoke = @{
            VM = "$VMName"
            ScriptType = 'PowerShell'
            ScriptText = $code
            GuestUser = $cred.UserName
            GuestPassword = $cred.Password
        }

        $Adapters = (Invoke-VMScriptPlus @Invoke -ErrorAction Stop).ScriptOutput | ConvertFrom-Csv
        
        #The below values are used for debugging
        $OSNICCount = $Adapters.count
        Write-Verbose -Message "Config file NICCount is $NICCount"
        Write-Verbose -Message "Vsphere adapter count is $AdapterCount"
        Write-Verbose -Message "OS NIC count is $OSNICCount"
        Write-Verbose -Message "NIC Data returned from the VMs OS: `n $adapters"


        #Compares the extracted adapter count to the VM-NIC count before proceeding.
        if ($NICCount -ne $Adapters.count){
            Write-Error -Message "The number of adapters required by the provided configuration file does not match the number of adapters queried from inside the Windows vm."
            return
        }
        
        #Attempts to set IP configuration
        try{
            for ($i=0; $i -lt $Adapters.count; $i++){
                $NICName = ($IPData[$i].NICName)
                #Puts the IP information into a string that looks like an array to be passed through the Invoke funtion into the guest OS
                $ip = ($IPData[$i].IPAddress)
                $IPs = ($ip -split ",")
                $ip = $ip | ForEach-Object {$_ -replace ',(.*?)','","$1'}
                $ip = "`"$ip`"" -f $ip
                $ip = "@($ip)"
                #Puts the subnet mask information into a string that looks like an array to be passed through the Invoke funtion into the guest OS
                #This one requires one mask for each IP, so a counter is used to iterate the string
                $subnet = ($IPData[$i].SubnetMask)
                $mask = "@(`"$subnet`""
                for ($c=1; $c -lt $IPs.count; $c++){
                    $mask += ",`"$subnet`""
                }
                $mask = $mask + ")"
                $gateway = ($IPData[$i].Gateway)
                #Puts the DNS information into a string that looks like an array to be passed through the Invoke funtion into the guest OS
                $dns = ($IPData[$i].DNSServers) | ForEach-Object {$_ -replace ',(.*?)','","$1'}
                $dns = "`"$dns`"" -f $dns
                #Puts the WINS information into a string that appears like an array to be passed through the Invoke funtion into the guest OS
                if ([string]::IsNullOrEmpty($IPData[$i].WINSServers)){
                    $wins = ""
                }
                else {
                    $wins = ($IPData[$i].WINSServers) | ForEach-Object {$_ -replace ',(.*?)','","$1'}
                }
                
                $AdapterIndex = $Adapters[$i].Index

                $code = @"
                `$adapter = Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object{`$_.Index -eq $AdapterIndex}
                `$OSNICName = Get-WmiObject Win32_NetworkAdapter | Where-Object {`$_.DeviceID -eq $AdapterIndex}
                `$OSNICName.NetConnectionID = "$NICName"
                `$OSNICName.put()
                `$OSAdapterIndex = `$adapter.Index 
                Write-Output "OS NIC index is `$OSAdapterIndex"
                Write-Output "Injected NIC index is $AdapterIndex"
                `$adapter.EnableStatic($ip,$mask)
                `$adapter.SetGateways("$gateway")
                `$adapter.SetDNSServerSearchOrder(@($dns))
                `$adapter.SetWINSServer("$wins")
                `$adapter.SetDynamicDNSRegistration(`$true,`$true)
"@
                $Invoke1 = @{
                    VM = "$VMName"
                    ScriptType = 'PowerShell'
                    ScriptText = $code
                    GuestUser = $cred.UserName
                    GuestPassword = $cred.Password
                }
                Invoke-VMScriptPlus @Invoke1 -ErrorAction Stop
            }
        }
        catch {
            Write-Error -Message "Unable to invoke the code to set network configuration."
            return
        }   
    }
    end {}
}