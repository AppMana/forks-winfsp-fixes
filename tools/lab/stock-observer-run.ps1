[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9-]+$')][string]$Token)
$ErrorActionPreference='Stop'
. C:\lab\process.ps1
Start-Transcript C:\lab\stock-observer-run-transcript.txt
if((Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToFileTimeUtc() -le
    [long](Get-Content C:\lab\pre-reboot.txt)){throw 'Stock MSI reboot not observed'}
$bootConfig=(& bcdedit.exe /enum '{current}' | Out-String)
if($LASTEXITCODE -ne 0 -or $bootConfig -match '(?im)^testsigning\s+Yes\s*$'){
    throw 'Stock lane requires test signing disabled'
}
$drivers=@(Get-CimInstance Win32_SystemDriver | Where-Object {
    $_.Name -like 'WinFsp*' -and $_.PathName -match '(?i)winfsp[^\\]*\.sys"?$'
})
if($drivers.Count -ne 1){throw "Expected one stock WinFsp kernel service, found $($drivers.Count)"}
$driver=$drivers[0]
$driverPath=$driver.PathName.Trim('"')
if($driverPath.StartsWith('\??\')){$driverPath=$driverPath.Substring(4)}
$driverPath=[Environment]::ExpandEnvironmentVariables($driverPath)
if(-not(Test-Path -LiteralPath $driverPath)){throw "Loaded driver path missing: $driverPath"}
$signature=Get-AuthenticodeSignature -LiteralPath $driverPath
if($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate){
    throw "Stock driver signature invalid: $($signature.Status)"
}
@{name=$driver.Name;state_before_test=$driver.State;path=$driverPath;
  sha256=(Get-FileHash -LiteralPath $driverPath).Hash.ToLowerInvariant();
  signature_status=$signature.Status.ToString();
  signer_subject=$signature.SignerCertificate.Subject;
  signer_thumbprint=$signature.SignerCertificate.Thumbprint;
  testsigning=$false} | ConvertTo-Json | Set-Content C:\lab\stock-driver.json

New-Item C:\lab\observer -ItemType Directory | Out-Null
Expand-Archive C:\lab\observer-results.zip C:\lab\observer
$output='C:\lab\observer\output'
$exe="$output\winfsp-tests-x64.exe"
$dll="$output\winfsp-x64.dll"
if((Get-FileHash $exe).Hash -ine
    '5c6d29955c4f86bcd0aacf7e31a0957f2b8054828ff02911875517111f9baf0e'){
    throw 'Observer executable digest mismatch'
}
if((Get-FileHash $dll).Hash -ine
    '91731c744f7c6530073546560b204bb3ed67f5ffcaa70340885365906b75bf01'){
    throw 'Observer DLL digest mismatch'
}
$env:WINFSP_TESTS_EXPECT_DLL=$dll
$inventoryOut='C:\lab\stock-observer-inventory.txt'
$inventoryErr='C:\lab\stock-observer-inventory.stderr.txt'
$inventoryExit=Invoke-NativeLabProcess $exe @('--list','reparse_net_projected_target_test') $inventoryOut $inventoryErr 30000
$inventory=@(Get-Content $inventoryOut | Where-Object {$_.Trim()})
if($inventoryExit -ne 0 -or $inventory.Count -ne 1 -or
    $inventory[0] -cne 'reparse_net_projected_target_test'){
    throw 'Observer inventory was missing or ambiguous'
}
$testOut='C:\lab\stock-observer-red.log'
$testErr='C:\lab\stock-observer-red.stderr.txt'
$testExit=Invoke-NativeLabProcess $exe @('reparse_net_projected_target_test') $testOut $testErr 120000
$evidence=(Get-Content $testErr -Raw)
if($testExit -eq 0){throw 'Observer unexpectedly passed on stock driver'}
if($evidence -cnotmatch
    'REPARSE_TARGET target=.* expected=[1-9][0-9]* observed=0 file_name=\\probe'){
    throw "Stock failure did not reproduce the target-classification RED (exit $testExit)"
}
if((Get-CimInstance Win32_SystemDriver -Filter "Name='$($driver.Name)'").State -ne 'Running'){
    throw 'Attested stock driver did not run during observer test'
}
@{inventory_exit=$inventoryExit;test_exit=$testExit;
  executable_sha256=(Get-FileHash $exe).Hash.ToLowerInvariant();
  dll_sha256=(Get-FileHash $dll).Hash.ToLowerInvariant()} |
    ConvertTo-Json | Set-Content C:\lab\stock-observer-result.json
Stop-Transcript
Write-Output "STOCK_OBSERVER_RED_CONFIRMED:$Token"
