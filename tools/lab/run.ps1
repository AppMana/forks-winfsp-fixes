[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9-]+$')][string]$Token,
      [ValidateSet('regression','full','directory','directory-sensitive','mountmgr')][string]$Suite='full')
$ErrorActionPreference='Stop'
. C:\lab\evidence.ps1
Start-Transcript "C:\lab\suite-$Suite.txt"
if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control').PSObject.Properties['ContainerType']) {
    throw 'Native VM required: upstream silently disables network tests in Windows containers'
}
$before=[long](Get-Content C:\lab\pre-reboot.txt)
if ((Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToFileTimeUtc() -le $before) { throw 'Guest did not reboot' }
$manifest=Get-Content C:\lab\output\manifest.json -Raw | ConvertFrom-Json
foreach($pair in @(@('winfsp-x64.sys','driver_sha256'),@('winfsp-x64.dll','dll_sha256'),@('winfsp-tests-x64.exe','test_sha256'))) {
    if ((Get-FileHash "C:\lab\output\$($pair[0])").Hash -ine $manifest.($pair[1])) { throw 'Artifact changed after build' }
}
& sc.exe start WinFsp
if ($LASTEXITCODE -notin @(0,1056)) { throw 'Candidate driver could not start' }
$drivers=@(Get-CimInstance Win32_SystemDriver | Where-Object { $_.Name -like 'WinFsp*' -and $_.State -eq 'Running' })
if ($drivers.Count -ne 1 -or $drivers[0].Name -ne 'WinFsp' -or
    $drivers[0].PathName.Trim('"') -notin @('C:\lab\output\winfsp-x64.sys','\??\C:\lab\output\winfsp-x64.sys')) { throw 'Wrong or additional WinFsp driver running' }
$drivers | ConvertTo-Json | Set-Content C:\lab\loaded-driver.json
Set-Location C:\lab\output
$arguments=switch($Suite) {
    regression { @('reparse_mount_target_test') }
    full { @('+*') }
    directory { @('--mountpoint=C:\lab\native-mount','--case-insensitive','*','+ea*') }
    'directory-sensitive' { @('--mountpoint=C:\lab\native-mount','*','+ea*') }
    mountmgr { @('--mountpoint=\\.\C:\lab\native-mount','--resilient','*','+ea*','-exec*') }
}
& .\winfsp-tests-x64.exe --list @arguments > "C:\lab\inventory-$Suite.txt"
if ($LASTEXITCODE -ne 0) { throw 'Native inventory failed' }
$env:WINFSP_TESTS_EXPECT_DLL='C:\lab\output\winfsp-x64.dll'
$p=Start-Process .\winfsp-tests-x64.exe -ArgumentList $arguments -PassThru -NoNewWindow -RedirectStandardOutput "C:\lab\native-$Suite.log" -RedirectStandardError "C:\lab\native-$Suite.stderr.txt"
if(-not $p.WaitForExit(1100000)){throw 'Native suite timed out'}
if(@(Get-Content "C:\lab\native-$Suite.stderr.txt" | Where-Object {$_ -ceq 'WINFSP_TEST_DLL:C:\lab\output\winfsp-x64.dll'}).Count -ne 1) {throw 'Candidate DLL attestation missing'}
$p.Refresh()
$exitCode=$p.ExitCode
if($null -eq $exitCode){throw 'Native process exit missing'}
Assert-NativeSuiteEvidence -Inventory @(Get-Content "C:\lab\inventory-$Suite.txt") -Output (Get-Content "C:\lab\native-$Suite.log" -Raw) -ExitCode $exitCode
Stop-Transcript
if ($exitCode -ne 0) { throw "Native suite $Suite failed ($exitCode); see retained log" }
Write-Output "SUITE_COMPLETE_${Suite}:$Token"
