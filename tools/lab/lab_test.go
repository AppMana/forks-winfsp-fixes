package lab

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	labv1 "github.com/appmana/labcontainers/api/v1"
	"github.com/appmana/labcontainers/pkg/client"
	clab "github.com/appmana/labcontainers/pkg/containerlab"
	"github.com/srl-labs/containerlab/core"
	"github.com/srl-labs/containerlab/links"
	"github.com/srl-labs/containerlab/types"
)

const ewdkSHA = "9f48251dd24ad31aac206d8256e95bda5f90a9783982c45a8aafeb9054562379"
const msiSHA = "073a70e00f77423e34bed98b86e600def93393ba5822204fac57a29324db9f7a"
const helperRevision = "56e537c59dcb051ae6dba677a557db2483b6fefc"
const helperSHA = "793bbca614dc48baadf3bbfdeb80073e8e673592456e4644380aeb469405e55f"
const powershell = `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`
const observerCacheSHA = "3bbc30a59fb551e0caccc77344e92672096aaf7859bdc3dd94a505062615a9fe"
const observerCacheRevision = "b5c3c595c306a4b8d319e507bb80a6c0ac3007ad"
const observerResultsSHA = "a2bbdd45a8e1112a1ad6473ed5956fbabc599faf42a51569657478966e3633aa"

type nativeLabPlan struct {
	buildOnly     bool
	stockObserver bool
	install       bool
	reboot        bool
	suites        []string
}

func nativePlan(buildOnly, stockObserver string) (nativeLabPlan, error) {
	if buildOnly != "" && buildOnly != "1" {
		return nativeLabPlan{}, fmt.Errorf("WINFSP_LAB_BUILD_ONLY must be empty or 1")
	}
	if stockObserver != "" && stockObserver != "1" {
		return nativeLabPlan{}, fmt.Errorf("WINFSP_LAB_STOCK_OBSERVER must be empty or 1")
	}
	if buildOnly == "1" && stockObserver == "1" {
		return nativeLabPlan{}, fmt.Errorf("build-only and stock-observer modes are mutually exclusive")
	}
	switch {
	case buildOnly == "1":
		return nativeLabPlan{buildOnly: true}, nil
	case stockObserver == "1":
		return nativeLabPlan{stockObserver: true, install: true, reboot: true}, nil
	default:
		return nativeLabPlan{install: true, reboot: true,
			suites: []string{"regression", "reparse", "full", "directory", "directory-sensitive", "mountmgr"}}, nil
	}
}

func focusedSuite(value string) (string, error) {
	switch value {
	case "", "lock-noncached":
		return value, nil
	default:
		return "", fmt.Errorf("WINFSP_LAB_FOCUSED_SUITE must be empty or lock-noncached")
	}
}

func checkedFile(path, want string) error {
	if !filepath.IsAbs(path) || strings.ContainsAny(path, ":\n\r") {
		return fmt.Errorf("absolute host path required: %q", path)
	}
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	h := sha256.New()
	if _, err = io.Copy(h, f); err != nil {
		return err
	}
	if fmt.Sprintf("%x", h.Sum(nil)) != want {
		return fmt.Errorf("digest mismatch: %s", path)
	}
	return nil
}

func topology(image, iso string) *core.Config {
	return &core.Config{Name: "winfsp-qualification", Topology: &types.Topology{
		Nodes: map[string]*types.NodeDefinition{
			"vm": {Kind: "generic_vm", Image: image, NetworkMode: "none", ImagePullPolicy: "Never",
				Binds: []string{iso + ":/ewdk.iso:ro"}, Env: map[string]string{"QEMU_ADDITIONAL_ARGS": "-drive file=/ewdk.iso,media=cdrom,readonly=on"}},
			"peer": {Kind: "linux", Image: "alpine:3.20", NetworkMode: "none", ImagePullPolicy: "Never"},
		}, Links: []*links.LinkDefinition{{Link: &links.LinkBriefRaw{Endpoints: []string{"vm:eth1", "peer:eth1"}}}},
	}}
}

// This opts into fresh disposable Windows VMs, not a host/cluster installer.
// The source archive is an exact commit; scripts and every input are retained.
func TestNativeWindows(t *testing.T) {
	if os.Getenv("WINFSP_LAB_LIVE") != "1" {
		t.Skip("set WINFSP_LAB_LIVE=1")
	}
	plan, err := nativePlan(os.Getenv("WINFSP_LAB_BUILD_ONLY"),
		os.Getenv("WINFSP_LAB_STOCK_OBSERVER"))
	if err != nil {
		t.Fatal(err)
	}
	focus, err := focusedSuite(os.Getenv("WINFSP_LAB_FOCUSED_SUITE"))
	if err != nil {
		t.Fatal(err)
	}
	if focus != "" && (plan.buildOnly || plan.stockObserver) {
		t.Fatal("focused suite cannot be combined with build-only or stock-observer mode")
	}
	iso, msi := os.Getenv("WINFSP_LAB_EWDK_ISO"), os.Getenv("SEAWEEDFS_WINFSP_MSI")
	inputs := map[string]string{iso: ewdkSHA}
	if !plan.buildOnly {
		inputs[msi] = msiSHA
	}
	for path, digest := range inputs {
		if err := checkedFile(path, digest); err != nil {
			t.Fatal(err)
		}
	}
	cachePath := os.Getenv("WINFSP_LAB_BUILD_CACHE")
	if plan.buildOnly {
		if err := checkedFile(cachePath, observerCacheSHA); err != nil {
			t.Fatal(err)
		}
	}
	observerPath := os.Getenv("WINFSP_LAB_OBSERVER_RESULTS")
	if plan.stockObserver {
		if err := checkedFile(observerPath, observerResultsSHA); err != nil {
			t.Fatal(err)
		}
	}
	image := os.Getenv("LABCONTAINERS_WINDOWS_IMAGE")
	imageInfo, err := exec.Command("docker", "image", "inspect", image).Output()
	if err != nil {
		t.Fatal(err)
	}
	imageID, err := matchedImage(imageInfo)
	if err != nil {
		t.Fatal(err)
	}
	peerID, err := exec.Command("docker", "image", "inspect", "alpine:3.20", "--format", "{{.Id}}").Output()
	if err != nil {
		t.Fatal(err)
	}
	labd := os.Getenv("LABCONTAINERS_LABD")
	buildInfo, err := exec.Command("go", "version", "-m", labd).CombinedOutput()
	if err != nil || !strings.Contains(string(buildInfo), "vcs.revision="+helperRevision) || !strings.Contains(string(buildInfo), "vcs.modified=false") {
		t.Fatalf("labd revision mismatch: %v\n%s", err, buildInfo)
	}
	parent := os.Getenv("RUNNER_TEMP")
	if !filepath.IsAbs(parent) {
		t.Fatal("RUNNER_TEMP must identify persistent artifact storage")
	}
	out, err := os.MkdirTemp(parent, "winfsp-native-")
	if err != nil {
		t.Fatal(err)
	}
	t.Log("retained results:", out)
	write := func(name string, b []byte) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(out, name), b, 0600); err != nil {
			t.Fatal(err)
		}
	}
	revision := os.Getenv("WINFSP_LAB_REVISION")
	if revision == "" {
		revision = "HEAD"
	}
	resolved, err := exec.Command("git", "rev-parse", "--verify", revision+"^{commit}").Output()
	if err != nil {
		t.Fatal(err)
	}
	revision = strings.TrimSpace(string(resolved))
	source, err := sourceArchive(revision)
	if err != nil {
		t.Fatal(err)
	}
	write("source.zip", source)
	write("image-inspect.json", imageInfo)
	if plan.buildOnly {
		cmd := exec.Command("git", "diff", "--quiet", observerCacheRevision, revision, "--",
			"src/dll", "inc", "ext", "tst/memfs",
			"build/VStudio/build.common.props",
			"build/VStudio/testing/winfsp-tests.vcxproj")
		if err := cmd.Run(); err != nil {
			t.Fatal("observer cache is incompatible with selected source revision:", err)
		}
	}
	msiEvidence, cacheEvidence := msiSHA, "not-staged"
	observerEvidence := "not-staged"
	if plan.buildOnly {
		msiEvidence, cacheEvidence = "not-staged", observerCacheSHA
	}
	if plan.stockObserver {
		observerEvidence = observerResultsSHA
	}
	write("provenance.txt", []byte(fmt.Sprintf("revision=%s\nsource_sha256=%x\newdk_sha256=%s\nmsi_sha256=%s\nimage=%s\nhelper_revision=%s\nbuild_only=%t\nstock_observer=%t\ncache_sha256=%s\nobserver_results_sha256=%s\n%s", revision, sha256.Sum256(source), ewdkSHA, msiEvidence, image, helperRevision, plan.buildOnly, plan.stockObserver, cacheEvidence, observerEvidence, buildInfo)))
	ctx, cancel := context.WithTimeout(context.Background(), 110*time.Minute)
	defer cancel()
	c, err := client.Launch(ctx, client.Options{LabdPath: labd})
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := c.Close(); err != nil {
			t.Error(err)
		}
	}()
	// Containerlab's local image lookup rejects bare Docker image IDs. Use
	// the existing reference but attest each created container's actual ID
	// before staging or executing anything inside the guest.
	topo, err := clab.Source(topology(image, iso))
	if err != nil {
		t.Fatal(err)
	}
	session, err := c.Start(ctx, &labv1.LabSpec{Topology: topo, Nodes: map[string]*labv1.NodeExtension{"vm": {Control: "qga"}}}, 115*time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	for name, expected := range map[string]string{"vm": imageID, "peer": strings.TrimSpace(string(peerID))} {
		actual, err := exec.Command("docker", "container", "inspect", "clab-"+session.Name()+"-"+name, "--format", "{{.Image}}").Output()
		if err != nil || strings.TrimSpace(string(actual)) != expected {
			t.Fatalf("runtime image mismatch for %s: %v %s", name, err, actual)
		}
		write("runtime-image-"+name+".txt", actual)
	}
	node := session.Node("vm")
	ready := func(afterReboot bool) {
		t.Helper()
		command := "Write-Output 'ready-" + filepath.Base(out) + "'"
		if afterReboot {
			command = `$ErrorActionPreference='Stop'; if((Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToFileTimeUtc() -le [long](Get-Content C:\lab\pre-reboot.txt)){throw 'reboot not observed'}; ` + command
		}
		_, err := session.RunTimeline(ctx, &labv1.TimelineAction{Action: &labv1.TimelineAction_WaitExec{WaitExec: &labv1.WaitExec{Exec: &labv1.ExecRequest{Node: node.Ref(), Argv: []string{powershell, "-NoProfile", "-Command", command}, TimeoutMillis: 30000}, TimeoutMillis: 600000, RetryMillis: 2000, StdoutContains: []byte("ready-" + filepath.Base(out))}}})
		if err != nil {
			t.Fatal(err)
		}
	}
	ready(false)
	defer func() {
		collectCtx, stop := context.WithTimeout(context.Background(), 8*time.Minute)
		defer stop()
		command := func(s string) ([]byte, error) {
			r, e := node.ExecWithTimeout(collectCtx, 2*time.Minute, powershell, "-NoProfile", "-Command", "$ErrorActionPreference='Stop'; "+s)
			if e != nil {
				return nil, e
			}
			if r.GetExitCode() != 0 {
				return nil, fmt.Errorf("collection exit %d: %s", r.GetExitCode(), r.GetStderr())
			}
			return r.GetStdout(), nil
		}
		size, e := command(`$paths=@(Get-ChildItem C:\lab -File | Where-Object Extension -in @('.txt','.log','.json') | ForEach-Object FullName); if(Test-Path C:\lab\output){$paths+='C:\lab\output'}; Compress-Archive -LiteralPath $paths -DestinationPath C:\lab\results.zip; (Get-Item C:\lab\results.zip).Length`)
		if e != nil {
			t.Error(e)
			return
		}
		length, e := strconv.Atoi(strings.TrimSpace(string(size)))
		if e != nil || length <= 0 {
			t.Errorf("invalid artifact size %q: %v", size, e)
			return
		}
		f, e := os.Create(filepath.Join(out, "results.zip"))
		if e != nil {
			t.Error(e)
			return
		}
		defer f.Close()
		for offset := 0; offset < length; offset += 262144 {
			b, e := command(fmt.Sprintf(`$f=[IO.File]::OpenRead('C:\lab\results.zip');try{$null=$f.Seek(%d,0);$b=New-Object byte[] 262144;$n=$f.Read($b,0,$b.Length);[Convert]::ToBase64String($b,0,$n)}finally{$f.Dispose()}`, offset))
			if e != nil {
				t.Error(e)
				return
			}
			decoded, e := base64.StdEncoding.DecodeString(strings.TrimSpace(string(b)))
			if e != nil {
				t.Error(e)
				return
			}
			if len(decoded) != min(262144, length-offset) {
				t.Error("short artifact read")
				return
			}
			if _, e = f.Write(decoded); e != nil {
				t.Error(e)
				return
			}
		}
	}()
	stage := func(name string, b []byte) {
		t.Helper()
		write("input-"+name, b)
		if err := node.Put(ctx, `C:\lab\`+name, 0600, b); err != nil {
			t.Fatal(err)
		}
	}
	stage("source.zip", source)
	if plan.buildOnly {
		b, err := os.ReadFile(cachePath)
		if err != nil {
			t.Fatal(err)
		}
		stage("cached-output.zip", b)
		b, err = os.ReadFile("build-test-only.ps1")
		if err != nil {
			t.Fatal(err)
		}
		stage("build-test-only.ps1", b)
	}
	if plan.stockObserver {
		b, err := os.ReadFile(observerPath)
		if err != nil {
			t.Fatal(err)
		}
		stage("observer-results.zip", b)
		for _, name := range []string{"stock-observer-install.ps1", "stock-observer-run.ps1", "process.ps1"} {
			b, err := os.ReadFile(name)
			if err != nil {
				t.Fatal(err)
			}
			stage(name, b)
		}
	}
	buildArgs := []string{"-Revision", revision}
	baseline := ""
	if !plan.buildOnly && !plan.stockObserver {
		baseline = os.Getenv("WINFSP_LAB_BASELINE_DRIVER")
		if baseline != "" && baseline != "1" {
			t.Fatal("WINFSP_LAB_BASELINE_DRIVER must be empty or 1")
		}
		if baseline == "1" {
			upstream, err := baselineRevision(os.Getenv("WINFSP_LAB_BASELINE_REVISION"))
			if err != nil {
				t.Fatal(err)
			}
			b, err := sourceArchive(upstream)
			if err != nil {
				t.Fatal(err)
			}
			stage("driver-source.zip", b)
			buildArgs = append(buildArgs, "-DriverRevision", upstream)
		}
		b, err := os.ReadFile(msi)
		if err != nil {
			t.Fatal(err)
		}
		stage("winfsp.msi", b)
		for _, name := range []string{"build.ps1", "install.ps1", "run.ps1", "evidence.ps1", "process.ps1", "attest-dll.inc"} {
			b, err := os.ReadFile(name)
			if err != nil {
				t.Fatal(err)
			}
			stage(name, b)
		}
	}
	if plan.stockObserver {
		b, err := os.ReadFile(msi)
		if err != nil {
			t.Fatal(err)
		}
		stage("winfsp.msi", b)
	}
	run := func(script, marker string, timeout time.Duration, args ...string) {
		t.Helper()
		argv := append([]string{powershell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", `C:\lab\` + script, "-Token", filepath.Base(out)}, args...)
		r, e := node.ExecWithTimeout(ctx, timeout, argv...)
		text := string(r.GetStdout()) + string(r.GetStderr())
		write(script+"-"+marker+"-command.txt", []byte(fmt.Sprintf("transport_error=%v\nexit=%d\n%s", e, r.GetExitCode(), text)))
		if e != nil || r.GetExitCode() != 0 || !strings.Contains(text, marker+":"+filepath.Base(out)) {
			t.Fatalf("%s failed: %v exit=%d\n%s", script, e, r.GetExitCode(), text)
		}
	}
	if plan.buildOnly {
		t.Log("building native observer only with attested compatible cache and offline EWDK")
		run("build-test-only.ps1", "BUILD_TEST_ONLY_COMPLETE", 15*time.Minute,
			"-Revision", revision)
		return
	}
	if plan.stockObserver {
		t.Log("installing exact stock signed MSI in isolated VM")
		run("stock-observer-install.ps1", "STOCK_OBSERVER_INSTALL_COMPLETE", 5*time.Minute)
		r, err := node.ExecWithTimeout(ctx, time.Minute, `C:\Windows\System32\shutdown.exe`, "/r", "/t", "5")
		if err != nil || r.GetExitCode() != 0 {
			t.Fatalf("schedule stock guest reboot: %v %s", err, r.GetStderr())
		}
		ready(true)
		t.Log("executing exact observer against stock signed driver")
		run("stock-observer-run.ps1", "STOCK_OBSERVER_RED_CONFIRMED", 5*time.Minute)
		return
	}
	t.Log("building exact source with offline EWDK")
	run("build.ps1", "BUILD_COMPLETE", 35*time.Minute, buildArgs...)
	t.Log("installing lab-signed candidate and rebooting isolated VM")
	run("install.ps1", "INSTALL_COMPLETE", 5*time.Minute)
	// Installation needs a clean Windows reboot, not runtime container restart:
	// the latter can cut power before NTFS flushes newly installed evidence.
	r, err := node.ExecWithTimeout(ctx, time.Minute, `C:\Windows\System32\shutdown.exe`, "/r", "/t", "5")
	if err != nil || r.GetExitCode() != 0 {
		t.Fatalf("schedule guest reboot: %v %s", err, r.GetStderr())
	}
	ready(true)
	suites := plan.suites
	if focus != "" {
		suites = []string{focus}
	} else if baseline == "1" {
		suites = []string{"regression"}
	} // An actual failing RED run, not a green exemption.
	for _, suite := range suites {
		t.Log("upstream suite:", suite)
		run("run.ps1", "SUITE_COMPLETE_"+suite, 20*time.Minute, "-Suite", suite)
	}
}

func TestNativeBuildOnlyPlanCannotInstallOrRun(t *testing.T) {
	p, err := nativePlan("1", "")
	if err != nil {
		t.Fatal(err)
	}
	if !p.buildOnly || p.install || p.reboot || 0 != len(p.suites) {
		t.Fatalf("unsafe build-only plan: %+v", p)
	}
	p, err = nativePlan("", "")
	if err != nil || p.buildOnly || !p.install || !p.reboot || 0 == len(p.suites) {
		t.Fatalf("invalid qualification plan: %+v %v", p, err)
	}
	if _, err = nativePlan("true", ""); err == nil {
		t.Fatal("accepted ambiguous build-only value")
	}
	p, err = nativePlan("", "1")
	if err != nil || p.buildOnly || !p.stockObserver || !p.install || !p.reboot || len(p.suites) != 0 {
		t.Fatalf("unsafe stock-observer plan: %+v %v", p, err)
	}
	if _, err = nativePlan("1", "1"); err == nil {
		t.Fatal("accepted conflicting isolated modes")
	}
}

func TestFocusedSuiteIsClosedSet(t *testing.T) {
	for _, good := range []string{"", "lock-noncached"} {
		if got, err := focusedSuite(good); err != nil || got != good {
			t.Fatalf("focused suite %q: %q %v", good, got, err)
		}
	}
	for _, bad := range []string{"full", "lock*", "lock_noncached_test"} {
		if _, err := focusedSuite(bad); err == nil {
			t.Fatalf("accepted arbitrary focused suite %q", bad)
		}
	}
}

func TestNativeBuildOnlyScriptExcludesDriverLifecycle(t *testing.T) {
	b, err := os.ReadFile("build-test-only.ps1")
	if err != nil {
		t.Fatal(err)
	}
	text := string(b)
	for _, required := range []string{"testing\\winfsp-tests.vcxproj", "driver_built=$false",
		"driver_installed=$false", observerCacheRevision} {
		if !strings.Contains(text, required) {
			t.Fatalf("build-only contract missing %q", required)
		}
	}
	for _, forbidden := range []string{"winfsp_sys.vcxproj", "winfsp_dll.vcxproj",
		"signtool.exe", "regsvr32.exe", "shutdown.exe", "run.ps1"} {
		if strings.Contains(text, forbidden) {
			t.Fatalf("build-only script contains lifecycle action %q", forbidden)
		}
	}
}

func TestStockObserverScriptsRequireSignedStockAndExactRed(t *testing.T) {
	install, err := os.ReadFile("stock-observer-install.ps1")
	if err != nil {
		t.Fatal(err)
	}
	run, err := os.ReadFile("stock-observer-run.ps1")
	if err != nil {
		t.Fatal(err)
	}
	combined := string(install) + string(run)
	for _, required := range []string{msiSHA, "Get-AuthenticodeSignature",
		"5c6d29955c4f86bcd0aacf7e31a0957f2b8054828ff02911875517111f9baf0e",
		"expected=[1-9][0-9]* observed=0 file_name=\\\\probe",
		"STOCK_OBSERVER_RED_CONFIRMED"} {
		if !strings.Contains(combined, required) {
			t.Fatalf("stock observer contract missing %q", required)
		}
	}
	for _, forbidden := range []string{"bcdedit.exe /set", "signtool.exe", "regsvr32.exe"} {
		if strings.Contains(combined, forbidden) {
			t.Fatalf("stock observer script mutates signed driver policy via %q", forbidden)
		}
	}
}

func baselineRevision(value string) (string, error) {
	if value == "" {
		return "ddca7bd5481857a65ba552f643b8776fd070836f", nil
	}
	if _, err := hex.DecodeString(value); err != nil || len(value) != 40 || strings.ToLower(value) != value {
		return "", fmt.Errorf("WINFSP_LAB_BASELINE_REVISION must be a full lowercase commit hash")
	}
	return value, nil
}

func TestBaselineRequiresExactRevision(t *testing.T) {
	if got, err := baselineRevision(""); err != nil || got != "ddca7bd5481857a65ba552f643b8776fd070836f" {
		t.Fatalf("default baseline: %q %v", got, err)
	}
	if got, err := baselineRevision(strings.Repeat("a", 40)); err != nil || got != strings.Repeat("a", 40) {
		t.Fatalf("explicit baseline: %q %v", got, err)
	}
	for _, bad := range []string{"HEAD", "deadbeef", strings.Repeat("z", 40), strings.Repeat("A", 40)} {
		if _, err := baselineRevision(bad); err == nil {
			t.Fatalf("accepted moving/malformed baseline %q", bad)
		}
	}
}

func matchedImage(data []byte) (string, error) {
	var images []struct {
		ID     string `json:"Id"`
		Config struct{ Labels map[string]string }
	}
	if err := json.Unmarshal(data, &images); err != nil {
		return "", err
	}
	if len(images) != 1 || len(images[0].ID) != 71 || !strings.HasPrefix(images[0].ID, "sha256:") || images[0].Config.Labels["appmana.labcontainers.revision"] != helperRevision || images[0].Config.Labels["appmana.labcontainers.guest-helper-sha256"] != helperSHA {
		return "", fmt.Errorf("image must contain the matched clean SDK guest helper")
	}
	return images[0].ID, nil
}

func TestImageRequiresMatchedHelper(t *testing.T) {
	good := fmt.Sprintf(`[{"Id":"sha256:%s","Config":{"Labels":{"appmana.labcontainers.revision":"%s","appmana.labcontainers.guest-helper-sha256":"%s"}}}]`, strings.Repeat("a", 64), helperRevision, helperSHA)
	if _, err := matchedImage([]byte(good)); err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{"[]", strings.ReplaceAll(good, helperRevision, "old"), strings.ReplaceAll(good, helperSHA, "old"), strings.ReplaceAll(good, "sha256:", "mutable:")} {
		if _, err := matchedImage([]byte(bad)); err == nil {
			t.Fatal("unmatched image accepted")
		}
	}
}

func sourceArchive(revision string) ([]byte, error) {
	// git archive is cwd-relative: the harness lives two levels below the
	// application root. Never accidentally compile a tools-only archive.
	return exec.Command("git", "-C", "../..", "archive", "--format=zip", revision).Output()
}

func TestSourceArchiveContainsCore(t *testing.T) {
	b, err := sourceArchive("HEAD")
	if err != nil {
		t.Fatal(err)
	}
	z, err := zip.NewReader(bytes.NewReader(b), int64(len(b)))
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"src/sys/fsctl.c", "src/dll/fuse/fuse_intf.c", "build/VStudio/winfsp_sys.vcxproj", "tst/winfsp-tests/winfsp-tests.c"} {
		f, err := z.Open(name)
		if err != nil {
			t.Fatal(name, err)
		}
		f.Close()
	}
}

func TestTopologyIsolation(t *testing.T) {
	c := topology("windows:pin", "/inputs/ewdk.iso")
	if len(c.Topology.Nodes) != 2 || len(c.Topology.Links) != 1 {
		t.Fatal("unexpected topology")
	}
	for _, n := range c.Topology.Nodes {
		if n.NetworkMode != "none" || len(n.Ports) != 0 {
			t.Fatal("management/port exposure")
		}
	}
}
