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
    try {
        if(-not $p.Start()){throw 'Native process did not start'}
        $stdout=$p.StandardOutput.ReadToEndAsync()
        $stderr=$p.StandardError.ReadToEndAsync()
        $finished=$p.WaitForExit($TimeoutMillis)
        if(-not $finished){$p.Kill(); $p.WaitForExit()}
        [IO.File]::WriteAllText($StdoutPath,$stdout.GetAwaiter().GetResult())
        [IO.File]::WriteAllText($StderrPath,$stderr.GetAwaiter().GetResult())
        if(-not $finished){throw 'Native suite timed out'}
        return $p.ExitCode
    } finally { $p.Dispose() }
}
