# Complete upstream MSI payload, built offline inside an isolated Windows VM.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$Revision,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$SourceSha256,
    [Parameter(Mandatory)][string]$InputsDirectory,
    [Parameter(Mandatory)][DateTimeOffset]$HostUtc,
    [Parameter(Mandatory)][string]$Token,
    [ValidatePattern('^[0-9a-f]{64}$')][string]$RetainedPayloadSha256,
    [ValidatePattern('^[0-9a-f]{40}$')][string]$PayloadRevision,
    [ValidatePattern('^[0-9a-f]{64}$')][string]$PayloadSourceSha256
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\inputs.ps1"
. "$PSScriptRoot\build-clock.ps1"
if(-not $PayloadRevision){$PayloadRevision=$Revision}
if(-not $PayloadSourceSha256){$PayloadSourceSha256=$SourceSha256}
if(-not $RetainedPayloadSha256 -and ($PayloadRevision -cne $Revision -or $PayloadSourceSha256 -cne $SourceSha256)){throw 'Fresh compilation must use the selected source'}
Assert-LabBuildClock -HostUtc $HostUtc
Assert-PinnedFile C:\lab\source.zip $SourceSha256
$pins=Get-Content (Join-Path $InputsDirectory 'inputs.json') -Raw | ConvertFrom-Json
foreach($file in $pins.files.PSObject.Properties) {
    Assert-ArchiveName $file.Name
    Assert-PinnedFile (Join-Path $InputsDirectory $file.Name) $file.Value
}
$discs=@(Get-Volume | Where-Object DriveLetter | ForEach-Object {"$($_.DriveLetter):"} |
    Where-Object {Test-Path "$_\BuildEnv\SetupBuildEnv.cmd"})
if($discs.Count -ne 1){throw 'Exactly one read-only EWDK disc required'}
$environment=& cmd.exe /d /c "call $($discs[0])\BuildEnv\SetupBuildEnv.cmd amd64 >nul && set"
if($LASTEXITCODE -ne 0){throw 'EWDK initialization failed'}
foreach($line in $environment) {
    if($line -match '^([^=]+)=(.*)$'){[Environment]::SetEnvironmentVariable($Matches[1],$Matches[2],'Process')}
}
foreach($arch in @('x86','x64','arm64')) {
    if(-not(Test-Path "$($discs[0])\Program Files\Windows Kits\10\Lib\10.0.19041.0\km\$arch\ntoskrnl.lib")) {
        throw "Required 19041 kernel library missing: $arch"
    }
}
$root='C:\lab\package-build'
if(Test-Path $root){throw 'Package build requires a fresh directory'}
New-Item $root -ItemType Directory | Out-Null
$output='C:\lab\output'
New-Item $output -ItemType Directory | Out-Null
Start-Transcript "$output\payload-build.log"
$payload=$null
try {
    $version='2.1.26273'
    $msbuild=(Get-Command MSBuild.exe).Source
    $certificateThumbprint=$null
    if($RetainedPayloadSha256) {
        # Only retry assembly. Never compile, restore, or resign retained bytes.
        Assert-PinnedFile C:\lab\retained-payload.zip $RetainedPayloadSha256
        $payload="$root\installer-payload"
        Expand-CheckedArchive C:\lab\retained-payload.zip $payload -FlatOnly
        # Validate the ORIGINAL manifest; do not regenerate hashes over cached bytes.
        $null=Assert-PackagePayload $payload $PayloadRevision $version $PayloadSourceSha256
    } else {
    Expand-CheckedArchive C:\lab\source.zip "$root\source"
    Expand-CheckedArchive (Join-Path $InputsDirectory 'wix314-binaries.zip') "$root\wix"
    Expand-CheckedArchive (Join-Path $InputsDirectory 'dotnet-sdk-8.0.425-win-x64.zip') "$root\dotnet"
    # Resolve both frameworks explicitly from the pinned offline packages.
    # A global TargetFrameworks override alone restores net35 but does not
    # supply the sample project's distinct net452 targeting pack (MSB3644).
    foreach($framework in @('net35','net452')) {
        Expand-CheckedArchive (Join-Path $InputsDirectory "microsoft.netframework.referenceassemblies.$framework.1.0.3.nupkg") "$root\refs-$framework"
        New-Item "$root\references\.NETFramework" -ItemType Directory -Force | Out-Null
        Copy-Item "$root\refs-$framework\build\.NETFramework\*" "$root\references\.NETFramework" -Recurse -Force
    }
    $env:DOTNET_ROOT="$root\dotnet"
    $env:DOTNET_CLI_TELEMETRY_OPTOUT='1'
    $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1'
    $env:NUGET_PACKAGES="$root\nuget-cache"
    $env:WIX="$root\wix\"
    $msbuild=(Get-Command MSBuild.exe).Source
    $signer=(Get-Command signtool.exe).Source
    $source="$root\source"
    $managedProject="$source\build\VStudio\dotnet\winfsp.net.csproj"
    Select-MsiManagedTarget $managedProject
    @{source_archive_sha256=$SourceSha256;managed_project_sha256=(Get-FileHash $managedProject).Hash.ToLowerInvariant();
      binding_target='net35';sample_target='net452'} | ConvertTo-Json | Set-Content "$output\managed-targets.json"
    $payload="$source\build\VStudio\build\Release"
    New-Item $payload -ItemType Directory -Force | Out-Null
    $common=@('/t:Build','/m:2','/nr:false','/nologo','/v:minimal',
        '/p:Configuration=Release','/p:BuildProjectReferences=false',
        '/p:MyTargetPlatformVersion=10.0.19041.0','/p:WindowsTargetPlatformVersion=10.0.19041.0',
        '/p:MyNtddiVersion=0x06010000','/p:MyWin32Version=0x0601',
        '/p:MyBuildNumber=26273',"/p:MyVersion=$version", "/p:MyGitRevision=$($Revision.Substring(0,7))",
        '/p:SignMode=Off',"/p:SolutionDir=$source\build\VStudio\", "/p:OutDir=$payload\")
    # Fail fast on managed input/restore errors before compiling three native
    # architectures. Keep the upstream net452 sample target unchanged.
    foreach($project in @('dotnet\winfsp.net.csproj','testing\memfs-dotnet.csproj')) {
        $name=Split-Path $project -Leaf
        & "$root\dotnet\dotnet.exe" build "$source\build\VStudio\$project" --configuration Release `
            /p:Platform=AnyCPU /p:GeneratePackageOnBuild=false `
            "/p:TargetFrameworkRootPath=$root\references\" `
            "/p:SolutionDir=$source\build\VStudio\" "/p:RestoreSources=$InputsDirectory" `
            /p:NuGetAudit=false /p:MyBuildNumber=26273 "/p:MyVersion=$version" `
            "/p:MyGitRevision=$($Revision.Substring(0,7))" *> "$output\$name.log"
        if($LASTEXITCODE -ne 0){throw "Managed build failed: $project"}
    }
    foreach($platform in @('Win32','x64','ARM64')) {
        foreach($project in @('winfsp_sys','winfsp_dll','tools\launcher','tools\launchctl','tools\fsptool','testing\memfs','testing\winfsp-tests')) {
            $name=($project -replace '\\','-')+'-'+$platform
            $args=@("$source\build\VStudio\$project.vcxproj")+$common+@("/p:Platform=$platform", "/p:IntDir=$root\obj\$name\", "/bl:$output\$name.binlog")
            if($project -ne 'winfsp_sys'){$args+='/p:PlatformToolset=v142'}
            & $msbuild @args *> "$output\$name.log"
            if($LASTEXITCODE -ne 0){throw "Native build failed: $name"}
        }
    }
    $savedCL=$env:CL
    try {
        $env:CL="$savedCL /I$root\wix\sdk\inc"
        & $msbuild "$source\build\VStudio\installer\CustomActions\CustomActions.vcxproj" @common /p:Platform=Win32 /p:PlatformToolset=v142 "/p:IntDir=$root\obj\customactions\" *> "$output\CustomActions.log"
        if($LASTEXITCODE -ne 0){throw 'CustomActions build failed'}
    } finally {$env:CL=$savedCL}
    $cert=New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=AppMana WinFsp MSI LAB ONLY' -CertStoreLocation Cert:\CurrentUser\My
    $certificateThumbprint=$cert.Thumbprint
    Export-Certificate -Cert $cert -FilePath "$output\lab.cer" | Out-Null
    foreach($arch in @('x86','x64','a64')) {
        & $signer sign /fd SHA256 /s My /sha1 $cert.Thumbprint "$payload\winfsp-$arch.sys"
        if($LASTEXITCODE -ne 0){throw "Lab driver signing failed: $arch"}
    }
    Export-PackagePayload $payload "$root\installer-payload" $Revision $version $SourceSha256
    }
    Compress-Archive -Path "$root\installer-payload\*" -DestinationPath "$output\payload.zip"
    & "$PSScriptRoot\build-msi.ps1" -SourceZip C:\lab\source.zip -SourceSha256 $SourceSha256 -Revision $Revision `
        -PayloadZip "$output\payload.zip" -PayloadSha256 (Get-FileHash "$output\payload.zip").Hash.ToLowerInvariant() `
        -WixZip (Join-Path $InputsDirectory 'wix314-binaries.zip') -WixSha256 $pins.files.'wix314-binaries.zip' `
        -MSBuildPath $msbuild -MSBuildSha256 (Get-FileHash $msbuild).Hash.ToLowerInvariant() `
        -Version $version -OutputDirectory "$root\assembled" -LabOnly -PayloadRevision $PayloadRevision -PayloadSourceSha256 $PayloadSourceSha256
    Copy-Item "$root\assembled\*.msi","$root\assembled\package-manifest.json","$root\assembled\package.log" $output
    @{lab_only=$true;production_qualified=$false;certificate_thumbprint=$certificateThumbprint;
      retained_payload_sha256=$RetainedPayloadSha256;
      source_revision=$Revision;ewdk_build=$env:BuildLab;inputs=$pins} |
      ConvertTo-Json -Depth 5 | Set-Content "$output\build-provenance.json"
} finally {
    # Keep completed files even when a later component fails. These are
    # explicitly partial, not an installer-qualified payload. A complete
    # payload.zip is already retained before MSI assembly begins.
    if($payload -and (Test-Path $payload) -and -not(Test-Path "$output\payload.zip")) {
        try {
            Compress-Archive -Path "$payload\*" -DestinationPath "$output\partial-payload.zip"
            @{complete=$false;source_revision=$PayloadRevision;source_archive_sha256=$PayloadSourceSha256;
              archive_sha256=(Get-FileHash "$output\partial-payload.zip").Hash.ToLowerInvariant()} |
                ConvertTo-Json | Set-Content "$output\partial-payload.json"
        } catch {Write-Warning "Partial payload retention failed: $_"}
    }
    Stop-Transcript
}
Write-Output "PACKAGE_BUILD_COMPLETE:$Token"
