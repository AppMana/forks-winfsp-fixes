Set-StrictMode -Version Latest
function Select-MsiManagedTarget([string]$Path) {
    [xml]$project=[IO.File]::ReadAllText($Path)
    $targets=$project.SelectNodes('/Project/PropertyGroup/TargetFrameworks')
    if($targets.Count -ne 1 -or $targets[0].InnerText -cne 'netstandard2.0;net35') {
        throw 'Expected the upstream dual-target WinFsp binding project; refusing to retarget another project'
    }
    # The upstream MSI consumes the net35 output. The separate netstandard
    # NuGet product is not built here. Never pass this as a global property:
    # that also changes the net452 sample restore graph to net35 (NETSDK1005).
    $targets[0].InnerText='net35'
    $project.Save($Path)
}
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
        }
        $leaves=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($entry in $archive.Entries) {if(-not $entry.FullName.EndsWith('/')) {$null=$leaves.Add($entry.FullName)}}
        foreach($entry in $archive.Entries) {
            $parts=$entry.FullName.TrimEnd('/').Split('/')
            for($i=1;$i -lt $parts.Count;$i++) {
                if($leaves.Contains(($parts[0..($i-1)] -join '/'))) {throw 'Archive file/directory collision'}
            }
        }
        # Materialize bytes only, never UNIX symlinks or reparse points. The
        # upstream git archive contains tools/build-choco.bat as a symlink;
        # MSI assembly does not execute it. Treating it as inert text allows
        # exact git archives without ever following archive-supplied links.
        $null=[IO.Directory]::CreateDirectory($Destination)
        foreach($entry in $archive.Entries) {
            $path=Join-Path $Destination $entry.FullName
            if($entry.FullName.EndsWith('/')) {
                $null=[IO.Directory]::CreateDirectory($path)
                continue
            }
            $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
            $from=$entry.Open()
            try {
                $to=[IO.File]::Open($path,[IO.FileMode]::CreateNew)
                try {$from.CopyTo($to)} finally {$to.Dispose()}
            } finally {$from.Dispose()}
        }
    } finally {$archive.Dispose()}
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
function Assert-CoffLibraryMachine([string]$Path,[int]$Machine) {
    $stream=[IO.File]::OpenRead($Path)
    $reader=[IO.BinaryReader]::new($stream)
    try {
        if([Text.Encoding]::ASCII.GetString($reader.ReadBytes(8)) -cne "!<arch>`n") {throw 'Not a COFF archive'}
        $objects=0
        while($stream.Position -lt $stream.Length) {
            $header=[Text.Encoding]::ASCII.GetString($reader.ReadBytes(60))
            if($header.Length -ne 60 -or $header.Substring(58) -cne ([char]96+"`n")) {throw 'Invalid COFF archive member'}
            $name=$header.Substring(0,16).Trim()
            [long]$size=0
            if(-not [long]::TryParse($header.Substring(48,10).Trim(),[ref]$size) -or $size -lt 0 -or
                $size -gt $stream.Length-$stream.Position) {throw 'Invalid COFF member size'}
            $start=$stream.Position
            if($name -notin @('/','//','/SYM64/')) {
                if($size -lt 20){throw 'Truncated COFF object'}
                $first=$reader.ReadUInt16(); $second=$reader.ReadUInt16()
                $actual=$first
                if($first -eq 0 -and $second -eq 0xffff) {
                    $null=$reader.ReadUInt16(); $actual=$reader.ReadUInt16()
                }
                if($actual -ne $Machine){throw "Wrong COFF architecture: $Path"}
                $objects++
            }
            $stream.Position=$start+$size
            if($size % 2) {
                if($stream.Position -ge $stream.Length -or $reader.ReadByte() -ne 10){throw 'Invalid COFF padding'}
            }
        }
        if(-not $objects){throw 'COFF archive has no objects'}
    } finally {$reader.Dispose()}
}
function Add-LabInstallerGuards([string]$Path) {
    [xml]$xml=[IO.File]::ReadAllText($Path)
    $ns='http://schemas.microsoft.com/wix/2006/wi'
    $manager=[Xml.XmlNamespaceManager]::new($xml.NameTable); $manager.AddNamespace('w',$ns)
    $product=$xml.SelectSingleNode('/w:Wix/w:Product',$manager)
    if(-not $product){throw 'Unknown WiX product schema'}
    foreach($id in @('APPMANA_LAB_ONLY','WIXFAILWHENDEFERRED','WixFailWhenDeferred')) {
        if($xml.SelectNodes("//*[@Id='$id']").Count){throw "Installer guard already exists: $id"}
    }
    $condition=$xml.CreateElement('Condition',$ns)
    $condition.SetAttribute('Message','AppMana lab package: isolated VM installation requires APPMANA_LAB_ONLY=1.')
    $condition.InnerText='Installed OR APPMANA_LAB_ONLY = "1"'
    $null=$product.AppendChild($condition)
    foreach($id in @('APPMANA_LAB_ONLY','WIXFAILWHENDEFERRED')) {
        $property=$xml.CreateElement('Property',$ns)
        $property.SetAttribute('Id',$id); $property.SetAttribute('Secure','yes')
        if($id -eq 'WIXFAILWHENDEFERRED'){$property.SetAttribute('Value','0')}
        $null=$product.AppendChild($property)
    }
    $action=$xml.CreateElement('CustomActionRef',$ns); $action.SetAttribute('Id','WixFailWhenDeferred')
    $null=$product.AppendChild($action)
    $xml.Save($Path)
}
function Export-PackagePayload([string]$BuildDirectory,[string]$Directory,[string]$Revision,[string]$Version,[string]$SourceSha256) {
    if(Test-Path -LiteralPath $Directory){throw 'Payload destination must be fresh'}
    New-Item -Path $Directory -ItemType Directory | Out-Null
    $files=@{}
    # Upstream's installer references flat outputs. WDK also creates nested
    # intermediate directories: preserve them at the build site, not in MSI input.
    foreach($file in Get-ChildItem -LiteralPath $BuildDirectory -File -Force) {
        if($file.Name -eq 'payload.json'){continue}
        Assert-ArchiveName $file.Name
        Copy-Item -LiteralPath $file.FullName -Destination $Directory
        $files[$file.Name]=(Get-FileHash (Join-Path $Directory $file.Name)).Hash.ToLowerInvariant()
    }
    @{schema=1;source_revision=$Revision;source_archive_sha256=$SourceSha256;version=$Version;files=$files} |
        ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Directory 'payload.json')
    $null=Assert-PackagePayload $Directory $Revision $Version $SourceSha256
}
function Assert-PackagePayload([string]$Directory,[string]$Revision,[string]$Version,[string]$SourceSha256) {
    $manifest=Get-Content -LiteralPath (Join-Path $Directory 'payload.json') -Raw | ConvertFrom-Json
    if($manifest.schema -ne 1 -or $manifest.source_revision -cne $Revision -or $manifest.version -cne $Version) {throw 'Payload provenance mismatch'}
    if($SourceSha256 -cnotmatch '^[0-9a-f]{64}$' -or $manifest.source_archive_sha256 -cne $SourceSha256) {throw 'Payload source archive mismatch'}
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
        if($name -match '-(x86|x64|a64)\.lib$') {
            Assert-CoffLibraryMachine $path (@{x86=0x14c;x64=0x8664;a64=0xaa64}[$Matches[1]])
        }
    }
    Assert-PeMachine (Join-Path $Directory 'CustomActions.dll') 0x14c
    foreach($file in Get-ChildItem -LiteralPath $Directory -Force) {
        if($file.PSIsContainer -or ($file.Name -ne 'payload.json' -and $file.Name -cnotin $names)) {throw 'Unmanifested payload file'}
    }
    return $manifest
}
