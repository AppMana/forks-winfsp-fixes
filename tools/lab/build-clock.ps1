function Assert-LabBuildClock {
    param([Parameter(Mandatory)][DateTimeOffset]$HostUtc)
    if ([Math]::Abs(([DateTimeOffset]::UtcNow - $HostUtc).TotalSeconds) -gt 120) {
        throw 'host/guest clock discrepancy or stale build request'
    }
}
