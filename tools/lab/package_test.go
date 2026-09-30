package lab

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
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

// This builds a lab-only installer. It neither installs it nor qualifies it.
func TestOfflinePackageBuild(t *testing.T) {
	if os.Getenv("WINFSP_PACKAGE_LIVE") != "1" {
		t.Skip("set WINFSP_PACKAGE_LIVE=1")
	}
	iso := os.Getenv("WINFSP_PACKAGE_EWDK_ISO")
	if err := checkedFile(iso, os.Getenv("WINFSP_PACKAGE_EWDK_SHA256")); err != nil {
		t.Fatal(err)
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
	for name, digest := range inputs.Files {
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
	if b, err := exec.Command("genisoimage", args...).CombinedOutput(); err != nil {
		t.Fatalf("media: %v %s", err, b)
	}
	revisionBytes, err := exec.Command("git", "rev-parse", "HEAD").Output()
	if err != nil {
		t.Fatal(err)
	}
	revision := strings.TrimSpace(string(revisionBytes))
	source, err := sourceArchive(revision)
	if err != nil {
		t.Fatal(err)
	}
	write("source.zip", source)
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
	topo.Topology.Nodes["vm"].Binds = append(topo.Topology.Nodes["vm"].Binds, media+":/package-inputs.iso:ro")
	topo.Topology.Nodes["vm"].Env["QEMU_ADDITIONAL_ARGS"] += " -drive file=/package-inputs.iso,media=cdrom,readonly=on"
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
		r, e := node.ExecWithTimeout(collect, 2*time.Minute, powershell, "-NoProfile", "-Command", `$ErrorActionPreference='Stop'; Compress-Archive -Path C:\lab\output\* -DestinationPath C:\lab\package-results.zip; (Get-Item C:\lab\package-results.zip).Length`)
		if e != nil || r.GetExitCode() != 0 {
			t.Errorf("collect package results: %v %s", e, r.GetStderr())
			return
		}
		length, e := strconv.Atoi(strings.TrimSpace(string(r.GetStdout())))
		if e != nil || length <= 0 {
			t.Error("invalid result size", e)
			return
		}
		f, e := os.Create(filepath.Join(out, "results.zip"))
		if e != nil {
			t.Error(e)
			return
		}
		defer f.Close()
		for offset := 0; offset < length; offset += 262144 {
			command := fmt.Sprintf(`$f=[IO.File]::OpenRead('C:\lab\package-results.zip');try{$null=$f.Seek(%d,0);$b=New-Object byte[] 262144;$n=$f.Read($b,0,$b.Length);[Convert]::ToBase64String($b,0,$n)}finally{$f.Dispose()}`, offset)
			r, e := node.ExecWithTimeout(collect, time.Minute, powershell, "-NoProfile", "-Command", command)
			if e != nil || r.GetExitCode() != 0 {
				t.Error("artifact read", e)
				return
			}
			b, e := base64.StdEncoding.DecodeString(strings.TrimSpace(string(r.GetStdout())))
			if e != nil || len(b) != min(262144, length-offset) {
				t.Error("artifact length", e)
				return
			}
			if _, e = f.Write(b); e != nil {
				t.Error(e)
				return
			}
		}
	}()
	if err := node.Put(ctx, `C:\lab\source.zip`, 0600, source); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"build-payload.ps1", "build-msi.ps1", "inputs.ps1", "build-clock.ps1"} {
		path := filepath.Join("../package", name)
		if name == "build-clock.ps1" {
			path = name
		}
		b, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		write("input-"+name, b)
		if err := node.Put(ctx, `C:\lab\`+name, 0600, b); err != nil {
			t.Fatal(err)
		}
	}
	command := fmt.Sprintf(`$ErrorActionPreference='Stop';Set-TimeZone -Id UTC;Set-Date -Date ([DateTimeOffset]::Parse('%s').UtcDateTime);$disc=@(Get-Volume | Where-Object FileSystemLabel -eq PKGINPUTS);if($disc.Count -ne 1){throw 'package input disc missing'};& C:\lab\build-payload.ps1 -Revision %s -SourceSha256 %x -InputsDirectory ($disc[0].DriveLetter+':\') -HostUtc '%s' -Token '%s'`, time.Now().UTC().Format(time.RFC3339), revision, sha256.Sum256(source), time.Now().UTC().Format(time.RFC3339), filepath.Base(out))
	t.Log("building complete native and managed package payload offline")
	r, err := node.ExecWithTimeout(ctx, 60*time.Minute, powershell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command)
	text := string(r.GetStdout()) + string(r.GetStderr())
	write("build-command.txt", []byte(fmt.Sprintf("error=%v\nexit=%d\n%s", err, r.GetExitCode(), text)))
	if err != nil || r.GetExitCode() != 0 || !strings.Contains(text, "PACKAGE_BUILD_COMPLETE:"+filepath.Base(out)) {
		t.Fatalf("package build failed: %v exit=%d\n%s", err, r.GetExitCode(), text)
	}
}
