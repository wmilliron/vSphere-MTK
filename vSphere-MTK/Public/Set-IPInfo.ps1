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
        #$nl = [System.Environment]::NewLine
        #$Adapters = ($Adapters).Trim()
        #$Adapters = ($Adapters -Split("$nl"))
        #$OSNICCount = $Adapters.count

        #write-host $adapters
        #write-host "Config file NICCount is $NICCount"
        #write-host "Vsphere adapter count is $AdapterCount"
        #write-host "OS NIC count is $OSNICCount"

        #Compares the extracted adapter count to the VM-NIC count before proceeding.
        if ($NICCount -ne $Adapters.count){
            Write-Error -Message "The number of adapters required by the provided configuration file does not match the number of adapters queried from inside the Windows vm."
            return
        }
        
        #Attempts to set IP configuration
        try{
            for ($i=0; $i -lt $Adapters.count; $i++){
                #Puts the IP information into a string that looks like an array to be passed as a variable through the Invoke
                $ip = ($IPData[$i].IPAddress)
                $IPs = ($ip -split ",")
                $ip = $ip | ForEach-Object { $_ -replace ',(.*?)','","$1' }
                $ip = "`"$ip`"" -f $ip
                $ip = "@($ip)"
                #Puts the subnet mask information into a string that looks like an array to be passed as a variable through the Invoke
                #This one requires one mask for each IP, so a counter is used to iterate the string
                $subnet = ($IPData[$i].SubnetMask)
                $mask = "@(`"$subnet`""
                for ($c=1; $c -lt $IPs.count; $c++){
                    $mask += ",`"$subnet`""
                }
                $mask = $mask + ")"
                $gateway = ($IPData[$i].Gateway)
                #Puts the DNS information into a string that looks like an array to be passed as a variable through the Invoke
                $dns = ($IPData[$i].DNSServers) | ForEach-Object { $_ -replace ',(.*?)','","$1' }
                $dns = "`"$dns`"" -f $dns
                $AdapterIndex = $Adapters[$i].Index

                $code = @"
                `$adapter = Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object{`$_.Index -eq $AdapterIndex}
                `$OSAdapterIndex = `$adapter.Index 
                write-host "OS index is `$OSAdapterIndex"
                write-host "Injected index is $AdapterIndex"
                `$adapter.EnableStatic($ip,$mask)
                `$adapter.SetGateways("$gateway")
                `$adapter.SetDNSServerSearchOrder(@($dns))
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
        catch{
            Write-Error -Message "Unable to invoke the code to set network configuration."
            return
        }   
    }
    end{}
}