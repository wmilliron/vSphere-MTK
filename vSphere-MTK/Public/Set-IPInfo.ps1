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
        elseif ($NICCount -eq $AdapterCount){

        }
        else{
            Write-Error -Message "Unable to compare the number of NICs present to the number required."
            return
        }




        #Pass code and parameters to Invoke-VMScriptPlus
        $cred = Get-Credential -Message "Please enter credentials with administrative access to the virtual machine's operating system."
        $Invoke = @{
            VM = $VMName
            ScriptType = 'PowerShell'
            ScriptText = $code
            GuestCredential = $cred
        }
        Invoke-VMScriptPlus @Invoke
    }
    end{}
}