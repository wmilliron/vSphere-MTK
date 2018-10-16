function Set-IPInfo{
    [cmdletbinding()]
    param (
     [Parameter(ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)][String[]]$ComputerName = $env:computername,
     [Parameter()][String[]]$ConfigurationPath
    )
    begin{
        try{
            Get-VIServer -erroraction stop
        }
        catch{
            connect-viserver
        }
    }
    process{
        #Verify VM Exists
        $Exists = Get-Vm -name $ComputerName -ErrorAction SilentlyContinue  
        if ($Exists){  
            Write-Host "$ComputerName found."
        }  
        else {  
            Write-Host "VM named $ComputerName does not exist. Exiting..." -ForegroundColor Red
            Return
        }
        
    }
    end{}
}