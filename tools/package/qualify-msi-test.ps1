# Portable tests of failure interpretation only. Not an MSI/VM qualification.
$ErrorActionPreference='Stop'
. "$PSScriptRoot\inputs.ps1"
$identity=Get-MsiDriverIdentity 'C:\Program Files (x86)\WinFsp\' 'C:\Program Files (x86)\WinFsp\SxS\sxs.20260930T015956Z\'
if($identity.Name -cne 'WinFsp+20260930T015956Z' -or $identity.Path -cne 'C:\Program Files (x86)\WinFsp\SxS\sxs.20260930T015956Z\bin\winfsp-x64.sys'){throw 'Incorrect MSI side-by-side driver identity'}
foreach($path in @('C:\lab\bin','C:\Program Files (x86)\WinFsp\SxS\sxs.20260930T015956Z\..\other','C:\Program Files (x86)\WinFsp\SxS\sxs.stale')) {
    $rejected=$false
    try {$null=Get-MsiDriverIdentity 'C:\Program Files (x86)\WinFsp\' $path} catch {$rejected=$true}
    if(-not $rejected){throw 'Invalid registered SxS identity accepted'}
}
Assert-DeferredRollbackEvidence 'CustomAction WixFailWhenDeferred returned actual error code 1603 (note this may not be 100% accurate)'
foreach($log in @('WIXFAILWHENDEFERRED = 1','Action start: WixFailWhenDeferred.','CustomAction Unrelated returned actual error code 1603','CustomAction WixFailWhenDeferred returned actual error code 0')) {
    $rejected=$false
    try {Assert-DeferredRollbackEvidence $log} catch {$rejected=$true}
    if(-not $rejected){throw 'Unrelated MSI failure accepted as injected rollback'}
}
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'qualify-msi.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Invalid qualification script'}
$functions=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-Msi'},$true))
if($functions.Count -ne 1){throw 'Expected one production MSI invocation helper'}
Invoke-Expression $functions[0].Extent.Text
$script:fakeExit=0
function Start-Process {
    param($FilePath,$ArgumentList,[switch]$Wait,[switch]$PassThru)
    if($FilePath -ne 'msiexec.exe' -or -not $Wait -or -not $PassThru){throw 'MSI must be synchronous with observed exit'}
    return [pscustomobject]@{ExitCode=$script:fakeExit}
}
$out='C:\lab\output'
foreach($code in @(0,3010,1603,1618,1625)) {
    $script:fakeExit=$code
    $rejected=$false; $result=$null
    try {$result=Invoke-Msi 'C:\candidate.msi' 'upgrade' @('APPMANA_LAB_ONLY=1')} catch {$rejected=$true}
    if($rejected -ne ($code -notin @(0,3010))){throw "Wrong upgrade exit handling: $code"}
    if(-not $rejected -and $result -ne $code){throw 'MSI exit lost'}
    $rejected=$false
    try {$null=Invoke-Msi 'C:\candidate.msi' 'guard' @() @(1603)} catch {$rejected=$true}
    if($rejected -ne ($code -ne 1603)){throw "Wrong expected-failure handling: $code"}
}
'MSI_EXIT_CONTRACT_PASS'
