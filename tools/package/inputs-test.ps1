$ErrorActionPreference='Stop'
. "$PSScriptRoot\inputs.ps1"
function Reject([scriptblock]$Action) {
    $failed=$false
    try { & $Action } catch { $failed=$true }
    if(-not $failed){throw 'Invalid package input accepted'}
}
$root=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item $root -ItemType Directory | Out-Null
try {
    $file=Join-Path $root 'input.zip'
    [IO.File]::WriteAllText($file,'pinned bytes')
    $sha=(Get-FileHash $file).Hash.ToLowerInvariant()
    Assert-PinnedFile $file $sha
    Reject {Assert-PinnedFile $file ('a'*64)}
    Reject {Assert-PinnedFile $file 'latest'}
    foreach($path in @('../escape','a/../../escape','/absolute','C:/absolute','a:stream','a\\file','a//file','a/./file','file.','file ','CON','nul.txt')) {
        Reject {Assert-ArchiveName $path}
    }
    foreach($path in @('src/sys/fsctl.c','build/VStudio/','winfsp-x64.sys')) {Assert-ArchiveName $path}
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=Join-Path $root 'duplicate.zip'
    $z=[IO.Compression.ZipFile]::Open($zip,'Create')
    try { $null=$z.CreateEntry('file'); $null=$z.CreateEntry('FILE') } finally {$z.Dispose()}
    Reject {Expand-CheckedArchive $zip (Join-Path $root 'out')}
    if(Test-Path (Join-Path $root 'out')) {throw 'Unsafe archive partially extracted'}
    $pe=Join-Path $root 'fake.exe'
    $bytes=New-Object byte[] 256
    $bytes[0]=0x4d; $bytes[1]=0x5a; $bytes[60]=128
    $bytes[128]=0x50; $bytes[129]=0x45; $bytes[132]=0x64; $bytes[133]=0x86
    [IO.File]::WriteAllBytes($pe,$bytes)
    Assert-PeMachine $pe 0x8664
    Reject {Assert-PeMachine $pe 0xaa64}
    $bytes[128]=0; [IO.File]::WriteAllBytes($pe,$bytes)
    Reject {Assert-PeMachine $pe 0x8664}
    $payload=Join-Path $root 'payload'
    New-Item $payload -ItemType Directory | Out-Null
    $files=@{}
    foreach($arch in @('x86','x64','a64')) {
        foreach($name in @("winfsp-$arch.sys","winfsp-$arch.dll","winfsp-$arch.lib","launcher-$arch.exe",
            "launchctl-$arch.exe","fsptool-$arch.exe","memfs-$arch.exe","fuse-$arch.pc","fuse3-$arch.pc")) {
            $bytes[128]=0x50
            $machine=@{x86=0x14c;x64=0x8664;a64=0xaa64}[$arch]
            $bytes[132]=$machine -band 255; $bytes[133]=$machine -shr 8
            $path=Join-Path $payload $name
            [IO.File]::WriteAllBytes($path,$bytes)
            $files[$name]=(Get-FileHash $path).Hash.ToLowerInvariant()
        }
    }
    foreach($name in @('CustomActions.dll','winfsp-msil.dll','winfsp-msil.xml','memfs-dotnet-msil.exe')) {
        $bytes[132]=0x4c; $bytes[133]=1
        $path=Join-Path $payload $name
        [IO.File]::WriteAllBytes($path,$bytes)
        $files[$name]=(Get-FileHash $path).Hash.ToLowerInvariant()
    }
    $manifest=@{schema=1;source_revision='a'*40;version='2.2.26271';files=$files}
    $manifest | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $payload 'payload.json')
    $null=Assert-PackagePayload $payload ('a'*40) '2.2.26271'
    Reject {Assert-PackagePayload $payload ('b'*40) '2.2.26271'}
    Reject {Assert-PackagePayload $payload ('a'*40) '2.2.26272'}
    [IO.File]::WriteAllText((Join-Path $payload 'extra.dll'),'untracked')
    Reject {Assert-PackagePayload $payload ('a'*40) '2.2.26271'}
    Remove-Item (Join-Path $payload 'extra.dll')
    [IO.File]::WriteAllText((Join-Path $payload 'winfsp-x64.sys'),'tampered')
    Reject {Assert-PackagePayload $payload ('a'*40) '2.2.26271'}
    $files.Remove('winfsp-x64.sys')
    $manifest | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $payload 'payload.json')
    Reject {Assert-PackagePayload $payload ('a'*40) '2.2.26271'}
    $tokens=$null; $errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'build-msi.ps1'),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ($errors | Out-String)}
    'PACKAGE_INPUT_CONTRACTS_PASS'
} finally {Remove-Item -LiteralPath $root -Recurse -Force}
