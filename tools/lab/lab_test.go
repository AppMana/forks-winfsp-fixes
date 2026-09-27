package lab

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
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
const powershell = `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`

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
	iso, msi := os.Getenv("WINFSP_LAB_EWDK_ISO"), os.Getenv("SEAWEEDFS_WINFSP_MSI")
	for path, digest := range map[string]string{iso: ewdkSHA, msi: msiSHA} {
		if err := checkedFile(path, digest); err != nil {
			t.Fatal(err)
		}
	}
	image := os.Getenv("LABCONTAINERS_WINDOWS_IMAGE")
	if !strings.HasSuffix(image, "-"+helperRevision[:7]) {
		t.Fatal("Windows image must contain the matched 56e537c guest helper")
	}
	labd := os.Getenv("LABCONTAINERS_LABD")
	buildInfo, err := exec.Command("go", "version", "-m", labd).CombinedOutput()
	if err != nil || !strings.Contains(string(buildInfo), "vcs.revision="+helperRevision) {
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
	write("provenance.txt", []byte(fmt.Sprintf("revision=%s\nsource_sha256=%x\newdk_sha256=%s\nmsi_sha256=%s\nimage=%s\nhelper_revision=%s\n%s", revision, sha256.Sum256(source), ewdkSHA, msiSHA, image, helperRevision, buildInfo)))
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
	topo, err := clab.Source(topology(image, iso))
	if err != nil {
		t.Fatal(err)
	}
	session, err := c.Start(ctx, &labv1.LabSpec{Topology: topo, Nodes: map[string]*labv1.NodeExtension{"vm": {Control: "qga"}}}, 115*time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	node := session.Node("vm")
	ready := func() {
		t.Helper()
		_, err := session.RunTimeline(ctx, &labv1.TimelineAction{Action: &labv1.TimelineAction_WaitExec{WaitExec: &labv1.WaitExec{Exec: &labv1.ExecRequest{Node: node.Ref(), Argv: []string{powershell, "-NoProfile", "-Command", "Write-Output 'ready-" + filepath.Base(out) + "'"}, TimeoutMillis: 10000}, TimeoutMillis: 600000, RetryMillis: 2000, StdoutContains: []byte("ready-" + filepath.Base(out))}}})
		if err != nil {
			t.Fatal(err)
		}
	}
	ready()
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
	buildArgs := []string{"-Revision", revision}
	baseline := os.Getenv("WINFSP_LAB_BASELINE_DRIVER")
	if baseline != "" && baseline != "1" {
		t.Fatal("WINFSP_LAB_BASELINE_DRIVER must be empty or 1")
	}
	if baseline == "1" {
		const upstream = "ddca7bd5481857a65ba552f643b8776fd070836f"
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
	for _, name := range []string{"build.ps1", "install.ps1", "run.ps1", "evidence.ps1"} {
		b, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		stage(name, b)
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
	t.Log("building exact source with offline EWDK")
	run("build.ps1", "BUILD_COMPLETE", 35*time.Minute, buildArgs...)
	t.Log("installing lab-signed candidate and rebooting isolated VM")
	run("install.ps1", "INSTALL_COMPLETE", 5*time.Minute)
	if err := node.Restart(ctx); err != nil {
		t.Fatal(err)
	}
	ready()
	suites := []string{"regression", "full", "directory", "directory-sensitive", "mountmgr"}
	if baseline == "1" {
		suites = []string{"regression"}
	} // An actual failing RED run, not a green exemption.
	for _, suite := range suites {
		t.Log("upstream suite:", suite)
		run("run.ps1", "SUITE_COMPLETE_"+suite, 20*time.Minute, "-Suite", suite)
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
