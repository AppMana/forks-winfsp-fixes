# Deterministic API-level control for the rdwr-test.c:201 ETW observation.
# Uses a fresh file only; no retries, AV exclusions or driver changes.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Directory,
    [string]$MemfsExecutable,
    [string]$MemfsSHA256,
    [string]$MemfsDllSHA256
)
$ErrorActionPreference='Stop'
if([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18'){throw 'Native lab SYSTEM token required'}
if((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control').PSObject.Properties['ContainerType']){throw 'Native VM required'}
if(-not [IO.Path]::IsPathRooted($Directory) -or -not(Test-Path -LiteralPath $Directory -PathType Container)){throw 'Existing absolute lab directory required'}
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class DeletePendingControl {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr CreateFileW(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool CloseHandle(IntPtr handle);
    static readonly IntPtr Invalid = new IntPtr(-1);
    static IntPtr Open(string path, uint access, uint share, uint disposition, uint flags) {
        IntPtr h = CreateFileW(path, access, share, IntPtr.Zero, disposition, flags, IntPtr.Zero);
        if(h == Invalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        return h;
    }
    static int Probe(string path) {
        IntPtr h = CreateFileW(path, 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        int error = Marshal.GetLastWin32Error();
        if(h != Invalid) { CloseHandle(h); throw new Exception("Unexpectedly reopened deleted file"); }
        return error;
    }
    public static string Run(string path) {
        IntPtr owner = Invalid, observer = Invalid;
        try {
            // Same read/write sharing and delete-on-close policy as rdwr_dotest.
            owner = Open(path, 0xC0000000, 3, 1, 0x04000080);
            // Model the metadata observer seen in the ETW trace. Share delete,
            // but deliberately retain this handle until after the first probe.
            observer = Open(path, 0x80, 7, 3, 0);
            if(!CloseHandle(owner)) throw new Win32Exception(Marshal.GetLastWin32Error());
            owner = Invalid;
            int pending = Probe(path);
            if(pending != 5) throw new Exception("Expected ERROR_ACCESS_DENIED while observer remains: " + pending);
            if(!CloseHandle(observer)) throw new Win32Exception(Marshal.GetLastWin32Error());
            observer = Invalid;
            int gone = Probe(path);
            if(gone != 2) throw new Exception("Expected ERROR_FILE_NOT_FOUND after final close: " + gone);
            return "DELETE_PENDING_CONTROL_COMPLETE:held=5:released=2";
        } finally {
            if(owner != Invalid) CloseHandle(owner);
            if(observer != Invalid) CloseHandle(observer);
        }
    }
}
'@
$path=Join-Path $Directory ('delete-pending-'+[guid]::NewGuid().ToString()+'.bin')
Write-Output "CONTROL_PATH:$path"
[DeletePendingControl]::Run($path)
if($MemfsExecutable) {
    foreach($item in @(@($MemfsExecutable,$MemfsSHA256),@((Join-Path (Split-Path $MemfsExecutable) 'winfsp-x64.dll'),$MemfsDllSHA256))) {
        if($item[1] -cnotmatch '^[0-9a-f]{64}$' -or (Get-FileHash -LiteralPath $item[0]).Hash -ine $item[1]){throw 'Unpinned memfs control binary'}
    }
    if(Test-Path R:\){throw 'Diagnostic drive letter is already occupied'}
    $process=Start-Process $MemfsExecutable -ArgumentList '-u','\rdwr-control\share','-m','R:' -PassThru
    try {
        $deadline=[DateTime]::UtcNow.AddSeconds(20)
        while(-not(Test-Path R:\)) {
            if($process.HasExited -or [DateTime]::UtcNow -gt $deadline){throw 'Pinned memfs control did not start'}
            Start-Sleep -Milliseconds 100
        }
        $path='R:\delete-pending-'+[guid]::NewGuid().ToString()+'.bin'
        Write-Output "CONTROL_PATH:$path"
        [DeletePendingControl]::Run($path)
    } finally {
        if(-not $process.HasExited){Stop-Process -Id $process.Id -Force}
        $process.Dispose()
    }
}
