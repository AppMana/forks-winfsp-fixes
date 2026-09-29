# Lab-only re-signing of an immutable build; never changes an installed driver.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ManifestSHA256,
    [Parameter(Mandatory)][DateTimeOffset]$HostUtc
)
$ErrorActionPreference = 'Stop'
if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18') { throw 'isolated lab SYSTEM token required' }
if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control').PSObject.Properties['ContainerType']) { throw 'native lab VM required' }
if ([Math]::Abs(([DateTimeOffset]::UtcNow - $HostUtc).TotalSeconds) -gt 120) { throw 'host/guest clock discrepancy or stale signing request' }
if (Test-Path -LiteralPath $OutputDirectory) { throw 'output must be a new directory' }
$manifestPath = Join-Path $InputDirectory 'manifest.json'
if ((Get-FileHash -Algorithm SHA256 $manifestPath).Hash -ine $ManifestSHA256) { throw 'input manifest digest mismatch' }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.lab_only -ne $true) { throw 'only lab-only artifacts may be re-signed' }
foreach ($item in @(@('winfsp-x64.sys','driver_sha256'), @('winfsp-x64.dll','dll_sha256'))) {
    if ((Get-FileHash -Algorithm SHA256 (Join-Path $InputDirectory $item[0])).Hash -ine $manifest.($item[1])) { throw "input digest mismatch: $($item[0])" }
}
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$driver = Join-Path $OutputDirectory 'winfsp-x64.sys'
Copy-Item -LiteralPath (Join-Path $InputDirectory 'winfsp-x64.sys') -Destination $driver
Copy-Item -LiteralPath (Join-Path $InputDirectory 'winfsp-x64.dll') -Destination $OutputDirectory
$now = [DateTime]::UtcNow
$cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=AppMana WinFsp LAB ONLY' -CertStoreLocation Cert:\LocalMachine\My -NotBefore $now.AddMinutes(-1) -NotAfter $now.AddYears(1)
$certificatePath = Join-Path $OutputDirectory 'lab.cer'
Export-Certificate -Cert $cert -FilePath $certificatePath | Out-Null
foreach ($store in @('Root','TrustedPublisher')) {
    & certutil.exe -f -addstore $store $certificatePath
    if ($LASTEXITCODE -ne 0) { throw "lab trust import failed: $store" }
}
$signature = Set-AuthenticodeSignature -LiteralPath $driver -Certificate $cert -HashAlgorithm SHA256
if ($signature.Status -ne 'Valid') { throw "signing failed: $($signature.Status) $($signature.StatusMessage)" }
$verified = Get-AuthenticodeSignature -LiteralPath $driver
if ($verified.Status -ne 'Valid' -or $verified.SignerCertificate.Thumbprint -ine $cert.Thumbprint) { throw 'signed output verification failed' }
$manifest | Add-Member -NotePropertyName resign_input_manifest_sha256 -NotePropertyValue $ManifestSHA256
$manifest | Add-Member -NotePropertyName resign_input_driver_sha256 -NotePropertyValue $manifest.driver_sha256
$manifest | Add-Member -NotePropertyName resign_script_sha256 -NotePropertyValue (Get-FileHash -Algorithm SHA256 $PSCommandPath).Hash.ToLowerInvariant()
$manifest | Add-Member -NotePropertyName resign_host_utc -NotePropertyValue $HostUtc.ToString('o')
$manifest | Add-Member -NotePropertyName resign_guest_utc -NotePropertyValue $now.ToString('o')
$manifest.driver_sha256 = (Get-FileHash -Algorithm SHA256 $driver).Hash.ToLowerInvariant()
$manifest.certificate_thumbprint = $cert.Thumbprint
$manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'manifest.json') -Encoding UTF8
$manifest | ConvertTo-Json
Write-Output 'LAB_RESIGN_COMPLETE'
