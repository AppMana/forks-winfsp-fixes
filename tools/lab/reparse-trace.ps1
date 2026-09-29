# Bounded, explicit ETW collection in an isolated native Windows lab VM.
# Run the unchanged filesystem test between Start and Stop. This tool does not
# install drivers, run tests, restart services, or reinterpret a failing test.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Start','Stop')][string]$Action,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9-]{1,64}$')][string]$SessionName,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidatePattern('^[0-9a-f]{64}$')][string]$DriverSHA256
)
$ErrorActionPreference='Stop'
if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18') { throw 'isolated lab SYSTEM token required' }
if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control').PSObject.Properties['ContainerType']) { throw 'native lab VM required' }
if (-not [IO.Path]::IsPathRooted($OutputDirectory)) { throw 'absolute output directory required' }
$provider='{77769d82-1374-4d50-b8da-568715c1a845}'
$etl=Join-Path $OutputDirectory 'reparse.etl'
$record=Join-Path $OutputDirectory 'capture.json'
if ($Action -eq 'Start') {
    if (-not $DriverSHA256) { throw 'expected diagnostic driver digest required' }
    if (Test-Path -LiteralPath $OutputDirectory) { throw 'capture directory must be new' }
    $driver=Get-CimInstance Win32_SystemDriver | Where-Object Name -eq WinFsp
    if (-not $driver -or $driver.State -ne 'Running') { throw 'WinFsp driver must already be running' }
    $path=$driver.PathName -replace '^\\\?\?\\',''
    if ((Get-FileHash -LiteralPath $path).Hash -ine $DriverSHA256) { throw 'unexpected driver digest' }
    if ((Get-AuthenticodeSignature -LiteralPath $path).Status -ne 'Valid') { throw 'invalid diagnostic driver signature' }
    New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
    $metadata=@{session=$SessionName;provider=$provider;driver=$path;driver_sha256=$DriverSHA256;
        boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToFileTimeUtc();started_utc=[DateTime]::UtcNow.ToString('o')}
    [IO.File]::WriteAllText($record,($metadata | ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
    # Manifest-free EtwWriteString providers need not appear in logman's named
    # provider catalog. Enable the GUID directly and verify captured events.
    & logman.exe start $SessionName -p $provider 0x1 4 -o $etl -f bincirc -max 32 -ets
    if ($LASTEXITCODE -ne 0) { throw 'ETW start failed; capture directory retained' }
} else {
    $metadata=Get-Content -LiteralPath $record -Raw | ConvertFrom-Json
    if ($metadata.session -cne $SessionName -or $metadata.provider -cne $provider) { throw 'capture identity mismatch' }
    $xml=Join-Path $OutputDirectory 'reparse.xml'
    $summary=Join-Path $OutputDirectory 'summary.txt'
    if ((Test-Path -LiteralPath $xml) -or (Test-Path -LiteralPath $summary)) { throw 'decoded outputs already exist' }
    & logman.exe stop $SessionName -ets
    if ($LASTEXITCODE -ne 0) { throw 'ETW stop failed; do not infer that recording ended' }
    & tracerpt.exe $etl -o $xml -of XML -summary $summary
    if ($LASTEXITCODE -ne 0) { throw 'ETW decode failed; original ETL retained' }
    [xml]$events=Get-Content -LiteralPath $xml -Raw
    $diagnostics=@($events.SelectNodes("//*[local-name()='Event'][*[local-name()='System']/*[local-name()='Provider']/@Guid='$provider']"))
    Get-Content -LiteralPath $summary
    if ($diagnostics.Count -eq 0) { throw 'no diagnostic events captured; not valid branch evidence' }
    foreach ($event in $diagnostics) {
        $event.SelectNodes(".//*[local-name()='Data']") | ForEach-Object InnerText
    }
    Write-Output "REPARSE_TRACE_CAPTURED:$($diagnostics.Count)"
}
