Set-StrictMode -Version Latest
function Assert-PinnedFile([string]$Path,[string]$Sha256) {
    if($Sha256 -cnotmatch '^[0-9a-f]{64}$' -or -not(Test-Path -LiteralPath $Path -PathType Leaf) -or
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ine $Sha256) {throw "Input digest mismatch: $Path"}
}
function Assert-ArchiveName([string]$Name) {
    if(-not $Name -or $Name.StartsWith('/') -or $Name.Contains('\') -or $Name.Contains(':')) {throw "Unsafe archive path: $Name"}
    foreach($part in $Name.TrimEnd('/').Split('/')) {
        if(-not $part -or $part -in @('.','..') -or $part -match '[. ]$|[\x00-\x1f<>"|?*]' -or
            $part -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') {throw "Unsafe archive component: $Name"}
    }
}
function Expand-CheckedArchive([string]$Zip,[string]$Destination) {
    if(Test-Path -LiteralPath $Destination) {throw 'Extraction destination must not exist'}
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive=[IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($entry in $archive.Entries) {
            Assert-ArchiveName $entry.FullName
            if(-not $seen.Add($entry.FullName.TrimEnd('/'))) {throw 'Duplicate archive path'}
            # ZIP UNIX symlinks must not redirect subsequent extraction.
            if((($entry.ExternalAttributes -shr 16) -band 0xf000) -eq 0xa000) {throw 'Archive symlink is forbidden'}
        }
    } finally {$archive.Dispose()}
    [IO.Compression.ZipFile]::ExtractToDirectory($Zip,$Destination)
}
function Assert-PeMachine([string]$Path,[int]$Machine) {
    $stream=[IO.File]::OpenRead($Path)
    $reader=[IO.BinaryReader]::new($stream)
    try {
        if($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5a4d) {throw "Not PE: $Path"}
        $stream.Position=60
        $offset=$reader.ReadUInt32()
        if($offset -lt 64 -or $offset -gt $stream.Length-6) {throw 'Invalid PE offset'}
        $stream.Position=$offset
        if($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne $Machine) {throw "Wrong PE architecture: $Path"}
    } finally {$reader.Dispose()}
}
function Assert-PackagePayload([string]$Directory,[string]$Revision,[string]$Version) {
    $manifest=Get-Content -LiteralPath (Join-Path $Directory 'payload.json') -Raw | ConvertFrom-Json
    if($manifest.schema -ne 1 -or $manifest.source_revision -cne $Revision -or $manifest.version -cne $Version) {throw 'Payload provenance mismatch'}
    $required=@('CustomActions.dll','winfsp-msil.dll','winfsp-msil.xml','memfs-dotnet-msil.exe')
    foreach($arch in @('x86','x64','a64')) {
        $required+=@("winfsp-$arch.sys","winfsp-$arch.dll","winfsp-$arch.lib","launcher-$arch.exe",
            "launchctl-$arch.exe","fsptool-$arch.exe","memfs-$arch.exe","fuse-$arch.pc","fuse3-$arch.pc")
    }
    $names=@($manifest.files.PSObject.Properties.Name)
    foreach($name in $required) {if($name -cnotin $names) {throw "Missing payload: $name"}}
    foreach($property in $manifest.files.PSObject.Properties) {
        $name=$property.Name
        if($name -cnotmatch '^[a-zA-Z0-9_.-]+$' -or $name -eq 'payload.json') {throw 'Invalid payload filename'}
        Assert-ArchiveName $name
        $path=Join-Path $Directory $name
        Assert-PinnedFile $path $property.Value
        if($name -match '-(x86|x64|a64)\.(sys|dll|exe)$') {
            $machine=@{x86=0x14c;x64=0x8664;a64=0xaa64}[$Matches[1]]
            Assert-PeMachine $path $machine
        }
    }
    Assert-PeMachine (Join-Path $Directory 'CustomActions.dll') 0x14c
    foreach($file in Get-ChildItem -LiteralPath $Directory -Force) {
        if($file.PSIsContainer -or ($file.Name -ne 'payload.json' -and $file.Name -cnotin $names)) {throw 'Unmanifested payload file'}
    }
    return $manifest
}
