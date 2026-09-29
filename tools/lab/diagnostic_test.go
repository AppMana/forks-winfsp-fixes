package lab

import (
	"os/exec"
	"testing"
)

func TestBuildClockRejectsSkewBeforeSigning(t *testing.T) {
	pwsh, err := exec.LookPath("pwsh")
	if err != nil {
		t.Skip("PowerShell required")
	}
	script := `$ErrorActionPreference='Stop'; . ./build-clock.ps1;
        Assert-LabBuildClock -HostUtc ([DateTimeOffset]::UtcNow);
        foreach($hours in @(-7,7)) {
            $rejected=$false;
            try { Assert-LabBuildClock -HostUtc ([DateTimeOffset]::UtcNow.AddHours($hours)) }
            catch { if($_.Exception.Message -ne 'host/guest clock discrepancy or stale build request'){throw}; $rejected=$true }
            if(-not $rejected){throw 'accepted seven-hour clock skew'}
        }`
	if output, err := exec.Command(pwsh, "-NoProfile", "-NonInteractive", "-Command", script).CombinedOutput(); err != nil {
		t.Fatalf("clock contract: %v\n%s", err, output)
	}
}

func TestReparseDiagnosticModeIsExplicit(t *testing.T) {
	for _, tc := range []struct {
		value     string
		conflict  bool
		want      bool
		wantError bool
	}{
		{"", false, false, false},
		{"1", false, true, false},
		{"true", false, false, true},
		{"0", false, false, true},
		{"1", true, false, true},
	} {
		got, err := reparseDiagnosticMode(tc.value, tc.conflict)
		if got != tc.want || (err != nil) != tc.wantError {
			t.Fatalf("%+v: got %v, %v", tc, got, err)
		}
	}
}
