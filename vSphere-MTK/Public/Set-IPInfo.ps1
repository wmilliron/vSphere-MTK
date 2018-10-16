function Set-IPInfo{
    [cmdletbinding()]
    param (
        [Parameter(Mandatory=$True)][String]$VMName,
        [Parameter()][String[]]$ConfigurationPath
    )
    begin{
        try{
            Get-VIServer -ErrorAction stop
        }
        catch{
            Connect-VIServer
        }
    }
    process{
        #Verify VM Exists
        $Exists = Get-Vm -name $VMName -ErrorAction SilentlyContinue  
        if ($Exists){  
            Write-Host "$VMName found."
        }  
        else {  
            Write-Host "VM named $VMName does not exist. Exiting..." -ForegroundColor Red
            Return
        }
        
        if (Test-Path $ConfigurationPath){
            $IPData = Import-Csv -Path $ConfigurationPath
        }
        else{
            Write-Error -Message "$ConfigurationPath cannot be reached. Exiting."
            Return
        }


    }
    end{}
}