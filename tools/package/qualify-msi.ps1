# Only invoked by the isolated generic-VM Labcontainers package harness.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('install','run')][string]$Phase,
    [Parameter(Mandatory)][string]$Token,
    [Parameter(Mandatory)][string]$InputsDirectory
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\inputs.ps1"
. "$PSScriptRoot\evidence.ps1"
. "$PSScriptRoot\process.ps1"
if([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18'){throw 'Native VM SYSTEM token required'}
if((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control').PSObject.Properties['ContainerType']){throw 'Windows container is not a qualification VM'}
$out='C:\lab\output'
$manifest=Get-Content "$out\package-manifest.json" -Raw | ConvertFrom-Json
if(-not $manifest.lab_only -or $manifest.production_qualified){throw 'Expected lab-only package'}
$msi="$out\winfsp-$($manifest.version)-LAB-ONLY.msi"
Assert-PinnedFile $msi $manifest.package_sha256
$bin="${env:ProgramFiles(x86)}\WinFsp\bin"
function Invoke-Msi([string]$Path,[string]$Name,[string[]]$Options,[int[]]$Expected=@(0,3010)) {
    $p=Start-Process msiexec.exe -ArgumentList (@('/i',('"'+$Path+'"'),'/qn','/norestart','/l*v',"$out\msi-$Name.log")+$Options) -Wait -PassThru
    if($p.ExitCode -notin $Expected){throw "MSI $Name exited $($p.ExitCode), expected $Expected"}
    return $p.ExitCode
}
function Assert-InstalledPayload {
    foreach($name in @('winfsp-x64.sys','winfsp-x64.dll','winfsp-x86.dll','launcher-x64.exe','launchctl-x64.exe','fsptool-x64.exe')) {
        Assert-PinnedFile (Join-Path $bin $name) $manifest.payload.files.$name
    }
}
Start-Transcript "$out\qualification-$Phase.log"
try {
    if($Phase -eq 'install') {
        # Exercise the opt-in guard rather than merely parsing its WiX XML.
        $null=Invoke-Msi $msi 'guard' @() @(1603)
        if((Get-Content "$out\msi-guard.log" -Raw) -notmatch 'APPMANA_LAB_ONLY=1'){throw 'Installation failed for an unrelated reason, not the lab guard'}
        $stock=Join-Path $InputsDirectory 'stock.msi'
        Assert-PinnedFile $stock '073a70e00f77423e34bed98b86e600def93393ba5822204fac57a29324db9f7a'
        $null=Invoke-Msi $stock 'stock' @('INSTALLLEVEL=1000')
        $before=@{}
        foreach($name in @('winfsp-x64.sys','winfsp-x64.dll','winfsp-x86.dll')){$before[$name]=(Get-FileHash (Join-Path $bin $name)).Hash.ToLowerInvariant()}
        $certPath=if(Test-Path "$out\lab.cer"){"$out\lab.cer"}else{Join-Path $InputsDirectory 'lab.cer'}
        $cert=[Security.Cryptography.X509Certificates.X509Certificate2]::new($certPath)
        $payload='C:\lab\package-build\installer-payload'
        $signature=Get-AuthenticodeSignature "$payload\winfsp-x64.sys"
        if(-not $signature.SignerCertificate -or $signature.SignerCertificate.Thumbprint -cne $cert.Thumbprint){throw 'Retained certificate does not sign the candidate driver'}
        foreach($store in @('Root','TrustedPublisher')) {
            & certutil.exe -f -addstore $store $certPath
            if($LASTEXITCODE -ne 0){throw 'Lab certificate import failed'}
        }
        & bcdedit.exe /set testsigning on
        if($LASTEXITCODE -ne 0){throw 'Lab test signing unavailable; never bypass Secure Boot'}
        $null=Invoke-Msi $msi 'rollback' @('APPMANA_LAB_ONLY=1','INSTALLLEVEL=1000','WIXFAILWHENDEFERRED=1') @(1603)
        Assert-DeferredRollbackEvidence (Get-Content "$out\msi-rollback.log" -Raw)
        foreach($name in $before.Keys){Assert-PinnedFile (Join-Path $bin $name) $before[$name]}
        $null=Invoke-Msi $msi 'upgrade' @('APPMANA_LAB_ONLY=1','INSTALLLEVEL=1000')
        Assert-InstalledPayload
        @{stock_files=$before;candidate_sha256=$manifest.package_sha256;certificate=$cert.Thumbprint;rollback_preserved=$true} |
            ConvertTo-Json -Depth 4 | Set-Content "$out\installation-evidence.json"
        (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToFileTimeUtc() | Set-Content C:\lab\pre-reboot.txt
    } else {
        if((Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToFileTimeUtc() -le [long](Get-Content C:\lab\pre-reboot.txt)){throw 'Reboot not observed'}
        Assert-InstalledPayload
        & sc.exe start WinFsp
        if($LASTEXITCODE -notin @(0,1056)){throw 'Installed driver could not start'}
        $drivers=@(Get-CimInstance Win32_SystemDriver | Where-Object {$_.Name -like 'WinFsp*' -and $_.State -eq 'Running'})
        if($drivers.Count -ne 1 -or $drivers[0].Name -ne 'WinFsp' -or $drivers[0].PathName.Trim('"') -notin @("$bin\winfsp-x64.sys","\??\$bin\winfsp-x64.sys")){throw 'Wrong installed driver running'}
        $drivers | Select-Object Name,State,PathName | ConvertTo-Json | Set-Content "$out\installed-driver.json"
        foreach($arch in @('x64','x86')) {
            # Do not copy a candidate DLL beside the test: load the MSI-installed DLL.
            $runner="C:\lab\msi-test-$arch"
            New-Item $runner -ItemType Directory | Out-Null
            $exe=Join-Path $runner "winfsp-tests-$arch.exe"
            Copy-Item "C:\lab\package-build\installer-payload\winfsp-tests-$arch.exe" $exe
            Assert-PinnedFile $exe $manifest.payload.files."winfsp-tests-$arch.exe"
            $env:PATH="$bin;"+$env:PATH
            $env:WINFSP_TESTS_EXPECT_DLL="$bin\winfsp-$arch.dll"
            $inventory=Invoke-NativeLabProcess $exe @('--list','+*') "$out\inventory-$arch.txt" "$out\inventory-$arch.stderr.txt"
            if($inventory -ne 0){throw 'Installed native inventory failed'}
            $exit=Invoke-NativeLabProcess $exe @('+*') "$out\native-$arch.log" "$out\native-$arch.stderr.txt"
            if(@(Get-Content "$out\native-$arch.stderr.txt" | Where-Object {$_ -ceq "WINFSP_TEST_DLL:$bin\winfsp-$arch.dll"}).Count -ne 1){throw 'Installed DLL attestation missing'}
            if((Get-Content "$out\native-$arch.stderr.txt" -Raw) -match ': need (Administrator|SE_CREATE_SYMBOLIC_LINK_PRIVILEGE)'){throw 'Native suite skipped privilege checks'}
            Assert-NativeSuiteEvidence @(Get-Content "$out\inventory-$arch.txt") (Get-Content "$out\native-$arch.log" -Raw) $exit
        }
    }
} finally {Stop-Transcript}
Write-Output "PACKAGE_QUALIFICATION_${Phase}:$Token"
