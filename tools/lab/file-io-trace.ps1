# Observe an already-running isolated qualification; never reinterpret its exit.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9-]{1,64}$')][string]$SessionName,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$Transcript,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$DriverSHA256,
    [ValidateRange(1,1800)][int]$TimeoutSeconds=600
)
$ErrorActionPreference='Stop'
if([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18'){throw 'Native lab SYSTEM token required'}
if((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control').PSObject.Properties['ContainerType']){throw 'Native VM required'}
if(-not [IO.Path]::IsPathRooted($OutputDirectory) -or -not (Test-Path $OutputDirectory -PathType Container)){throw 'Existing absolute artifact directory required'}
$etl=Join-Path $OutputDirectory "$SessionName.etl"
$metadata=Join-Path $OutputDirectory "$SessionName.json"
if((Test-Path $etl) -or (Test-Path $metadata)){throw 'Capture must be fresh'}
$drivers=@(Get-CimInstance Win32_SystemDriver | Where-Object {$_.Name -like 'WinFsp*' -and $_.State -eq 'Running'})
if($drivers.Count -ne 1){throw 'Exactly one running WinFsp driver required'}
$path=$drivers[0].PathName.Trim('"') -replace '^\\\?\?\\',''
if((Get-FileHash -LiteralPath $path).Hash -ine $DriverSHA256){throw 'Wrong diagnostic driver'}
$provider='{EDD08927-9CC4-4E65-B970-C2560FB5C289}'
$record=@{provider=$provider;keywords='0x4f0';driver=$path;driver_sha256=$DriverSHA256;
    started_utc=[DateTime]::UtcNow.ToString('o');transcript=$Transcript;test_result='not interpreted';
    processes=@(Get-Process | Select-Object Id,ProcessName);complete=$false}
$record | ConvertTo-Json -Depth 4 | Set-Content $metadata
# File names, create/cleanup/close, operation-end status and delete paths.
# Exclude bulk read/write events and bound the circular trace to 16 MiB.
& logman.exe start $SessionName -p $provider 0x4f0 4 -o $etl -f bincirc -max 16 -ets
if($LASTEXITCODE -ne 0){throw 'Kernel file trace start failed'}
try {
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if((Test-Path $Transcript) -and (Select-String -LiteralPath $Transcript -SimpleMatch 'Windows PowerShell transcript end' -Quiet)) {
            $record.complete=$true
            break
        }
        Start-Sleep -Seconds 2
    } while([DateTime]::UtcNow -lt $deadline)
} finally {
    & logman.exe stop $SessionName -ets
    $record.stop_exit=$LASTEXITCODE
    $record.stopped_utc=[DateTime]::UtcNow.ToString('o')
    $record | ConvertTo-Json -Depth 4 | Set-Content $metadata
}
if($record.stop_exit -ne 0){throw 'Kernel file trace did not stop cleanly'}
if(-not $record.complete){throw 'Bounded trace timed out before the observed transcript ended'}
'FILE_IO_TRACE_COMPLETE'
