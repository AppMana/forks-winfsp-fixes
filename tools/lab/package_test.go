package lab

import (
	"archive/zip"
	"context"
	"crypto/sha256"
	"encoding/base64"
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
)

func packageChunk(ctx context.Context, size int, read func() ([]byte, error)) ([]byte, error) {
	var last error
	for attempt := 0; attempt < 3; attempt++ {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		b, err := read()
		if err == nil && len(b) == size {
			return b, nil
		}
		last = err
		if last == nil {
			last = fmt.Errorf("artifact chunk length %d, expected %d", len(b), size)
		}
	}
	return nil, last
}

func TestPackageChunkRetriesWithoutAcceptingPartialOutput(t *testing.T) {
	calls := 0
	b, err := packageChunk(context.Background(), 3, func() ([]byte, error) {
		calls++
		if calls == 1 {
			return nil, context.DeadlineExceeded
		}
		if calls == 2 {
			return []byte("ab"), nil
		}
		return []byte("abc"), nil
	})
	if err != nil || string(b) != "abc" || calls != 3 {
		t.Fatalf("%q %v calls=%d", b, err, calls)
	}
	calls = 0
	_, err = packageChunk(context.Background(), 3, func() ([]byte, error) { calls++; return []byte("ab"), nil })
	if err == nil || calls != 3 {
		t.Fatal("unbounded or accepted partial chunk", err, calls)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err = packageChunk(ctx, 3, func() ([]byte, error) { t.Fatal("read after cancellation"); return nil, nil })
	if err != context.Canceled {
		t.Fatal(err)
	}
}

// This builds a lab-only installer. It neither installs it nor qualifies it.
func checkPackagingOnlyChanges(diff string) error {
	for _, path := range strings.Split(strings.TrimSpace(diff), "\n") {
		if path == "" || path == "README.md" || path == "build/VStudio/installer/Product.wxs" ||
			strings.HasPrefix(path, "tools/lab/") || strings.HasPrefix(path, "tools/package/") || strings.HasPrefix(path, ".github/") {
			continue
		}
		return fmt.Errorf("retained payload cannot be reused after source change: %s", path)
	}
	return nil
}

func TestRetainedPayloadRejectsNativeSourceChanges(t *testing.T) {
	if err := checkPackagingOnlyChanges("build/VStudio/installer/Product.wxs\ntools/package/build-msi.ps1\nREADME.md\n"); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"src/sys/fsctl.c", "src/dll/fs.c", "inc/winfsp/winfsp.h", "build/VStudio/build.version.props", "build/VStudio/installer/CustomActions/CustomActions.cpp", "tst/winfsp-tests/reparse.c", "opt/fsext/lib/winfsp-x64.lib"} {
		if checkPackagingOnlyChanges(path) == nil {
			t.Fatal("accepted stale binaries after", path)
		}
	}
}

func TestOfflinePackageBuild(t *testing.T) {
	if os.Getenv("WINFSP_PACKAGE_LIVE") != "1" {
		t.Skip("set WINFSP_PACKAGE_LIVE=1")
	}
	qualify := os.Getenv("WINFSP_PACKAGE_QUALIFY")
	if qualify != "" && qualify != "1" {
		t.Fatal("WINFSP_PACKAGE_QUALIFY must be empty or 1")
	}
	existing := os.Getenv("WINFSP_PACKAGE_EXISTING_RESULTS")
	existingSHA := os.Getenv("WINFSP_PACKAGE_EXISTING_RESULTS_SHA256")
	focused := os.Getenv("WINFSP_PACKAGE_RDWR_ONLY")
	if focused != "" && (focused != "1" || existing == "" || qualify != "1") {
		t.Fatal("WINFSP_PACKAGE_RDWR_ONLY=1 requires a pinned existing package and qualification")
	}
	if existing != "" || existingSHA != "" {
		if err := checkedFile(existing, existingSHA); err != nil {
			t.Fatal(err)
		}
		if qualify != "1" || os.Getenv("WINFSP_PACKAGE_RETAINED_PAYLOAD") != "" {
			t.Fatal("existing package requires qualification and cannot be combined with payload rebuilding")
		}
	}
	architectures := os.Getenv("WINFSP_PACKAGE_NATIVE_ARCHITECTURES")
	if architectures == "" {
		architectures = "both"
	}
	if architectures != "both" && architectures != "x64" && architectures != "x86" {
		t.Fatal("invalid native architecture selection")
	}
	repeats := 0
	if value := os.Getenv("WINFSP_PACKAGE_RDWR_REPEATS"); value != "" {
		var err error
		repeats, err = strconv.Atoi(value)
		if err != nil || repeats < 0 || repeats > 100 {
			t.Fatal("rdwr repetitions must be 0..100")
		}
	}
	if focused == "1" && repeats == 0 {
		t.Fatal("focused diagnostic requires at least one repetition")
	}
	iso := os.Getenv("WINFSP_PACKAGE_EWDK_ISO")
	if existing == "" {
		if err := checkedFile(iso, os.Getenv("WINFSP_PACKAGE_EWDK_SHA256")); err != nil {
			t.Fatal(err)
		}
	}
	image := os.Getenv("LABCONTAINERS_WINDOWS_IMAGE")
	info, err := exec.Command("docker", "image", "inspect", image).Output()
	if err != nil {
		t.Fatal(err)
	}
	imageID, err := matchedImage(info)
	if err != nil {
		t.Fatal(err)
	}
	labd := os.Getenv("LABCONTAINERS_LABD")
	buildInfo, err := exec.Command("go", "version", "-m", labd).CombinedOutput()
	if err != nil || !strings.Contains(string(buildInfo), "vcs.revision="+helperRevision) || !strings.Contains(string(buildInfo), "vcs.modified=false") {
		t.Fatal("unmatched daemon", err)
	}
	parent := os.Getenv("RUNNER_TEMP")
	if !filepath.IsAbs(parent) {
		t.Fatal("persistent RUNNER_TEMP required")
	}
	out, err := os.MkdirTemp(parent, "winfsp-package-")
	if err != nil {
		t.Fatal(err)
	}
	t.Log("retained results:", out)
	write := func(name string, data []byte) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(out, name), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	pins, err := os.ReadFile("../package/inputs.json")
	if err != nil {
		t.Fatal(err)
	}
	var inputs struct {
		Files map[string]string `json:"files"`
	}
	if err := json.Unmarshal(pins, &inputs); err != nil {
		t.Fatal(err)
	}
	write("inputs.json", pins)
	media := filepath.Join(out, "inputs.iso")
	args := []string{"-quiet", "-J", "-r", "-V", "PKGINPUTS", "-o", media, "-graft-points", "inputs.json=" + filepath.Join(out, "inputs.json")}
	if existing != "" {
		args = append(args, "existing-results.zip="+existing)
		write("existing-package.txt", []byte(existing+"\nsha256="+existingSHA+"\n"))
	}
	for name, digest := range inputs.Files {
		if existing != "" {
			break // exact-package replay needs no compiler, WiX or .NET cache
		}
		folder := "dotnet"
		if strings.HasPrefix(name, "wix") {
			folder = "wix"
		}
		path := filepath.Join(os.Getenv("WINFSP_PACKAGE_INPUT_ROOT"), folder, name)
		if err := checkedFile(path, digest); err != nil {
			t.Fatal(err)
		}
		args = append(args, name+"="+path)
	}
	sourceRef := os.Getenv("WINFSP_PACKAGE_REVISION")
	if sourceRef == "" {
		sourceRef = "HEAD"
	}
	revisionBytes, err := exec.Command("git", "rev-parse", "--verify", sourceRef+"^{commit}").Output()
	if err != nil {
		t.Fatal(err)
	}
	revision := strings.TrimSpace(string(revisionBytes))
	source, err := sourceArchive(revision)
	if err != nil {
		t.Fatal(err)
	}
	write("source.zip", source)
	payloadRevision := revision
	payloadSource := source
	if ref := os.Getenv("WINFSP_PACKAGE_PAYLOAD_REVISION"); ref != "" {
		if os.Getenv("WINFSP_PACKAGE_RETAINED_PAYLOAD") == "" {
			t.Fatal("payload revision override requires retained payload")
		}
		b, err := exec.Command("git", "rev-parse", "--verify", ref+"^{commit}").Output()
		if err != nil {
			t.Fatal(err)
		}
		payloadRevision = strings.TrimSpace(string(b))
		diff, err := exec.Command("git", "diff", "--name-only", payloadRevision, revision, "--").Output()
		if err != nil {
			t.Fatal(err)
		}
		if err := checkPackagingOnlyChanges(string(diff)); err != nil {
			t.Fatal(err)
		}
		payloadSource, err = sourceArchive(payloadRevision)
		if err != nil {
			t.Fatal(err)
		}
		write("payload-source-compatibility.txt", []byte(fmt.Sprintf("payload_revision=%s\npayload_source_sha256=%x\npackaging_revision=%s\nchanged_paths:\n%s", payloadRevision, sha256.Sum256(payloadSource), revision, diff)))
	}
	args = append(args, "source.zip="+filepath.Join(out, "source.zip"))
	retainedSHA := os.Getenv("WINFSP_PACKAGE_RETAINED_SHA256")
	retained := os.Getenv("WINFSP_PACKAGE_RETAINED_PAYLOAD")
	if retained != "" || retainedSHA != "" {
		if os.Getenv("WINFSP_PACKAGE_REVISION") == "" {
			t.Fatal("retained payload requires its explicit WINFSP_PACKAGE_REVISION")
		}
		if err := checkedFile(retained, retainedSHA); err != nil {
			t.Fatal(err)
		}
		args = append(args, "retained-payload.zip="+retained)
		write("retained-payload.txt", []byte(retained+"\nsha256="+retainedSHA+"\n"))
	}
	if qualify == "1" {
		stock := os.Getenv("SEAWEEDFS_WINFSP_MSI")
		if err := checkedFile(stock, msiSHA); err != nil {
			t.Fatal(err)
		}
		args = append(args, "stock.msi="+stock)
		if retained != "" || existing != "" {
			cert := os.Getenv("WINFSP_PACKAGE_CERTIFICATE")
			if err := checkedFile(cert, os.Getenv("WINFSP_PACKAGE_CERTIFICATE_SHA256")); err != nil {
				t.Fatal(err)
			}
			args = append(args, "lab.cer="+cert)
		}
	}
	for _, name := range []string{"build-payload.ps1", "build-msi.ps1", "inputs.ps1", "build-clock.ps1", "qualify-msi.ps1", "evidence.ps1", "process.ps1", "delete-pending-repro.ps1"} {
		path := filepath.Join("../package", name)
		if name == "build-clock.ps1" || name == "evidence.ps1" || name == "process.ps1" || name == "delete-pending-repro.ps1" {
			path = name
		}
		b, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		write("input-"+name, b)
		args = append(args, name+"="+filepath.Join(out, "input-"+name))
	}
	if b, err := exec.Command("genisoimage", args...).CombinedOutput(); err != nil {
		t.Fatalf("media: %v %s", err, b)
	}
	write("image.json", info)
	write("daemon.txt", buildInfo)
	write("provenance.txt", []byte(fmt.Sprintf("source_revision=%s\nsource_sha256=%x\newdk_sha256=%s\n", revision, sha256.Sum256(source), os.Getenv("WINFSP_PACKAGE_EWDK_SHA256"))))
	ctx, cancel := context.WithTimeout(context.Background(), 75*time.Minute)
	defer cancel()
	c, err := client.Launch(ctx, client.Options{LabdPath: labd, StateDir: filepath.Join(out, "state")})
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := c.Close(); err != nil {
			t.Error(err)
		}
	}()
	topo := topology(image, iso)
	if existing != "" {
		topo = topology(image, media)
	} else {
		topo.Topology.Nodes["vm"].Binds = append(topo.Topology.Nodes["vm"].Binds, media+":/package-inputs.iso:ro")
		topo.Topology.Nodes["vm"].Env["QEMU_ADDITIONAL_ARGS"] += " -drive file=/package-inputs.iso,media=cdrom,readonly=on"
	}
	topologySource, err := clab.Source(topo)
	if err != nil {
		t.Fatal(err)
	}
	session, err := c.Start(ctx, &labv1.LabSpec{Topology: topologySource, Nodes: map[string]*labv1.NodeExtension{"vm": {Control: "qga"}}}, 80*time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	actual, err := exec.Command("docker", "inspect", "clab-"+session.Name()+"-vm", "--format", "{{.Image}}").Output()
	if err != nil || strings.TrimSpace(string(actual)) != imageID {
		t.Fatal("runtime image mismatch", err)
	}
	node := session.Node("vm")
	_, err = session.RunTimeline(ctx, &labv1.TimelineAction{Action: &labv1.TimelineAction_WaitExec{WaitExec: &labv1.WaitExec{Exec: &labv1.ExecRequest{Node: node.Ref(), Argv: []string{powershell, "-NoProfile", "-Command", "Write-Output 'PACKAGE_READY'"}, TimeoutMillis: 30000}, TimeoutMillis: 600000, RetryMillis: 2000, StdoutContains: []byte("PACKAGE_READY")}}})
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		collect, stop := context.WithTimeout(context.Background(), 10*time.Minute)
		defer stop()
		// Collect small diagnostic evidence first. A later payload transfer
		// failure must not strand all completed test logs inside a torn ZIP.
		archives := []string{"evidence", "results"}
		if existing != "" {
			// The original MSI/payload ZIP is already pinned on the host. Do not
			// transfer those unchanged bytes back through serial control again.
			archives = []string{"evidence"}
		}
		for _, archive := range archives {
			guest := `C:\lab\package-` + archive + ".zip"
			selection := `@(Get-ChildItem C:\lab\output -File | Where-Object {$_.Extension -notin @('.zip','.msi')} | ForEach-Object FullName)`
			if archive == "results" {
				selection = `@(Get-ChildItem C:\lab\output -File | ForEach-Object FullName)`
			}
			r, e := node.ExecWithTimeout(collect, 2*time.Minute, powershell, "-NoProfile", "-Command", fmt.Sprintf(`$ErrorActionPreference='Stop'; Compress-Archive -LiteralPath %s -DestinationPath '%s'; (Get-Item '%s').Length`, selection, guest, guest))
			if e != nil || r.GetExitCode() != 0 {
				t.Errorf("collect package results: %v %s", e, r.GetStderr())
				return
			}
			length, e := strconv.Atoi(strings.TrimSpace(string(r.GetStdout())))
			if e != nil || length <= 0 {
				t.Error("invalid result size", e)
				return
			}
			partial := filepath.Join(out, archive+".zip.partial")
			f, e := os.Create(partial)
			if e != nil {
				t.Error(e)
				return
			}
			defer f.Close()
			for offset := 0; offset < length; offset += 262144 {
				command := fmt.Sprintf(`$f=[IO.File]::OpenRead('%s');try{$null=$f.Seek(%d,0);$b=New-Object byte[] 262144;$n=$f.Read($b,0,$b.Length);[Convert]::ToBase64String($b,0,$n)}finally{$f.Dispose()}`, guest, offset)
				b, e := packageChunk(collect, min(262144, length-offset), func() ([]byte, error) {
					r, e := node.ExecWithTimeout(collect, time.Minute, powershell, "-NoProfile", "-Command", command)
					if e != nil {
						return nil, e
					}
					if r.GetExitCode() != 0 {
						return nil, fmt.Errorf("artifact read exit=%d: %s", r.GetExitCode(), r.GetStderr())
					}
					return base64.StdEncoding.DecodeString(strings.TrimSpace(string(r.GetStdout())))
				})
				if e != nil {
					t.Error("artifact read", archive, offset, e)
					return
				}
				if _, e = f.Write(b); e != nil {
					t.Error(e)
					return
				}
			}
			if e = f.Close(); e != nil {
				t.Error(e)
				return
			}
			z, e := zip.OpenReader(partial)
			if e != nil {
				t.Error("artifact ZIP structure", e)
				return
			}
			for _, entry := range z.File {
				r, err := entry.Open()
				if err == nil {
					_, err = io.Copy(io.Discard, r)
					r.Close()
				}
				if err != nil {
					z.Close()
					t.Error("artifact ZIP CRC", entry.Name, err)
					return
				}
			}
			z.Close()
			if e = os.Rename(partial, filepath.Join(out, archive+".zip")); e != nil {
				t.Error(e)
				return
			}
		}
	}()
	command := fmt.Sprintf(`$ErrorActionPreference='Stop';Set-TimeZone -Id UTC;Set-Date -Date ([DateTimeOffset]::Parse('%s').UtcDateTime);$disc=@(Get-Volume | Where-Object FileSystemLabel -eq PKGINPUTS);if($disc.Count -ne 1){throw 'package input disc missing'};$inputRoot=$disc[0].DriveLetter+':\';New-Item C:\lab -ItemType Directory -Force | Out-Null;Copy-Item -LiteralPath ($inputRoot+'source.zip') -Destination C:\lab\source.zip;& ($inputRoot+'build-payload.ps1') -Revision %s -SourceSha256 %x -InputsDirectory $inputRoot -HostUtc '%s' -Token '%s'`, time.Now().UTC().Format(time.RFC3339), revision, sha256.Sum256(source), time.Now().UTC().Format(time.RFC3339), filepath.Base(out))
	if existing != "" {
		command = fmt.Sprintf(`$ErrorActionPreference='Stop';Set-TimeZone -Id UTC;Set-Date -Date ([DateTimeOffset]::Parse('%s').UtcDateTime);$disc=@(Get-Volume | Where-Object FileSystemLabel -eq PKGINPUTS);if($disc.Count -ne 1){throw 'package input disc missing'};$inputRoot=$disc[0].DriveLetter+':\';. ($inputRoot+'inputs.ps1');Import-QualifiedPackage ($inputRoot+'existing-results.zip') '%s' C:\lab;Write-Output 'PACKAGE_BUILD_COMPLETE:%s'`, time.Now().UTC().Format(time.RFC3339), existingSHA, filepath.Base(out))
		t.Log("importing exact existing MSI and test binaries; no build or signing")
	} else if retained != "" {
		command = strings.Replace(command, ";& ($inputRoot+", ";Copy-Item -LiteralPath ($inputRoot+'retained-payload.zip') -Destination C:\\lab\\retained-payload.zip;& ($inputRoot+", 1)
		command += " -RetainedPayloadSha256 " + retainedSHA
		command += fmt.Sprintf(" -PayloadRevision %s -PayloadSourceSha256 %x", payloadRevision, sha256.Sum256(payloadSource))
		t.Log("assembling installer from retained payload; no compilation or signing")
	} else {
		t.Log("building complete native and managed package payload offline")
	}
	r, err := node.ExecWithTimeout(ctx, 60*time.Minute, powershell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command)
	text := string(r.GetStdout()) + string(r.GetStderr())
	write("build-command.txt", []byte(fmt.Sprintf("error=%v\nexit=%d\n%s", err, r.GetExitCode(), text)))
	if err != nil || r.GetExitCode() != 0 || !strings.Contains(text, "PACKAGE_BUILD_COMPLETE:"+filepath.Base(out)) {
		t.Fatalf("package build failed: %v exit=%d\n%s", err, r.GetExitCode(), text)
	}
	if qualify == "1" {
		for _, phase := range []string{"install", "run"} {
			t.Log("qualifying actual MSI:", phase)
			command := fmt.Sprintf(`$ErrorActionPreference='Stop';$disc=@(Get-Volume | Where-Object FileSystemLabel -eq PKGINPUTS);if($disc.Count -ne 1){throw 'package input disc missing'};$inputRoot=$disc[0].DriveLetter+':\';& ($inputRoot+'qualify-msi.ps1') -Phase %s -Token %s -InputsDirectory $inputRoot`, phase, filepath.Base(out))
			command += fmt.Sprintf(" -Architectures %s -RdwrRepeats %d", architectures, repeats)
			if focused == "1" {
				command += " -RdwrOnly"
			}
			r, e := node.ExecWithTimeout(ctx, 40*time.Minute, powershell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command)
			result := string(r.GetStdout()) + string(r.GetStderr())
			write("qualification-"+phase+"-command.txt", []byte(fmt.Sprintf("error=%v\nexit=%d\n%s", e, r.GetExitCode(), result)))
			marker := "PACKAGE_QUALIFICATION_" + phase + ":" + filepath.Base(out)
			if focused == "1" && phase == "run" {
				marker = "PACKAGE_RDWR_DIAGNOSTIC_COMPLETE:" + filepath.Base(out)
			}
			if e != nil || r.GetExitCode() != 0 || !strings.Contains(result, marker) {
				t.Fatalf("MSI %s qualification failed: %v exit=%d\n%s", phase, e, r.GetExitCode(), result)
			}
			if phase == "install" {
				r, e := node.ExecWithTimeout(ctx, time.Minute, `C:\Windows\System32\shutdown.exe`, "/r", "/t", "5")
				if e != nil || r.GetExitCode() != 0 {
					t.Fatal("schedule MSI guest reboot", e)
				}
				ready := `$ErrorActionPreference='Stop';if((Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToFileTimeUtc() -le [long](Get-Content C:\lab\pre-reboot.txt)){throw 'reboot not observed'};'MSI_REBOOT_READY'`
				_, e = session.RunTimeline(ctx, &labv1.TimelineAction{Action: &labv1.TimelineAction_WaitExec{WaitExec: &labv1.WaitExec{Exec: &labv1.ExecRequest{Node: node.Ref(), Argv: []string{powershell, "-NoProfile", "-Command", ready}, TimeoutMillis: 30000}, TimeoutMillis: 600000, RetryMillis: 2000, StdoutContains: []byte("MSI_REBOOT_READY")}}})
				if e != nil {
					t.Fatal(e)
				}
			}
		}
	}
}
