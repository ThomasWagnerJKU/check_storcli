#!/bin/bash
# Tests for check_storcli: replay recorded storcli JSON through a fake storcli64.
# Usage: tests/run_tests.sh   (needs jq)

cd "$(dirname "$0")/.." || exit 1
CHECK=./check_storcli
FAKE=tests/bin/storcli64      # relative on purpose: the plugin must cope with that
export PATH="$PWD/tests/bin:$PATH"
fail=0
count=0

# expect NAME EXPECTED_RC EXPECTED_SUBSTRING [ENV=VALUE ...] -- [CHECK ARGS...]
# Runs with -S (no sudo) unless USE_SUDO=1 is among the ENV settings.
expect() {
    local name=$1 rc_want=$2 want=$3; shift 3
    local envs=() nosudo=-S
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do
        [ "$1" = USE_SUDO=1 ] && nosudo=""
        envs+=("$1"); shift
    done
    shift
    local out rc
    out=$(env "${envs[@]}" "$CHECK" $nosudo -s "$FAKE" "$@" 2>&1); rc=$?
    count=$((count + 1))
    if [ "$rc" -eq "$rc_want" ] && [[ $out == *"$want"* ]]; then
        echo "ok   $name"
    else
        echo "FAIL $name: rc=$rc (want $rc_want), output:"; echo "     $out"
        echo "     expected to contain: $want"
        fail=1
    fi
}

# All fine
expect "all optimal" 0 "OK - all optimal [1 controller(s), 2 VD(s), 4 PD(s)]" --
expect "perfdata: counts and ROC" 0 "| vd=2 pd=4 'c0_roc_temp'=66;95;105" --
expect "perfdata: drive temp" 0 "'c0_e251_s5_temp'=42;50;60" --
expect "perfdata: error counters" 0 "'c0_e251_s0_media_err'=0c 'c0_e251_s0_other_err'=0c 'c0_e251_s0_pred_fail'=0c" --
expect "via sudo -n" 0 "OK - all optimal" USE_SUDO=1 --

# WARNING-only conditions
expect "warning only" 1 "WARNING - c0 2 correctable memory errors" CTRL_FIXTURE=ctrl_warning.json --
expect "partially degraded VD" 1 "c0 vd 0/239 'daily' (RAID6) partially degraded" CTRL_FIXTURE=ctrl_warning.json --
expect "recovering VD" 1 "c0 vd 1/238 'storage' (RAID6) recovering" CTRL_FIXTURE=ctrl_warning.json --
expect "rebuilding PD" 1 "c0 pd 251:5 rebuilding" CTRL_FIXTURE=ctrl_warning.json --
expect "CacheVault not optimal" 1 "c0 CacheVault Degraded" CTRL_FIXTURE=ctrl_warning.json --
expect "BBU not optimal" 1 "c0 BBU Learning" CTRL_FIXTURE=ctrl_warning.json --
expect "CacheVault and BBU temps" 1 "'c0_cachevault_temp'=38 'c0_bbu_temp'=30" CTRL_FIXTURE=ctrl_warning.json --

# CRITICAL conditions
expect "degraded VD" 2 "c0 vd 1/238 'storage' (RAID6) DEGRADED" CTRL_FIXTURE=ctrl_degraded.json --
expect "offline PD" 2 "c0 pd 251:4 OFFLINE" CTRL_FIXTURE=ctrl_degraded.json --
expect "controller not optimal" 2 "CRITICAL - c0 controller Needs Attention" CTRL_FIXTURE=ctrl_critical.json --
expect "uncorrectable memory errors" 2 "c0 1 uncorrectable memory errors" CTRL_FIXTURE=ctrl_critical.json --
expect "unconfigured bad PD" 2 "c0 pd 251:4 unconfigured BAD" CTRL_FIXTURE=ctrl_critical.json --
expect "unknown PD state" 2 "c0 pd 251:5 state Cpybck" CTRL_FIXTURE=ctrl_critical.json --
expect "unknown VD state" 2 "c0 vd 0/239 'daily' (RAID6) state Rbld" CTRL_FIXTURE=ctrl_critical.json --
expect "SMART alert" 2 "/c0/e251/s4 SMART alert" DRIVE_FIXTURE=drives_bad.json --
expect "predictive failures" 2 "/c0/e251/s4 2 predictive failures" DRIVE_FIXTURE=drives_bad.json --
expect "hot drive" 2 "/c0/e251/s5 temperature 55C" DRIVE_FIXTURE=drives_bad.json --

# Drive details
expect "media errors warn" 1 "WARNING - /c0/e251/s1 3 media errors" DRIVE_FIXTURE=drives_media_errors.json --
expect "-m raises the media error limit" 0 "OK - all optimal" DRIVE_FIXTURE=drives_media_errors.json -- -m 5
expect "missing field keeps the rest" 0 "'c0_e251_s0_pred_fail'=0c 'c0_e251_s0_temp'=41;50;60" DRIVE_FIXTURE=drives_missing_smart.json --
expect "drives without enclosure" 0 "'c0_s5_temp'=42;50;60" CTRL_FIXTURE=ctrl_direct.json DRIVE_FIXTURE=drives_direct.json --
expect "missing drive details" 3 "UNKNOWN - drive details found for only 3 of 4 drive(s)" DRIVE_FIXTURE=drives_partial.json --
expect "failed drive query" 3 "c0 storcli: Show Drive Information Failed." DRIVE_FIXTURE=drives_failed.json --
expect "no drive details at all" 3 "drive details found for only 0 of 4 drive(s)" DRIVE_FIXTURE=ctrl_optimal.json --

# Thresholds
expect "drive temperature thresholds" 1 "WARNING - /c0/e251/s1 temperature 42C" -- -w 42 -c 99
expect "ROC thresholds" 2 "c0 controller temperature 66C" -- -r 50 -R 60
expect "ROC perfdata thresholds" 0 "'c0_roc_temp'=66;80;90" -- -r 80 -R 90
expect "non-numeric values ignored" 0 "OK - all optimal [1 controller(s), 2 VD(s), 4 PD(s)] | vd=2 pd=4 'c0_e251_s0" CTRL_FIXTURE=ctrl_na.json --

# Controller failures and severity order (UNKNOWN beats WARNING, CRITICAL beats UNKNOWN)
expect "failed controller" 3 "UNKNOWN - no usable controller found (c0 storcli: Controller 0 not found)" CTRL_FIXTURE=ctrl_failed.json --
expect "no controllers" 3 "UNKNOWN - no usable controller found" CTRL_FIXTURE=ctrl_empty.json --
expect "UNKNOWN beats WARNING" 3 "UNKNOWN - c0 pd 251:5 rebuilding, c1 storcli: Controller 1 not found" CTRL_FIXTURE=ctrl_mixed.json --
expect "CRITICAL beats UNKNOWN" 2 "CRITICAL - " CTRL_FIXTURE=ctrl_degraded.json DRIVE_FIXTURE=drives_partial.json --

# storcli problems and arguments
expect "missing storcli" 3 "UNKNOWN - storcli not found at" -- -s /nonexistent
expect "unparsable output" 3 "UNKNOWN - cannot parse storcli output for '/call show all J': StorCli64.exe: command not found" CTRL_FIXTURE=garbage.txt --
expect "storcli hangs" 3 "UNKNOWN - storcli timed out after 1s" HANG=1 -- -t 1
expect "invalid number" 3 "UNKNOWN - invalid value 'abc' for temp warn" -- -w abc
expect "help" 0 "Usage:" -- -h
expect "version" 0 "check_storcli 0.1" -- -V

echo "$count tests, $([ $fail -eq 0 ] && echo "all passed" || echo "FAILURES")"
exit $fail
