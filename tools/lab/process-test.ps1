$ErrorActionPreference='Stop'
. "$PSScriptRoot/process.ps1"
$out=[IO.Path]::GetTempFileName()
$err=[IO.Path]::GetTempFileName()
try {
    $exe=(Get-Process -Id $PID).Path
    # Fast child exit, explicit nonzero status and both redirected streams.
    $script="[Console]::Out.Write('stdout-proof');[Console]::Error.Write('stderr-proof');exit 23"
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    $code=Invoke-NativeLabProcess $exe @('-NoProfile','-EncodedCommand',$encoded) $out $err 30000
    if($code -ne 23 -or [IO.File]::ReadAllText($out) -cne 'stdout-proof' -or [IO.File]::ReadAllText($err) -cne 'stderr-proof'){throw 'Lost process status or output'}
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('Start-Sleep -Seconds 60'))
    $timedOut=$false
    try {Invoke-NativeLabProcess $exe @('-NoProfile','-EncodedCommand',$encoded) $out $err 1000 | Out-Null}
    catch {if($_.Exception.Message -eq 'Native suite timed out'){$timedOut=$true}else{throw}}
    if(-not $timedOut){throw 'Process deadline was not enforced'}
    'PASS: fast native process preserves exit/stdout/stderr and enforces deadline'
} finally {Remove-Item -LiteralPath $out,$err}
