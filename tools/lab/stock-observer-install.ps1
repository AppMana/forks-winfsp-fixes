[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9-]+$')][string]$Token)
$ErrorActionPreference='Stop'
Start-Transcript C:\lab\stock-observer-install-transcript.txt
if([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18'){
    throw 'Stock observer install requires fresh guest SYSTEM token'
}
if((Get-FileHash C:\lab\winfsp.msi).Hash -ine
    '073a70e00f77423e34bed98b86e600def93393ba5822204fac57a29324db9f7a'){
    throw 'Stock MSI digest mismatch'
}
$bootConfig=(& bcdedit.exe /enum '{current}' | Out-String)
if($LASTEXITCODE -ne 0 -or $bootConfig -match '(?im)^testsigning\s+Yes\s*$'){
    throw 'Stock lane requires test signing disabled'
}
$p=Start-Process msiexec.exe -ArgumentList '/i','C:\lab\winfsp.msi','/qn','/norestart',
    'INSTALLLEVEL=1000' -Wait -PassThru
if($p.ExitCode -notin @(0,3010)){throw "MSI exit $($p.ExitCode)"}
$drivers=@(Get-CimInstance Win32_SystemDriver | Where-Object {
    $_.Name -like 'WinFsp*' -and $_.PathName -match '(?i)winfsp[^\\]*\.sys"?$'
})
if($drivers.Count -ne 1){throw "Expected one stock WinFsp kernel service, found $($drivers.Count)"}
$drivers | Select-Object Name,State,PathName | ConvertTo-Json |
    Set-Content C:\lab\stock-driver-pre-reboot.json
(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToFileTimeUtc() |
    Set-Content C:\lab\pre-reboot.txt
Stop-Transcript
Write-Output "STOCK_OBSERVER_INSTALL_COMPLETE:$Token"
