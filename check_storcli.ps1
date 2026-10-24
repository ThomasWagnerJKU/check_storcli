# Nagios/Icinga plugin (Windows, e.g. via SNClient/NSClient++) to check Broadcom/LSI
# MegaRAID controllers via storcli's JSON output. Windows sibling of check_storcli.
#
# Copyright (C) 2026 Thomas Wagner <thomas.wagner@jku.at>
# SPDX-License-Identifier: GPL-2.0-or-later

<#
.SYNOPSIS
  Nagios/snclient check for Broadcom/LSI MegaRAID controllers via storcli JSON output.

.DESCRIPTION
  Checks controller status, virtual drives, physical drives (state, media/other
  errors, predictive failures, SMART alerts) and CacheVault/BBU.
  Emits drive temperatures and error counters as perfdata.

  Exit codes: 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN

  SNClient passes arguments quoted, so named parameters don't bind; give them
  positionally in the order below. An empty first argument ("") doesn't survive
  SNClient's quoting, so pass the storcli path explicitly to change later ones.

.PARAMETER StorCli
  Path to storcli64.exe. If omitted, PATH and common install locations are searched.

.PARAMETER TempWarn / TempCrit
  Drive temperature thresholds in degrees C.

.PARAMETER MediaErrWarn
  Media error count per drive that triggers WARNING (default 1).

.PARAMETER RocWarn / RocCrit
  Controller (RAID-on-Chip) temperature thresholds in degrees C.

.PARAMETER TimeoutSec
  Timeout per storcli call in seconds (default 60).
#>
param(
    [string]$StorCli = "",
    [int]$TempWarn = 50,
    [int]$TempCrit = 60,
    [int]$MediaErrWarn = 1,
    [int]$RocWarn = 95,
    [int]$RocCrit = 105,
    [int]$TimeoutSec = 60
)

$ErrorActionPreference = "Stop"

$OK = 0; $WARNING = 1; $CRITICAL = 2; $UNKNOWN = 3
$script:State = $OK
$script:Problems = New-Object System.Collections.Generic.List[string]
$script:Perf = New-Object System.Collections.Generic.List[string]

# Severity order: OK < WARNING < UNKNOWN < CRITICAL
$script:Rank = @{ 0 = 0; 1 = 1; 3 = 2; 2 = 3 }

function Raise([int]$s, [string]$msg) {
    if ($script:Rank[$s] -gt $script:Rank[$script:State]) { $script:State = $s }
    $script:Problems.Add($msg)
}

# Writes to the console directly: Write-Output inside a function whose result is
# assigned ($x = Some-Function) would be captured into the variable and lost on exit.
function Exit-Unknown([string]$msg) {
    [Console]::Out.WriteLine("UNKNOWN - $msg")
    exit $UNKNOWN
}

# Whole number from a JSON value, or $null for anything else (e.g. "N/A")
function ToInt($v) {
    if ($null -eq $v) { return $null }
    $d = 0.0
    if ([double]::TryParse([string]$v, [Globalization.NumberStyles]::Float,
                           [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) {
        return [int][math]::Floor($d)
    }
    return $null
}

function Find-StorCli {
    if ($StorCli) {
        if (Test-Path -LiteralPath $StorCli) { return $StorCli }
        Exit-Unknown "storcli not found at '$StorCli'"
    }
    $cmd = Get-Command storcli64.exe, storcli.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        "${env:ProgramFiles(x86)}\MegaRAID Storage Manager\StorCLI64.exe",
        "$env:ProgramFiles\Broadcom\StorCLI\storcli64.exe",
        "$env:ProgramFiles\StorCLI\storcli64.exe",
        "$env:ProgramFiles\LSI\StorCLI\storcli64.exe",
        "$env:ProgramFiles\MegaRAID\StorCLI\storcli64.exe",
        "C:\StorCLI\storcli64.exe",
        "C:\storcli64.exe"
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    Exit-Unknown "storcli64.exe not found (pass -StorCli <path>)"
}

function Invoke-StorCli([string]$exe, [string[]]$cliArgs) {
    $what = $cliArgs -join ' '
    # storcli writes storcli.log into the working directory; keep it out of the snclient folder.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = $what
    $psi.WorkingDirectory = $env:TEMP
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Exit-Unknown "cannot run storcli '$exe': $($_.Exception.Message)"
    }
    # Read both streams asynchronously, so a full pipe can't block storcli
    $stdout = $p.StandardOutput.ReadToEndAsync()
    $stderr = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { }
        Exit-Unknown "storcli timed out after ${TimeoutSec}s for '$what'"
    }
    $out = $stdout.Result + $stderr.Result

    $json = $null
    try { $json = $out | ConvertFrom-Json } catch { }
    if ($null -eq $json -or $null -eq $json.PSObject.Properties["Controllers"]) {
        $first = ($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        Exit-Unknown "cannot parse storcli output for '$what': $first"
    }
    return , @($json.Controllers)
}

# Return property value by exact name, or $null (property names contain spaces/slashes)
function Prop($obj, [string]$name) {
    if ($null -eq $obj) { return $null }
    $p = $obj.PSObject.Properties[$name]
    if ($p) { return $p.Value }
    return $null
}

$exe = Find-StorCli

# --- Controller, VD list, PD list, CacheVault/BBU -------------------------
$ctrls = Invoke-StorCli $exe @("/call", "show", "all", "J")

$nCtrl = 0; $nVD = 0; $nPD = 0

foreach ($c in $ctrls) {
    $cs = Prop $c "Command Status"
    $cid = Prop $cs "Controller"
    if ((Prop $cs "Status") -ne "Success") {
        Raise $UNKNOWN "c$cid storcli: $(Prop $cs 'Description')"
        continue
    }
    $nCtrl++
    $rd = Prop $c "Response Data"

    # Controller status
    $status = Prop $rd "Status"
    $ctrlStatus = Prop $status "Controller Status"
    if ($ctrlStatus -and $ctrlStatus -ne "Optimal") {
        Raise $CRITICAL "c$cid controller $ctrlStatus"
    }
    $memUnc = ToInt (Prop $status "Memory Uncorrectable Errors")
    $memErr = ToInt (Prop $status "Memory Correctable Errors")
    if ($memUnc -gt 0) { Raise $CRITICAL "c$cid $memUnc uncorrectable memory errors" }
    if ($memErr -gt 0) { Raise $WARNING "c$cid $memErr correctable memory errors" }

    # RAID-on-Chip temperature
    $roc = ToInt (Prop (Prop $rd "HwCfg") "ROC temperature(Degree Celsius)")
    if ($null -ne $roc) {
        if ($roc -ge $RocCrit) { Raise $CRITICAL "c$cid controller temperature ${roc}C" }
        elseif ($roc -ge $RocWarn) { Raise $WARNING "c$cid controller temperature ${roc}C" }
        $script:Perf.Add("'c${cid}_roc_temp'=$roc;$RocWarn;$RocCrit")
    }

    # Virtual drives: Optl = OK, Rec (recovery) / Pdgd (partially degraded) / Dgrd = WARNING/CRITICAL
    foreach ($vd in @(Prop $rd "VD LIST")) {
        if ($null -eq $vd) { continue }
        $nVD++
        $name = "c$cid vd $(Prop $vd 'DG/VD') '$(Prop $vd 'Name')' ($(Prop $vd 'TYPE'))"
        $st = [string](Prop $vd "State")
        switch -CaseSensitive ($st) {
            "Optl" { }
            "Pdgd" { Raise $WARNING "$name partially degraded" }
            "Rec"  { Raise $WARNING "$name recovering" }
            "Dgrd" { Raise $CRITICAL "$name DEGRADED" }
            "OfLn" { Raise $CRITICAL "$name OFFLINE" }
            default { Raise $CRITICAL "$name state $st" }
        }
    }

    # Physical drives: Onln/UGood/GHS/DHS/JBOD = OK, Rbld = WARNING, others CRITICAL
    foreach ($pd in @(Prop $rd "PD LIST")) {
        if ($null -eq $pd) { continue }
        $nPD++
        $slot = Prop $pd "EID:Slt"
        $st = [string](Prop $pd "State")
        switch -Regex -CaseSensitive ($st) {
            "^(Onln|UGood|GHS|DHS|JBOD)$" { }
            "^Rbld$" { Raise $WARNING "c$cid pd $slot rebuilding" }
            "^UBad$" { Raise $CRITICAL "c$cid pd $slot unconfigured BAD" }
            "^Offln$" { Raise $CRITICAL "c$cid pd $slot OFFLINE" }
            default { Raise $CRITICAL "c$cid pd $slot state $st" }
        }
    }

    # CacheVault / BBU
    foreach ($cv in @(Prop $rd "Cachevault_Info")) {
        if ($null -eq $cv) { continue }
        $cvState = Prop $cv "State"
        if ($cvState -and $cvState -ne "Optimal") { Raise $WARNING "c$cid CacheVault $cvState" }
        $t = Prop $cv "Temp"
        if ([string]$t -match "(\d+)") { $script:Perf.Add("'c${cid}_cachevault_temp'=$($Matches[1])") }
    }
    foreach ($bbu in @(Prop $rd "BBU_Info")) {
        if ($null -eq $bbu) { continue }
        $bState = Prop $bbu "State"
        if ($bState -and $bState -ne "Optimal") { Raise $WARNING "c$cid BBU $bState" }
        $t = Prop $bbu "Temp"
        if ([string]$t -match "(\d+)") { $script:Perf.Add("'c${cid}_bbu_temp'=$($Matches[1])") }
    }
}

if ($nCtrl -eq 0) {
    $why = if ($script:Problems.Count -gt 0) { " ($($script:Problems -join ', '))" } else { "" }
    Exit-Unknown "no usable controller found$why"
}

# --- Per-drive details: error counters, SMART, temperature ----------------
$details = Invoke-StorCli $exe @("/call/eall/sall", "show", "all", "J")

foreach ($c in $details) {
    $cs = Prop $c "Command Status"
    if ((Prop $cs "Status") -ne "Success") {
        Raise $UNKNOWN "c$(Prop $cs 'Controller') storcli: $(Prop $cs 'Description')"
    }
}

# Find every "Drive /cX/eY/sZ State" (or "/cX/sZ" without enclosure) object,
# wherever storcli nests it (normally under "Drive ... - Detailed Information").
function Find-DriveStates($obj, [System.Collections.Generic.List[object]]$found) {
    if ($obj -is [System.Array]) { foreach ($o in $obj) { Find-DriveStates $o $found }; return }
    if ($null -eq $obj -or $obj -isnot [System.Management.Automation.PSCustomObject]) { return }
    foreach ($p in $obj.PSObject.Properties) {
        if ($p.Name -cmatch "^Drive (/c(\d+)(/e(\d+))?/s(\d+)) State$" -and $p.Value) {
            $encl = if ($Matches[4]) { "_e$($Matches[4])" } else { "" }
            $found.Add([pscustomobject]@{
                Path  = $Matches[1]
                Label = "c$($Matches[2])${encl}_s$($Matches[5])"
                State = $p.Value
            })
        } else {
            Find-DriveStates $p.Value $found
        }
    }
}

$driveStates = New-Object System.Collections.Generic.List[object]
foreach ($c in $details) { Find-DriveStates (Prop $c "Response Data") $driveStates }

foreach ($d in $driveStates) {
    $path = $d.Path; $label = $d.Label; $stateBlock = $d.State
    $media = ToInt (Prop $stateBlock "Media Error Count")
    $other = ToInt (Prop $stateBlock "Other Error Count")
    $pred  = ToInt (Prop $stateBlock "Predictive Failure Count")
    $smart = Prop $stateBlock "S.M.A.R.T alert flagged by drive"
    # A missing counter means 0, as in the Linux variant
    if ($null -eq (Prop $stateBlock "Media Error Count")) { $media = 0 }
    if ($null -eq (Prop $stateBlock "Other Error Count")) { $other = 0 }
    if ($null -eq (Prop $stateBlock "Predictive Failure Count")) { $pred = 0 }

    if ($smart -eq "Yes") { Raise $CRITICAL "$path SMART alert" }
    if ($null -ne $pred -and $pred -gt 0) { Raise $CRITICAL "$path $pred predictive failures" }
    if ($null -ne $media -and $media -ge $MediaErrWarn) { Raise $WARNING "$path $media media errors" }

    if ($null -ne $media) { $script:Perf.Add("'${label}_media_err'=${media}c") }
    if ($null -ne $other) { $script:Perf.Add("'${label}_other_err'=${other}c") }
    if ($null -ne $pred)  { $script:Perf.Add("'${label}_pred_fail'=${pred}c") }

    $temp = Prop $stateBlock "Drive Temperature"
    if ([string]$temp -cmatch "(\d+)C") {
        $t = [int]$Matches[1]
        if ($t -ge $TempCrit) { Raise $CRITICAL "$path temperature ${t}C" }
        elseif ($t -ge $TempWarn) { Raise $WARNING "$path temperature ${t}C" }
        $script:Perf.Add("'${label}_temp'=$t;$TempWarn;$TempCrit")
    }
}

if ($driveStates.Count -lt $nPD) {
    Raise $UNKNOWN "drive details found for only $($driveStates.Count) of $nPD drive(s)"
}

# --- Output --------------------------------------------------------------
$label = @("OK", "WARNING", "CRITICAL", "UNKNOWN")[$script:State]
$summary = "$nCtrl controller(s), $nVD VD(s), $nPD PD(s)"
if ($script:Problems.Count -gt 0) {
    $msg = "$label - $($script:Problems -join ', ') [$summary]"
} else {
    $msg = "$label - all optimal [$summary]"
}
$script:Perf.Insert(0, "vd=$nVD")
$script:Perf.Insert(1, "pd=$nPD")
Write-Output "$msg | $($script:Perf -join ' ')"
exit $script:State
