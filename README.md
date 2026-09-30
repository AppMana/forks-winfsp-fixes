<h1 align="center">WinFsp &middot; Windows File System Proxy</h1>

<p align="center">
    <img src="art/winfsp-glow.png" width="128"/>
    <br/>
    <br/>
    <i>WinFsp enables developers to write their own file systems (i.e. "Windows drives") as user mode programs and without any knowledge of Windows kernel programming. It is similar to FUSE (Filesystem in Userspace) for Linux and other UNIX-like computers.</i>
    <br/>
    <br/>
    <a href="https://winfsp.dev"><b>winfsp.dev</b></a>
    <br/>
    <br/>
    <a href="https://github.com/winfsp/winfsp/releases/latest"><img src="https://img.shields.io/github/release/winfsp/winfsp.svg?label=stable&style=for-the-badge&logo=data:image/svg%2bxml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA0ODAgNDgwIj48cGF0aCBkPSJNMzg3LjAwMiAyMDEuMDAxQzM3Mi45OTggMTMyLjAwMiAzMTIuOTk4IDgwIDI0MCA4MGMtNTcuOTk4IDAtMTA3Ljk5OCAzMi45OTgtMTMyLjk5OCA4MS4wMDFDNDcuMDAyIDE2Ny4wMDIgMCAyMTcuOTk4IDAgMjgwYzAgNjUuOTk2IDUzLjk5OSAxMjAgMTIwIDEyMGgyNjBjNTUgMCAxMDAtNDUgMTAwLTEwMCAwLTUyLjk5OC00MC45OTYtOTYuMDAxLTkyLjk5OC05OC45OTl6TTIwOCAyNTJ2LTc2aDY0djc2aDY4TDI0MCAzNTIgMTQwIDI1Mmg2OHoiIGZpbGw9IiNmZmYiLz48L3N2Zz4="/></a>
    <a href="https://github.com/winfsp/winfsp/releases"><img src="https://img.shields.io/github/release/winfsp/winfsp/all.svg?label=latest&colorB=e52e4b&style=for-the-badge&logo=data:image/svg%2bxml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA0ODAgNDgwIj48cGF0aCBkPSJNMzg3LjAwMiAyMDEuMDAxQzM3Mi45OTggMTMyLjAwMiAzMTIuOTk4IDgwIDI0MCA4MGMtNTcuOTk4IDAtMTA3Ljk5OCAzMi45OTgtMTMyLjk5OCA4MS4wMDFDNDcuMDAyIDE2Ny4wMDIgMCAyMTcuOTk4IDAgMjgwYzAgNjUuOTk2IDUzLjk5OSAxMjAgMTIwIDEyMGgyNjBjNTUgMCAxMDAtNDUgMTAwLTEwMCAwLTUyLjk5OC00MC45OTYtOTYuMDAxLTkyLjk5OC05OC45OTl6TTIwOCAyNTJ2LTc2aDY0djc2aDY4TDI0MCAzNTIgMTQwIDI1Mmg2OHoiIGZpbGw9IiNmZmYiLz48L3N2Zz4="/></a>
    <a href="https://chocolatey.org/packages/winfsp"><img src="https://img.shields.io/badge/choco-install%20winfsp-black.svg?style=for-the-badge"/></a>
    <br/>
    <br/>
    <img src="doc/cap.gif" width="75%" height="75%"/>
    <br/>
    <br/>
</p>

<hr/>

## AppMana qualification

`appmana-v2.1` is based on upstream commit
`ddca7bd5481857a65ba552f643b8776fd070836f`, matching the WinFsp 2.1 MSI
currently bundled by AppMana's SeaweedFS CSI. Fork artifacts are **lab-only**
until qualified and production-signed. The upstream installation instructions
below refer to upstream releases, not this fork's experimental driver.

Run the native Windows x64 suite in a fresh Labcontainers VM from a Linux/KVM
host with Docker and Go 1.26.3 or later:

```sh
export WINFSP_LAB_LIVE=1
export WINFSP_LAB_EWDK_ISO=/absolute/path/EWDK_ge_release_svc_prod1_26100_250904-1728.iso
export SEAWEEDFS_WINFSP_MSI=/absolute/path/winfsp-2.1.25156.msi
export LABCONTAINERS_LABD=/absolute/path/matched/labd
export LABCONTAINERS_WINDOWS_IMAGE=labcontainers/windows-server-2022:csi-1e16650
export RUNNER_TEMP=/absolute/path/persistent-results
cd tools/lab
GOWORK=off go test -v -count=1 -run '^TestNativeWindows$' -timeout=120m
```

To compile only the native observer/test executable in a fresh isolated VM,
without building, signing, installing or starting a driver and without running
any suite, add:

```sh
export WINFSP_LAB_BUILD_ONLY=1
export WINFSP_LAB_BUILD_CACHE=/absolute/path/winfsp-native-1425103029/results.zip
export WINFSP_LAB_REVISION=bddfe46d637facad01ac37ee49bc897f3afcf937
```

The cache ZIP is pinned to SHA-256
`3bbc30a59fb551e0caccc77344e92672096aaf7859bdc3dd94a505062615a9fe`.
The harness also proves that the selected revision has not changed the cached
DLL/header, Memfs/tlib or test-project inputs. Its retained build-only manifest
records the source, cache, EWDK, DLL, import-library and output executable
hashes. A successful build is not a native RED/GREEN result; execute the
binary against an explicitly attested driver in a separate qualification run.

To reproduce the network-filesystem projection failure against the exact stock
signed 2.1.25156 MSI in another fresh isolated VM, use the retained build-only
results archive and add:

```sh
export WINFSP_LAB_STOCK_OBSERVER=1
export WINFSP_LAB_OBSERVER_RESULTS=/absolute/path/winfsp-native-2168257981/results.zip
```

This mode rejects test-signing, installs only the pinned stock MSI, reboots,
attests the stock driver's path, Authenticode signer and hash, loads the
observer DLL only from its separate unregistered directory, inventories one
test, and succeeds only when that test produces the exact expected
target-classification RED. It never treats an ordinary test pass or a failure
before the observer callback as reproduction evidence.

The SDK, daemon and image guest helper must all match
`1e16650971a8d0307e465e75fdc047606165bbe7`; do not use the old alpha.2 daemon.
The EWDK and MSI hashes are enforced in `tools/lab/lab_test.go`. Build the
daemon from that clean SDK checkout with `go build -o /absolute/path/labd ./cmd/labd`.
The Windows image and `alpine:3.20` peer must already exist locally. Guests
have no management network, WAN, published ports or Internet dependency;
control is serial QGA. `WINFSP_LAB_REVISION` selects an exact source commit
(default `HEAD`); uncommitted application changes are never compiled.
Set `WINFSP_LAB_BASELINE_DRIVER=1` to compile the pinned unpatched upstream
driver with the current DLL/test executable and run only the new native
regression. That RED control is expected to fail; it is not a qualification
pass or a test exclusion. Leave the variable unset for candidate qualification.
`WINFSP_LAB_BASELINE_REVISION` optionally selects another locally available
full commit hash; its default is the v2.1 commit above, not a moving branch.
The manual workflow exposes `baseline_driver` and the repository variable
`WINFSP_LAB_BASELINE_REVISION` for the same deliberately failing control.

The harness builds the SYS, DLL and upstream test executable, test-signs the
driver in the disposable VM, explicitly registers it, reboots, verifies the
driver/DLL identities, and checks complete inventories for the selected x64
internal disk/network, directory and mount-manager modes. This is not the
entire upstream release matrix (x86/.NET, external/sample/compatibility and
additional option-injection modes remain separate qualifications). It retains
source, hashes, binaries, compiler logs and test failures beneath `RUNNER_TEMP`.
Native disk/network and directory-mount runs do not replace SeaweedFS Git/LFS,
mixed-OS, crash-recovery or actual CSI pod qualification. The local-directory
symlink fix does not change the network/UNC classifier, and exact mount-root
targets without a trailing separator remain unsupported.

The manual `native-lab` workflow uses repository variables
`WINFSP_LAB_RUNNER_LABELS` (JSON array of isolated Linux/KVM runner labels),
`WINFSP_LAB_EWDK_ISO`, `WINFSP_LAB_MSI`, `LABCONTAINERS_LABD`,
`LABCONTAINERS_WINDOWS_IMAGE`, and `WINFSP_LAB_RESULTS` (persistent host paths).
Missing configuration fails the workflow rather than reporting a skipped lab
as successful qualification.
No signing secrets, cluster credentials or production routes belong on that
runner. The workflow produces retained test artifacts, not releases or MSIs.

For CSI deployment, package matching production-signed SYS/DLL files through
the MSI build, pin its URL and SHA-256 in the mount image, and qualify host
installation and upgrade using the isolated Kubernetes/Labcontainers harness.
Do not drain production nodes to perform qualification. A DLL-only image update
cannot deploy this kernel fix. Never enable test signing on cluster nodes.

`tools/package/build-msi.ps1` assembles the complete upstream installer from
pinned source, payload and WiX archives. It requires `-LabOnly`, a fresh output
directory and a hash-pinned Windows MSBuild executable; its output is not a
production-signed release. The payload manifest must match the source revision,
source archive digest and package version. It includes native x86/x64/ARM64
drivers, DLLs, import libraries, launcher tools and Memfs, plus CustomActions
and the .NET bindings/sample. See `Assert-PackagePayload` in
`tools/package/inputs.ps1` for the enforced file inventory.

The existing native x64 VM build is not a complete MSI payload. In particular,
the pinned 26100 EWDK lacks x86 kernel libraries; it cannot alone build all
three driver architectures. The .NET projects also require a .NET SDK and
their target-framework reference assemblies (net35/netstandard2.0 and net452).
Stage and pin those build inputs before attempting complete offline assembly;
do not substitute stock binaries and label them as built from the patched
revision. Package-input contract tests validate rejection and archive handling,
not successful MSI assembly, installation or filesystem behavior.

The complete offline build has a separate opt-in entry point in the same native
Labcontainers harness. It does not reinstall drivers or repeat filesystem suites:

```sh
export WINFSP_PACKAGE_LIVE=1
export WINFSP_PACKAGE_EWDK_ISO=/absolute/cache/EWDK-19041-package.iso
export WINFSP_PACKAGE_EWDK_SHA256=1bd011404cc16c912463fa103cedc1793f9b55f9977ab355ce98ae89c075d841
export WINFSP_PACKAGE_INPUT_ROOT=/absolute/cache/inputs
# Use the matched LABCONTAINERS_LABD, LABCONTAINERS_WINDOWS_IMAGE and
# persistent RUNNER_TEMP variables from the native harness example above.
cd tools/lab
GOWORK=off go test -v -count=1 -run '^TestOfflinePackageBuild$' -timeout=85m
```

The input root contains `wix/wix314-binaries.zip` and, under `dotnet/`, the SDK
and three reference packages named and pinned in `tools/package/inputs.json`.
The SDK is Microsoft's Windows x64 .NET 8.0.425 archive; reference packages are
NuGet `Microsoft.NETFramework.ReferenceAssemblies`, `.net35` and `.net452`,
version 1.0.3. The MSI uses the upstream net35 binding; the separately shipped
netstandard NuGet package is not an MSI input. No online restore is permitted by
the VM topology. `build-payload.ps1` builds all native architectures, the managed
components and upstream installer, signing the drivers with a fresh **lab-only**
certificate. Outputs, logs, source archive and input identities are retained;
the owned VM is removed after artifact collection. Building an MSI does not
qualify its installation or make it production-signed.

`tools/package/fetch-ewdk.py --output /absolute/cache/EWDK-19041-package.iso
--sha256 1bd011404cc16c912463fa103cedc1793f9b55f9977ab355ce98ae89c075d841`
fetches the official 19041 EWDK with bounded parallel ranges. It refuses existing
output/partial files and validates the pinned digest before promotion. The pin
was recorded from an HTTPS acquisition of Microsoft's ISO, not a claimed
Microsoft-published checksum. A first-acquisition mode exists only to bootstrap
a newly reviewed pin; its manifest explicitly distinguishes observed hashes.

## Overview

WinFsp is a platform that provides development and runtime support for custom file systems on Windows computers. Typically any information or storage may be organized and presented as a file system via WinFsp, with the benefit being that the information can be accessed via the standand Windows file API’s by any Windows application.

The core WinFsp consists of a kernel mode file system driver (FSD) and a user mode DLL. The FSD interfaces with the Windows kernel and handles all interactions necessary to present itself as a file system driver. The DLL interfaces with the FSD and presents an API that can be used to handle file system functions. For example, when an application attempts to open a file, the file system receives an `Open` call with the necessary information.

Using WinFsp to build a file system has many benefits:

**Easy development**: Developing kernel mode file systems for Windows is a notoriously difficult task. WinFsp makes file system development relatively painless. This [Tutorial](doc/WinFsp-Tutorial.asciidoc) explains how to build a file system.

**Stability**: Stable software without any known kernel mode crashes, resource leaks or similar problems. WinFsp owes this stability to its [Design](doc/WinFsp-Design.asciidoc) and its rigorous [Testing Regime](doc/WinFsp-Testing.asciidoc).

**Correctness**: Strives for file system correctness and compatibility with NTFS. For details see the [Compatibility](doc/NTFS-Compatibility.asciidoc) document.

**Performance**: Has excellent performance that rivals or exceeds that of NTFS in many file system scenarios. Read more about its [Performance](doc/WinFsp-Performance-Testing.asciidoc).

<p align="center">
    <img src="doc/WinFsp-Performance-Testing/file_tests.png" height="300"/>
    <img src="doc/WinFsp-Performance-Testing/rdwr_tests.png" height="300"/>
</p>

**Wide support**: Supports Windows 7 to Windows 11 and the x86, x64 and ARM64 architectures.

**Flexible API**: Includes Native, FUSE2, FUSE3 and .NET API's.

**Shell integration**: Provides facilities to integrate user mode file systems with the Windows shell. See the [Service Architecture](doc/WinFsp-Service-Architecture.asciidoc) document.

**Self-contained**: Self-contained software without external dependencies.

**Widely used**: Used in many open-source and commercial applications with millions of installations (estimated: the WinFsp project does not track its users).

**Flexible licensing**: Available under the [GPLv3](License.txt) license with a special exception for Free/Libre and Open Source Software. A commercial license is also available. Please contact Bill Zissimopoulos \<billziss at navimatics.com> for more details.

## Installation

Download and run the [WinFsp installer](https://github.com/winfsp/winfsp/releases/latest). In the installer select the option to install the "Developer" files. These include the MEMFS sample file system, but also header and library files that let you develop your own user-mode file system.

<img src="doc/WinFsp-Tutorial/Installer.png" height="290"/>

### Launch a file system for testing

You can test WinFsp by launching MEMFS from the command line:

```
billziss@xps ⟩ ~ ⟩ net use X: \\memfs64\test
The command completed successfully.

billziss@xps ⟩ ~ ⟩ X:
billziss@xps ⟩ X:\ ⟩ echo "hello world" > hello.txt
billziss@xps ⟩ X:\ ⟩ dir


    Directory: X:\


Mode                 LastWriteTime         Length Name
----                 -------------         ------ ----
-a----         6/12/2022   5:15 PM             28 hello.txt


billziss@xps ⟩ X:\ ⟩ type hello.txt
hello world
billziss@xps ⟩ X:\ ⟩ cd ~
billziss@xps ⟩ ~ ⟩ net use X: /delete
X: was deleted successfully.
```

MEMFS (and all file systems that use the WinFsp Launcher as documented in the [Service Architecture](doc/WinFsp-Service-Architecture.asciidoc) document) can also be launched from Explorer using the "Map Network Drive" functionality.

## Resources

**Documentation**:

- [Tutorial](doc/WinFsp-Tutorial.asciidoc)

- [API Reference](doc/WinFsp-API-winfsp.h.md)

- [Building](doc/WinFsp-Building.asciidoc)

- [Project wiki](https://github.com/winfsp/winfsp/wiki)

**Discussion**:

- [WinFsp Google Group](https://groups.google.com/forum/#!forum/winfsp)

- [Author's Twitter](https://twitter.com/BZissimopoulos)
