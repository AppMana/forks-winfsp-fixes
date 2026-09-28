# Disposable-guest native test build. Reuses an attested compatible DLL/import
# library cache and never builds, signs, installs or starts a driver.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$Revision,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9-]+$')][string]$Token
)
$ErrorActionPreference='Stop'
Start-Transcript C:\lab\build-test-only-transcript.txt
$cacheRevision='b5c3c595c306a4b8d319e507bb80a6c0ac3007ad'
$cacheDllHash='91731c744f7c6530073546560b204bb3ed67f5ffcaa70340885365906b75bf01'
$cacheLibHash='44b4d269effc2f83d944b6c1d426fd76f16e70929dc7d950de3fddd11697a3e1'
$discs=@(Get-Volume | Where-Object DriveLetter | ForEach-Object {"$($_.DriveLetter):"} |
    Where-Object {Test-Path "$_\BuildEnv\SetupBuildEnv.cmd"})
if($discs.Count -ne 1){throw 'Exactly one read-only EWDK disc required'}
$ewdk=$discs[0]
$environment=& cmd.exe /d /c "call $ewdk\BuildEnv\SetupBuildEnv.cmd amd64 >nul && set"
if($LASTEXITCODE -ne 0){throw 'EWDK initialization failed'}
foreach($line in $environment){if($line -match '^([^=]+)=(.*)$'){
    [Environment]::SetEnvironmentVariable($Matches[1],$Matches[2],'Process')
}}
if($env:BuildLab -ne 'ge_release_svc_prod1.26100.6584'){throw 'Unexpected EWDK version'}
New-Item C:\lab\source,C:\lab\cache,C:\lab\output -ItemType Directory | Out-Null
Expand-Archive C:\lab\source.zip C:\lab\source
Expand-Archive C:\lab\cached-output.zip C:\lab\cache
$cachedManifest=Get-Content C:\lab\cache\output\manifest.json -Raw | ConvertFrom-Json
if($cachedManifest.source_revision -cne $cacheRevision){throw 'Cached source revision mismatch'}
foreach($pair in @(@('winfsp-x64.dll',$cacheDllHash),@('winfsp-x64.lib',$cacheLibHash))){
    $path="C:\lab\cache\output\$($pair[0])"
    if((Get-FileHash $path).Hash -ine $pair[1]){throw "Cached artifact mismatch: $($pair[0])"}
    Copy-Item -LiteralPath $path -Destination C:\lab\output
}
$msbuild=(Get-Command MSBuild.exe).Source
$compiler=(Get-Command cl.exe).Source
@($msbuild,$compiler) | ForEach-Object {
    [pscustomobject]@{path=$_;sha256=(Get-FileHash $_).Hash;version=(Get-Item $_).VersionInfo.FileVersion}
} | ConvertTo-Json | Set-Content C:\lab\output\toolchain.json
$arguments=@(
    'C:\lab\source\build\VStudio\testing\winfsp-tests.vcxproj',
    '/t:Build','/m:1','/nr:false','/nologo','/v:normal',
    '/p:Configuration=Release','/p:Platform=x64','/p:BuildProjectReferences=false',
    '/p:PlatformToolset=v143','/p:MyTargetPlatformVersion=10.0.26100.0',
    '/p:WindowsTargetPlatformVersion=10.0.26100.0','/p:MyNtddiVersion=0x0A000006',
    '/p:MyWin32Version=0x0A00','/p:MyBuildNumber=26270',
    "/p:MyGitRevision=$($Revision.Substring(0,7))",
    '/p:MyCopyright=2015-2025 Bill Zissimopoulos','/p:SignMode=Off',
    '/p:SolutionDir=C:\lab\source\build\VStudio\',
    '/p:OutDir=C:\lab\output\','/p:IntDir=C:\lab\obj\winfsp-tests\',
    '/bl:C:\lab\output\winfsp-tests.binlog')
$arguments | ConvertTo-Json | Set-Content C:\lab\output\winfsp-tests.arguments.json
& $msbuild @arguments *> C:\lab\output\winfsp-tests.log
if($LASTEXITCODE -ne 0){throw 'Native test build failed'}
$test='C:\lab\output\winfsp-tests-x64.exe'
if(-not(Test-Path $test)){throw 'Native test executable missing'}
@{source_revision=$Revision;cache_source_revision=$cacheRevision;
    source_archive_sha256=(Get-FileHash C:\lab\source.zip).Hash.ToLowerInvariant();
    cache_archive_sha256=(Get-FileHash C:\lab\cached-output.zip).Hash.ToLowerInvariant();
    cache_dll_sha256=$cacheDllHash;cache_import_lib_sha256=$cacheLibHash;
    build_script_sha256=(Get-FileHash $PSCommandPath).Hash.ToLowerInvariant();
    ewdk_build=$env:BuildLab;test_sha256=(Get-FileHash $test).Hash.ToLowerInvariant();
    build_only=$true;driver_built=$false;driver_installed=$false} |
    ConvertTo-Json | Set-Content C:\lab\output\build-test-only-manifest.json
Stop-Transcript
Write-Output "BUILD_TEST_ONLY_COMPLETE:$Token"
