$ErrorActionPreference='Stop'
. "$PSScriptRoot\inputs.ps1"
function Reject([scriptblock]$Action) {
    $failed=$false
    try { & $Action } catch { $failed=$true }
    if(-not $failed){throw 'Invalid package input accepted'}
}
function New-TestLibrary([int]$Machine) {
    $object=New-Object byte[] 20
    $object[2]=255; $object[3]=255
    $object[6]=$Machine -band 255; $object[7]=$Machine -shr 8
    $header='object/'.PadRight(16)+(' '*32)+'20'.PadRight(10)+[char]96+"`n"
    return ,([byte[]]([Text.Encoding]::ASCII.GetBytes("!<arch>`n"+$header)+$object))
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
    foreach($order in @(@('a','a/b'),@('a/b','A'))) {
        $collision=Join-Path $root ([guid]::NewGuid().ToString()+'.zip')
        $z=[IO.Compression.ZipFile]::Open($collision,'Create')
        try {foreach($name in $order){$null=$z.CreateEntry($name)}} finally {$z.Dispose()}
        Reject {Expand-CheckedArchive $collision (Join-Path $root 'out')}
        if(Test-Path (Join-Path $root 'out')) {throw 'Prefix collision partially extracted'}
    }
    $linkZip=Join-Path $root 'link.zip'
    $z=[IO.Compression.ZipFile]::Open($linkZip,'Create')
    try {
        $entry=$z.CreateEntry('link'); $entry.ExternalAttributes=-1577123840
        $stream=$entry.Open(); $writer=[IO.StreamWriter]::new($stream)
        try {$writer.Write('../escaped')} finally {$writer.Dispose()}
    } finally {$z.Dispose()}
    $linkOut=Join-Path $root 'link-out'
    Expand-CheckedArchive $linkZip $linkOut
    $materialized=Get-Item (Join-Path $linkOut 'link')
    if($materialized.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Archive symlink materialized'}
    if([IO.File]::ReadAllText($materialized.FullName) -ne '../escaped'){throw 'Symlink bytes not preserved'}
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
            if($name.EndsWith('.lib')) {[IO.File]::WriteAllBytes($path,(New-TestLibrary $machine))}
            $files[$name]=(Get-FileHash $path).Hash.ToLowerInvariant()
        }
    }
    foreach($name in @('CustomActions.dll','winfsp-msil.dll','winfsp-msil.xml','memfs-dotnet-msil.exe')) {
        $bytes[132]=0x4c; $bytes[133]=1
        $path=Join-Path $payload $name
        [IO.File]::WriteAllBytes($path,$bytes)
        $files[$name]=(Get-FileHash $path).Hash.ToLowerInvariant()
    }
    $manifest=@{schema=1;source_revision='a'*40;source_archive_sha256='c'*64;version='2.2.26271';files=$files}
    $manifest | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $payload 'payload.json')
    $null=Assert-PackagePayload $payload ('a'*40) '2.2.26271' ('c'*64)
    # WDK places a winfsp.sys staging directory beside the actual outputs.
    # The installer consumes a flat payload, not that build-only directory.
    $wdk=Join-Path $payload 'winfsp.sys'
    New-Item $wdk -ItemType Directory | Out-Null
    [IO.File]::WriteAllText((Join-Path $wdk 'driver.inf'),'WDK staging only')
    Reject {Assert-PackagePayload $payload ('a'*40) '2.2.26271' ('c'*64)}
    $flat=Join-Path $root 'flat-payload'
    Export-PackagePayload $payload $flat ('a'*40) '2.2.26271' ('c'*64)
    $null=Assert-PackagePayload $flat ('a'*40) '2.2.26271' ('c'*64)
    if(Test-Path (Join-Path $flat 'winfsp.sys')){throw 'WDK intermediate leaked into payload'}
    if(-not(Test-Path (Join-Path $wdk 'driver.inf'))){throw 'Original build outputs modified'}
    Reject {Export-PackagePayload $payload $flat ('a'*40) '2.2.26271' ('c'*64)}
    Remove-Item $wdk -Recurse
    Reject {Assert-PackagePayload $payload ('b'*40) '2.2.26271' ('c'*64)}
    Reject {Assert-PackagePayload $payload ('a'*40) '2.2.26272' ('c'*64)}
    Reject {Assert-PackagePayload $payload ('a'*40) '2.2.26271' ('d'*64)}
    # Even updating the manifest hash must not disguise the wrong machine.
    $library=Join-Path $payload 'winfsp-a64.lib'
    [IO.File]::WriteAllBytes($library,(New-TestLibrary 0x8664))
    $files['winfsp-a64.lib']=(Get-FileHash $library).Hash.ToLowerInvariant()
    $manifest | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $payload 'payload.json')
    Reject {Assert-PackagePayload $payload ('a'*40) '2.2.26271' ('c'*64)}
    [IO.File]::WriteAllBytes($library,(New-TestLibrary 0xaa64))
    $files['winfsp-a64.lib']=(Get-FileHash $library).Hash.ToLowerInvariant()
    $manifest | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $payload 'payload.json')
    $null=Assert-PackagePayload $payload ('a'*40) '2.2.26271' ('c'*64)
    [IO.File]::WriteAllText((Join-Path $payload 'extra.dll'),'untracked')
    Reject {Assert-PackagePayload $payload ('a'*40) '2.2.26271' ('c'*64)}
    Remove-Item (Join-Path $payload 'extra.dll')
    [IO.File]::WriteAllText((Join-Path $payload 'winfsp-x64.sys'),'tampered')
    Reject {Assert-PackagePayload $payload ('a'*40) '2.2.26271' ('c'*64)}
    $files.Remove('winfsp-x64.sys')
    $manifest | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $payload 'payload.json')
    Reject {Assert-PackagePayload $payload ('a'*40) '2.2.26271' ('c'*64)}
    $repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $managed=Join-Path $root 'winfsp.net.csproj'
    Copy-Item (Join-Path $repository 'build/VStudio/dotnet/winfsp.net.csproj') $managed
    Select-MsiManagedTarget $managed
    [xml]$managedXml=Get-Content $managed -Raw
    if($managedXml.SelectSingleNode('/Project/PropertyGroup/TargetFrameworks').InnerText -cne 'net35') {throw 'MSI binding target not selected'}
    $sample=Join-Path $repository 'build/VStudio/testing/memfs-dotnet.csproj'
    $sampleHash=(Get-FileHash $sample).Hash
    Reject {Select-MsiManagedTarget $sample}
    if((Get-FileHash $sample).Hash -cne $sampleHash){throw 'Sample framework changed'}
    if([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'build-payload.ps1')).Contains('/p:TargetFrameworks=')){throw 'Global framework override breaks the net452 sample restore'}
    foreach($arch in @('x86','x64','a64')) {
        Assert-CoffLibraryMachine (Join-Path $repository "opt/fsext/lib/winfsp-$arch.lib") (@{x86=0x14c;x64=0x8664;a64=0xaa64}[$arch])
    }
    $product=Join-Path $root 'Product.wxs'
    Copy-Item (Join-Path $repository 'build/VStudio/installer/Product.wxs') $product
    [xml]$before=Get-Content $product -Raw
    Add-LabInstallerGuards $product
    [xml]$after=Get-Content $product -Raw
    foreach($id in @('APPMANA_LAB_ONLY','WIXFAILWHENDEFERRED','WixFailWhenDeferred')) {
        if($after.SelectNodes("//*[@Id='$id']").Count -ne 1){throw "Missing or duplicate MSI guard: $id"}
    }
    $manager=[Xml.XmlNamespaceManager]::new($after.NameTable); $manager.AddNamespace('w','http://schemas.microsoft.com/wix/2006/wi')
    if($after.SelectNodes('/w:Wix/w:Product/w:Condition[contains(text(),"APPMANA_LAB_ONLY")]', $manager).Count -ne 1){throw 'Launch condition absent'}
    $condition=$after.SelectSingleNode('/w:Wix/w:Product/w:Condition[contains(text(),"APPMANA_LAB_ONLY")]', $manager)
    if($condition.InnerText -cne 'Installed OR APPMANA_LAB_ONLY = "1"'){throw 'Lab opt-in condition weakened'}
    foreach($id in @('APPMANA_LAB_ONLY','WIXFAILWHENDEFERRED')) {
        if($after.SelectSingleNode("//*[@Id='$id']").GetAttribute('Secure') -cne 'yes'){throw 'Installer property is not secure'}
    }
    if($after.SelectSingleNode("//*[@Id='WIXFAILWHENDEFERRED']").GetAttribute('Value') -cne '0'){throw 'Rollback fault enabled by default'}
    if($after.SelectNodes('/w:Wix/w:Product/w:CustomActionRef[@Id="WixFailWhenDeferred"]',$manager).Count -ne 1){throw 'Rollback action reference absent'}
    if($before.Wix.Product.UpgradeCode -cne $after.Wix.Product.UpgradeCode -or
        $before.SelectNodes('//*[local-name()="File"]').Count -ne $after.SelectNodes('//*[local-name()="File"]').Count){throw 'Upstream package identity or payload changed'}
    Reject {Add-LabInstallerGuards $product}
    foreach($script in @('build-msi.ps1','build-payload.ps1')) {
        $tokens=$null; $errors=$null
        $null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $script),[ref]$tokens,[ref]$errors)
        if($errors.Count){throw ($errors | Out-String)}
    }
    'PACKAGE_INPUT_CONTRACTS_PASS'
} finally {Remove-Item -LiteralPath $root -Recurse -Force}
