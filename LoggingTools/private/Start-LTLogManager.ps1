function Start-LTLogManager {
  $Runspace = [runspacefactory]::CreateRunspace()
  $Runspace.ApartmentState = [System.Threading.ApartmentState]::MTA
  $Runspace.Name = 'LTLogManager'
  $Runspace.ThreadOptions = 'ReuseThread'
  $LTLogManager = [powershell]::Create()
  $LTLogManager.runspace = $Runspace
  $Runspace.Open()
  
  [void]$LTLogManager.AddScript({

    Write-Host "Wirte-host"
    Write-Output "Write-Output"
    Get-Date

    Start-Sleep -Seconds 10

  })

  $AsyncObject = $LTLogManager.BeginInvoke()
}