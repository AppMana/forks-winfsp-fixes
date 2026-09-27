# Called only by the fresh-VM harness. Never invoke on a cluster node.
[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9-]+$')][string]$Token)
$ErrorActionPreference='Stop'
Start-Transcript C:\lab\install-transcript.txt
$manifest = Get-Content C:\lab\output\manifest.json -Raw | ConvertFrom-Json
if (-not $manifest.lab_only) { throw 'Expected lab-only artifact manifest' }
if ((Get-FileHash C:\lab\output\winfsp-x64.sys).Hash -ine $manifest.driver_sha256) { throw 'Driver digest mismatch' }
& whoami.exe /all
foreach($store in @('Root','TrustedPublisher')) {
    # Import-Certificate fails on fresh guests whose TrustedPublisher store
    # has not been initialized. certutil creates the machine store itself.
    & certutil.exe -f -addstore $store C:\lab\output\lab.cer
    if($LASTEXITCODE -ne 0){throw "Lab certificate installation failed: $store"}
    if(-not(Test-Path "Cert:\LocalMachine\$store\$($manifest.certificate_thumbprint)")) {throw 'Lab certificate absent after import'}
}
& bcdedit.exe /set testsigning on
if ($LASTEXITCODE -ne 0) { throw 'Test signing unavailable; do not bypass Secure Boot' }
$p=Start-Process msiexec.exe -ArgumentList '/i','C:\lab\winfsp.msi','/qn','/norestart','INSTALLLEVEL=1000' -Wait -PassThru
if ($p.ExitCode -notin @(0,3010)) { throw "MSI exit $($p.ExitCode)" }
# The non-SxS development DLL registers its matching SYS next to itself.
# Retain the stock MSI for launcher/tools; do not overwrite a signed binary.
$p=Start-Process regsvr32.exe -ArgumentList '/s','C:\lab\output\winfsp-x64.dll' -Wait -PassThru
if ($p.ExitCode -ne 0) { throw 'Lab DLL registration failed' }
$driver=Get-CimInstance Win32_SystemDriver -Filter "Name='WinFsp'"
if (-not $driver -or $driver.PathName.Trim('"') -ine 'C:\lab\output\winfsp-x64.sys') {
    throw "Unexpected driver registration: $($driver | ConvertTo-Json -Compress)"
}
(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToFileTimeUtc() | Set-Content C:\lab\pre-reboot.txt
Stop-Transcript
Write-Output "INSTALL_COMPLETE:$Token"
