# Offline assembly of the COMPLETE upstream installer. This entry point only
# produces lab artifacts; it cannot publish or create a production release.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceZip,
    [Parameter(Mandatory)][string]$SourceSha256,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$Revision,
    [Parameter(Mandatory)][string]$PayloadZip,
    [Parameter(Mandatory)][string]$PayloadSha256,
    [Parameter(Mandatory)][string]$WixZip,
    [Parameter(Mandatory)][string]$WixSha256,
    [Parameter(Mandatory)][string]$MSBuildPath,
    [Parameter(Mandatory)][string]$MSBuildSha256,
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [switch]$LabOnly
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\inputs.ps1"
if(-not $LabOnly){throw 'Production signing and qualification are not implemented; LabOnly is required'}
if([Environment]::OSVersion.Platform -ne 'Win32NT'){throw 'WiX MSI assembly requires Windows'}
Assert-PinnedFile $MSBuildPath $MSBuildSha256
foreach($item in @(@($SourceZip,$SourceSha256),@($PayloadZip,$PayloadSha256),@($WixZip,$WixSha256))) {
    Assert-PinnedFile $item[0] $item[1]
}
$parts=$Version.Split('.')
if([int]$parts[0] -gt 255 -or [int]$parts[1] -gt 255 -or [int]$parts[2] -gt 65535){throw 'Version exceeds MSI limits'}
if(Test-Path -LiteralPath $OutputDirectory){throw 'Output directory must be fresh; existing artifacts are never overwritten'}
$out=[IO.Path]::GetFullPath($OutputDirectory)
New-Item $out -ItemType Directory | Out-Null
Start-Transcript (Join-Path $out 'package.log')
try {
    $source=Join-Path $out 'source'
    $wix=Join-Path $out 'wix'
    Expand-CheckedArchive $SourceZip $source
    Expand-CheckedArchive $WixZip $wix
    $payload=Join-Path $source 'build/VStudio/build/Release'
    Expand-CheckedArchive $PayloadZip $payload
    $manifest=Assert-PackagePayload $payload $Revision $Version $SourceSha256
    foreach($arch in @('x86','x64','a64')) {
        Assert-CoffLibraryMachine (Join-Path $source "opt/fsext/lib/winfsp-$arch.lib") (@{x86=0x14c;x64=0x8664;a64=0xaa64}[$arch])
    }
    $installer=Join-Path $source 'build/VStudio/installer'
    # Preserve upstream feature/component/upgrade/service registration design.
    # Only the disposable staging copy receives lab guards and fault injection.
    $product=Join-Path $installer 'Product.wxs'
    Add-LabInstallerGuards $product
    $msbuild=(Resolve-Path -LiteralPath $MSBuildPath).Path
    $buildArguments=@((Join-Path $installer 'winfsp_msi.wixproj'),'/t:Build','/m:1','/nr:false',
        '/p:Configuration=Release','/p:Platform=x86',"/p:SolutionDir=$source\build\VStudio\",
        "/p:WixTargetsPath=$wix\wix.targets","/p:WixToolPath=$wix\","/p:WixExtDir=$wix",
        "/p:MyVersion=$Version","/p:MyFullVersion=$Version.$($Revision.Substring(0,7))",
        "/p:MyGitRevision=$($Revision.Substring(0,7))",'/p:MyProductVersion=AppMana LAB ONLY',
        '/p:MyCompanyName=AppMana (lab packaging)','/p:MyProductStage=Beta',"/bl:$out\package.binlog")
    $buildArguments | ConvertTo-Json | Set-Content (Join-Path $out 'arguments.json')
    Push-Location $installer
    try { & $msbuild @buildArguments; if($LASTEXITCODE -ne 0){throw "MSI build failed: $LASTEXITCODE"} } finally {Pop-Location}
    $msi=Join-Path $payload "winfsp-$Version.msi"
    if(-not(Test-Path $msi)){throw 'MSI output missing'}
    $target=Join-Path $out "winfsp-$Version-LAB-ONLY.msi"
    Copy-Item -LiteralPath $msi -Destination $target
    @{schema=1;lab_only=$true;production_qualified=$false;source_revision=$Revision;version=$Version;
        source_sha256=$SourceSha256;payload_sha256=$PayloadSha256;wix_sha256=$WixSha256;
        package_sha256=(Get-FileHash $target).Hash.ToLowerInvariant();
        staged_installer_sha256=(Get-FileHash $product).Hash.ToLowerInvariant();
        script_sha256=(Get-FileHash $PSCommandPath).Hash.ToLowerInvariant();
        msbuild_sha256=(Get-FileHash $msbuild).Hash.ToLowerInvariant();payload=$manifest} |
        ConvertTo-Json -Depth 8 | Set-Content (Join-Path $out 'package-manifest.json')
} finally {Stop-Transcript}
