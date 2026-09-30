function Invoke-NativeLabProcess {
    param([string]$Executable, [string[]]$Arguments, [string]$StdoutPath,
          [string]$StderrPath, [int]$TimeoutMillis=1100000)
    $p=New-Object System.Diagnostics.Process
    $p.StartInfo.FileName=$Executable
    # Harness arguments are controlled option names/paths without spaces.
    if(@($Arguments | Where-Object {$_ -match '[\s"]'}).Count){throw 'Unsupported native argument quoting'}
    $p.StartInfo.Arguments=$Arguments -join ' '
    $p.StartInfo.UseShellExecute=$false
    $p.StartInfo.CreateNoWindow=$true
    $p.StartInfo.RedirectStandardOutput=$true
    $p.StartInfo.RedirectStandardError=$true
    $stdoutFile=$null; $stderrFile=$null
    try {
        # Drain both pipes continuously to readable, unbuffered files. Waiting
        # for exit before writing logs hides progress and crash evidence.
        $stdoutFile=[IO.FileStream]::new($StdoutPath,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite,1,[IO.FileOptions]::Asynchronous)
        $stderrFile=[IO.FileStream]::new($StderrPath,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite,1,[IO.FileOptions]::Asynchronous)
        if(-not $p.Start()){throw 'Native process did not start'}
        $stdout=$p.StandardOutput.BaseStream.CopyToAsync($stdoutFile)
        $stderr=$p.StandardError.BaseStream.CopyToAsync($stderrFile)
        $finished=$p.WaitForExit($TimeoutMillis)
        if(-not $finished){$p.Kill(); $p.WaitForExit()}
        $null=$stdout.GetAwaiter().GetResult(); $stdoutFile.Flush()
        $null=$stderr.GetAwaiter().GetResult(); $stderrFile.Flush()
        if(-not $finished){throw 'Native suite timed out'}
        return $p.ExitCode
    } finally {
        if($stdoutFile){$stdoutFile.Dispose()}
        if($stderrFile){$stderrFile.Dispose()}
        $p.Dispose()
    }
}
