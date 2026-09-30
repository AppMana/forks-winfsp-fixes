$ErrorActionPreference='Stop'
. "$PSScriptRoot/process.ps1"
$out=[IO.Path]::GetTempFileName()
$err=[IO.Path]::GetTempFileName()
$directory=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item $directory -ItemType Directory | Out-Null
try {
    $exe=(Get-Process -Id $PID).Path
    # Fast child exit, explicit nonzero status and both redirected streams.
    $script="[Console]::Out.Write('stdout-proof');[Console]::Error.Write('stderr-proof');exit 23"
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    $code=Invoke-NativeLabProcess $exe @('-NoProfile','-EncodedCommand',$encoded) $out $err 30000
    if($code -ne 23 -or [IO.File]::ReadAllText($out) -cne 'stdout-proof' -or [IO.File]::ReadAllText($err) -cne 'stderr-proof'){throw 'Lost process status or output'}
    # PowerShell Set-Location does not change the OS process working directory.
    # The child must use the caller's selected filesystem location explicitly.
    Push-Location $directory
    try {
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('[Console]::Out.Write([Environment]::CurrentDirectory)'))
        $code=Invoke-NativeLabProcess $exe @('-NoProfile','-EncodedCommand',$encoded) $out $err 30000
        if($code -ne 0 -or [IO.File]::ReadAllText($out) -cne $directory){throw 'Native child ignored the selected working directory'}
    } finally {Pop-Location}
    # The child observes its own redirected output before it exits. Buffering
    # until process termination cannot satisfy this check.
    [IO.File]::WriteAllText($out,'')
    $quoted=$out.Replace("'","''")
    $script=@'
[Console]::Out.Write('live-proof');[Console]::Out.Flush()
for($i=0;$i -lt 40;$i++) {
    $file=[IO.File]::Open('__LOG_PATH__',[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    $reader=[IO.StreamReader]::new($file)
    try {if($reader.ReadToEnd().Contains('live-proof')){exit 0}} finally {$reader.Dispose()}
    Start-Sleep -Milliseconds 50
}
exit 31
'@
    $script=$script.Replace('__LOG_PATH__',$quoted)
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    if((Invoke-NativeLabProcess $exe @('-NoProfile','-EncodedCommand',$encoded) $out $err 30000) -ne 0){throw 'Native logs are invisible while the process is running'}
    # Preserve the exact regression inventory when prepending --list. This
    # also guards against accidentally dropping the network projection RED.
    $selection=@('reparse_mount_target_test','reparse_net_projected_target_test')
    $inventoryArguments=@('--list')+@($selection)
    if($inventoryArguments.Count -ne 3 -or
       $inventoryArguments[1] -cne $selection[0] -or
       $inventoryArguments[2] -cne $selection[1]){throw 'Regression selection was changed or lost'}
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('Start-Sleep -Seconds 60'))
    $timedOut=$false
    try {Invoke-NativeLabProcess $exe @('-NoProfile','-EncodedCommand',$encoded) $out $err 1000 | Out-Null}
    catch {if($_.Exception.Message -eq 'Native suite timed out'){$timedOut=$true}else{throw}}
    if(-not $timedOut){throw 'Process deadline was not enforced'}
    'PASS: fast native process preserves exit/stdout/stderr and enforces deadline'
} finally {Remove-Item -LiteralPath $out,$err; Remove-Item -LiteralPath $directory}
