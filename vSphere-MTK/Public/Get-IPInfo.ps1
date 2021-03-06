function Get-IPInfo {
    [cmdletbinding()]
    param (
     [Parameter(ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)][String[]]$ComputerName = $env:computername,
     [Parameter()][String[]]$ExportPath
    )
    
    begin {
        #Ensures the remote machine execution policy will allow the Set-IPInfo cmdlet to run post conversion
        try{
            Invoke-Command -ComputerName $ComputerName -ErrorAction Stop -ScriptBlock {
                if((Get-ExecutionPolicy) -eq "Restricted"){
                    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
                }
                else{
                    $ExecutionPolicy = Get-ExecutionPolicy
                    Write-Verbose -Message "The execution policy on $ComputerName is set to $ExecutionPolicy"
                }
            }
        }
        catch{
            Write-Warning -Message "Unable to set the Execution Policy on the remote system $ComputerName. Ensure the remote system has the remote execution policy set to RemoteSigned by running 'Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force'"
        }
    }
    process {
        #Sets the output directory based on parameter input, if any
        $CurrentDir = ((Get-Location).Path + "\")
        if ($ExportPath){
            if ([string]::IsNullOrWhiteSpace($ExportPath)){
                $ExportPath = $CurrentDir
                Write-Warning -Message "The specified ExportPath is invalid. The file will be exported to $ExportPath"
            }
            else{
                if (Test-Path $ExportPath) {
                    if ($ExportPath -like "*/" -or $ExportPath -like "*\"){
                        write-host "IP Configration(s) will be exported to $ExportPath"
                    }
                    else{
                        $ExportPath = ($ExportPath).Trim() + "\"
                        write-host "IP Configration(s) will be exported to $ExportPath"
                    }
                }
                else{
                    Write-Warning -Message "The specified ExportPath cannot be reached. The file will be exported to $CurrentDir"
                    $ExportPath = $CurrentDir
                    write-host "IP Configration(s) will be exported to $ExportPath"
                }
            }
        }
        else{
            $ExportPath = $CurrentDir
            write-host "IP Configration(s) will be exported to $ExportPath"
        }
        foreach ($Computer in $ComputerName) {
            if(Test-Connection -ComputerName $Computer -Count 1 -ea 0) {
                try {
                $nics = Get-WmiObject Win32_NetworkAdapterConfiguration -ComputerName $Computer -EA Stop | Where-Object {$_.IPEnabled}
                $Output = @()
                }
                catch {
                    Write-Warning "Error occurred while querying $computer."
                    Continue
                }
                foreach ($nic in $nics) {
                    $nicName = (Get-WmiObject Win32_NetworkAdapter -ComputerName $Computer | Where-Object {$_.DeviceID -eq $nic.Index}).NetConnectionID
                    if ($nicName){
                        $IPAddress  = $nic.IpAddress | Sort-Object
                        $IPAddressCount = ($nic.IPAddress).count
                        $SubnetMask  = $nic.IPSubnet[0]
                        $DefaultGateway = $nic.DefaultIPGateway
                        $DNSServers  = $nic.DNSServerSearchOrder
                        $WINS1 = $nic.WINSPrimaryServer
                        $WINS2 = $nic.WINSSecondaryServer   
                        if ([string]::IsNullOrEmpty($WINS1) -and [string]::IsNullOrEmpty($WINS2)){
                            Write-Verbose -Message "No WINS values present"
                            $WINS = ""
                        }
                        else{
                            $WINS = "$WINS1,$WINS2" 
                        }
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
                        $OutputObj | Add-Member -MemberType NoteProperty -Name WINSServers -Value $WINS       
                        $OutputObj | Add-Member -MemberType NoteProperty -Name MACAddress -Value $MACAddress
                        $OutputObj
                        $Output += $OutputObj
                    }
                }
                $Output | Export-Csv -Path ($ExportPath.Trim() + "$Computer-IPInfo.csv") -NoTypeInformation
            }
        }
    }
    end {}
}