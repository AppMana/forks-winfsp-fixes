package lab

import "testing"

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
