# Disposable-guest build only. Outputs are test-signed, never release packages.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$Revision,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9-]+$')][string]$Token
)
$ErrorActionPreference = 'Stop'
Start-Transcript C:\lab\build-transcript.txt
$discs = @(Get-Volume | Where-Object DriveLetter | ForEach-Object { "$($_.DriveLetter):" } |
    Where-Object { Test-Path "$_\BuildEnv\SetupBuildEnv.cmd" })
if ($discs.Count -ne 1) { throw 'Exactly one read-only EWDK disc required' }
$ewdk = $discs[0]
$environment = & cmd.exe /d /c "call $ewdk\BuildEnv\SetupBuildEnv.cmd amd64 >nul && set"
if ($LASTEXITCODE -ne 0) { throw 'EWDK initialization failed' }
foreach ($line in $environment) {
    if ($line -match '^([^=]+)=(.*)$') {
        [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
    }
}
if ($env:BuildLab -ne 'ge_release_svc_prod1.26100.6584') { throw 'Unexpected EWDK version' }
New-Item C:\lab\source -ItemType Directory | Out-Null
Expand-Archive C:\lab\source.zip C:\lab\source
$output = 'C:\lab\output'
New-Item $output -ItemType Directory | Out-Null
$msbuild = (Get-Command MSBuild.exe).Source
$compiler = (Get-Command cl.exe).Source
$signer = (Get-Command signtool.exe).Source
@($msbuild, $compiler, $signer) | ForEach-Object {
    [pscustomobject]@{path=$_;sha256=(Get-FileHash $_).Hash;version=(Get-Item $_).VersionInfo.FileVersion}
} | ConvertTo-Json | Set-Content "$output\toolchain.json"
$common = @('/t:Build', '/m:1', '/nr:false', '/nologo', '/v:normal',
    '/p:Configuration=Release', '/p:Platform=x64', '/p:BuildProjectReferences=false',
    '/p:MyTargetPlatformVersion=10.0.26100.0', '/p:WindowsTargetPlatformVersion=10.0.26100.0',
    '/p:MyNtddiVersion=0x0A000006', '/p:MyWin32Version=0x0A00',
    '/p:MyBuildNumber=26270', "/p:MyGitRevision=$($Revision.Substring(0,7))",
    '/p:MyCopyright=2015-2025 Bill Zissimopoulos', '/p:SignMode=Off',
    '/p:SolutionDir=C:\lab\source\build\VStudio\', "/p:OutDir=$output\")
foreach ($project in @('winfsp_sys', 'winfsp_dll', 'testing\winfsp-tests')) {
    $name = Split-Path $project -Leaf
    $arguments = @("C:\lab\source\build\VStudio\$project.vcxproj") + $common +
        @("/p:IntDir=C:\lab\obj\$name\", "/bl:$output\$name.binlog")
    if ($project -ne 'winfsp_sys') { $arguments += '/p:PlatformToolset=v143' }
    $arguments | ConvertTo-Json | Set-Content "$output\$name.arguments.json"
    & $msbuild @arguments *> "$output\$name.log"
    if ($LASTEXITCODE -ne 0) { throw "Build failed: $project (see retained log)" }
}
$unsigned = (Get-FileHash "$output\winfsp-x64.sys").Hash.ToLowerInvariant()
$cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=AppMana WinFsp LAB ONLY' -CertStoreLocation Cert:\CurrentUser\My
Export-Certificate -Cert $cert -FilePath "$output\lab.cer" | Out-Null
& $signer sign /fd SHA256 /s My /sha1 $cert.Thumbprint "$output\winfsp-x64.sys"
if ($LASTEXITCODE -ne 0) { throw 'Lab signing failed' }
@{source_revision=$Revision;source_archive_sha256=(Get-FileHash C:\lab\source.zip).Hash.ToLowerInvariant();
    build_script_sha256=(Get-FileHash $PSCommandPath).Hash.ToLowerInvariant();
    ewdk_build=$env:BuildLab;unsigned_driver_sha256=$unsigned;lab_only=$true;
    driver_sha256=(Get-FileHash "$output\winfsp-x64.sys").Hash.ToLowerInvariant();
    dll_sha256=(Get-FileHash "$output\winfsp-x64.dll").Hash.ToLowerInvariant();
    test_sha256=(Get-FileHash "$output\winfsp-tests-x64.exe").Hash.ToLowerInvariant();
    certificate_thumbprint=$cert.Thumbprint} | ConvertTo-Json | Set-Content "$output\manifest.json"
Stop-Transcript
Write-Output "BUILD_COMPLETE:$Token"
