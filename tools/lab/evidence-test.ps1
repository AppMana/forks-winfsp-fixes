$ErrorActionPreference='Stop'
. "$PSScriptRoot/evidence.ps1"
$inventory=@('create_test','reparse_test')
$good="create_test............................. OK 0.01s`nreparse_test............................ OK 1.20s`n--- COMPLETE ---`n"
Assert-NativeSuiteEvidence $inventory $good 0
foreach($bad in @('',($good -replace '--- COMPLETE ---',''),($good -replace 'OK 1.20s','KO'),($good -replace 'reparse_test','wrong_test__'),($good+"unexpected`n"))) {
    $rejected=$false
    try{Assert-NativeSuiteEvidence $inventory $bad 0}catch{$rejected=$true}
    if(-not $rejected){throw 'Invalid native output accepted'}
}
foreach($badNames in @(@(),@('create_test'),@('create_test','create_test'))) {
    $rejected=$false
    try{Assert-NativeSuiteEvidence $badNames $good 0}catch{$rejected=$true}
    if(-not $rejected){throw 'Invalid inventory accepted'}
}
$rejected=$false
try{Assert-NativeSuiteEvidence $inventory $good 1}catch{$rejected=$true}
if(-not $rejected){throw 'Failed process accepted'}
'PASS: native evidence rejects missing, failed, duplicate, mismatched and extra results'
