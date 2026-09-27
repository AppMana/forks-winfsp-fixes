function Assert-NativeSuiteEvidence {
    param([string[]]$Inventory, [string]$Output, [int]$ExitCode)
    $names=@($Inventory | ForEach-Object {$_.Trim()} | Where-Object {$_})
    if($ExitCode -ne 0 -or $names.Count -eq 0 -or
       @($names | Where-Object {$_ -notmatch '^[A-Za-z0-9_]+$'}).Count -ne 0 -or
       @($names | Sort-Object -Unique).Count -ne $names.Count) {throw 'Invalid native suite exit/inventory'}
    $lines=@($Output -split '\r?\n' | Where-Object {$_})
    if($lines.Count -ne $names.Count+1 -or $lines[-1] -cne '--- COMPLETE ---') {throw 'Incomplete native suite'}
    for($i=0;$i -lt $names.Count;$i++) {
        # tst/tlib/testsuite.c uses char dispname[39+1], excluding the NUL.
        $name=$names[$i].Substring(0,[Math]::Min(39,$names[$i].Length)).PadRight(39,'.')
        if($lines[$i] -cnotmatch ('^'+[regex]::Escape($name)+' OK [0-9]+\.[0-9]+s$')) {throw "Native test missing or failed: $($names[$i])"}
    }
}
