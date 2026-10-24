# check_storcli

A Nagios/Icinga plugin that checks Broadcom/LSI MegaRAID RAID controllers
with Broadcom's `storcli`. Two variants with the same states, output text and
performance data:

- `check_storcli`: Linux, bash. Needs `jq` and, unless run as root, `sudo`.
- `check_storcli.ps1`: Windows, PowerShell 5.1. Runs via SNClient/NSClient++
  as LocalSystem.

It checks the controller, every virtual drive, every physical drive (state,
media/other errors, predictive failures, SMART alert, temperature) and the
CacheVault/BBU, and reports drive and controller temperatures and error
counters as performance data.

## Usage

### Linux: check_storcli

```sh
check_storcli
check_storcli -s /opt/MegaRAID/storcli/storcli64 -w 45 -c 55
```

```
OK - all optimal [1 controller(s), 2 VD(s), 12 PD(s)] | vd=2 pd=12 'c0_roc_temp'=66;95;105 'c0_e251_s0_media_err'=0c 'c0_e251_s0_other_err'=0c 'c0_e251_s0_pred_fail'=0c 'c0_e251_s0_temp'=41;50;60 ...
```

| Option | Meaning |
|---|---|
| `-s` | Path of storcli64 (default: search `PATH`, `/opt/MegaRAID/storcli/`, `/usr/sbin`, `/usr/local/sbin`) |
| `-w` | Drive temperature warning in °C (default: 50) |
| `-c` | Drive temperature critical in °C (default: 60) |
| `-m` | Media errors per drive that trigger WARNING (default: 1) |
| `-r` | Controller (ROC) temperature warning in °C (default: 95) |
| `-R` | Controller (ROC) temperature critical in °C (default: 105) |
| `-t` | Timeout in seconds for each storcli call (default: 60) |
| `-S` | Don't use sudo (when the check already runs as root) |
| `-V` | Show the version |
| `-h` | Show the help |

All numbers are whole numbers; anything else gives UNKNOWN.

storcli needs root, so the plugin runs `sudo -n storcli64 ...`. Allow exactly
the two read-only calls it makes, e.g. in `/etc/sudoers.d/naemon-storcli`:

```
Cmnd_Alias STORCLI_READ = /opt/MegaRAID/storcli/storcli64 /call show all J, \
                          /opt/MegaRAID/storcli/storcli64 /call/eall/sall show all J
Defaults!STORCLI_READ runcwd=/var/tmp
naemon ALL=(root) NOPASSWD: STORCLI_READ
```

Replace `naemon` with whichever account runs the check, and the path with the
one passed to `-s` or found automatically, exactly as written there: symlinks
are not resolved, a relative `-s` path is only prefixed with the current
directory.

`runcwd` (sudo 1.9.3 or newer) matters: storcli writes `storcli.log` into its
working directory, as root. Without it, the monitoring account could run the
allowed command from a directory where `storcli.log` is a symlink to any file
and have root append to that file. With an older sudo, point the rule at a
small root-owned wrapper script that `cd`s into a fixed directory first. The
plugin itself always runs storcli from a fresh temporary directory, so the log
doesn't pile up in the monitoring user's directory.

### Windows: check_storcli.ps1

```
check_storcli.ps1
check_storcli.ps1 "C:\Program Files (x86)\MegaRAID Storage Manager\StorCLI64.exe" 45 55
```

Parameters, in this order: `-StorCli`, `-TempWarn`, `-TempCrit`,
`-MediaErrWarn`, `-RocWarn`, `-RocCrit`, `-TimeoutSec`, with the same defaults
as the Linux options. SNClient passes arguments quoted, so named parameters
don't bind there; give them positionally instead, as in the example above
(other drive temperature thresholds). An empty first argument (`""`) doesn't
survive SNClient's quoting, so to change a later parameter, pass the storcli
path explicitly. Without `-StorCli`
the script searches `PATH` and the usual install locations, including the copy
that comes with MegaRAID Storage Manager
(`C:\Program Files (x86)\MegaRAID Storage Manager\StorCLI64.exe`).

With SNClient, put the script into `scripts\` and register it as a wrapped
script in `snclient_local.ini`, or put it into `scripts\autoinclude\`:

```ini
[/settings/external scripts/wrapped scripts]
check_storcli.ps1 = check_storcli.ps1
```

It runs storcli from `%TEMP%`, so `storcli.log` doesn't land in the agent's
directory.

## What it checks

The plugin runs `storcli /call show all J` (controllers, virtual and physical
drive lists, CacheVault/BBU) and `storcli /call/eall/sall show all J`
(per-drive details).

### States

- **CRITICAL**: a controller isn't `Optimal` or has uncorrectable memory
  errors; a virtual drive is degraded (`Dgrd`), offline (`OfLn`) or in another
  unknown state; a physical drive is unconfigured bad, offline or in another
  unknown state; a drive raised a SMART alert or has predictive failures; a
  drive or the controller is at or above its critical temperature
- **WARNING**: a virtual drive is partially degraded (`Pdgd`) or recovering
  (`Rec`); a physical drive is rebuilding (`Rbld`); a CacheVault/BBU isn't
  `Optimal`; the controller has correctable memory errors; a drive has at
  least `-m` media errors; a drive or the controller is at or above its
  warning temperature
- **UNKNOWN**: storcli isn't found, times out or its output can't be parsed;
  a controller reports a failed command; no controller answers; per-drive
  details are missing for some drives; an argument is invalid

Physical drive states `Onln`, `UGood`, `GHS`, `DHS` and `JBOD` are fine.
Problems are listed in the output, worst state wins (UNKNOWN ranks between
WARNING and CRITICAL). A value storcli reports as something other than a
number (e.g. `N/A`) is treated as absent. The plugin prints exactly one line.

### Performance data

- `vd`, `pd`: number of virtual and physical drives
- `cN_roc_temp`: controller (RAID-on-Chip) temperature, with the thresholds
- `cN_eE_sS_temp`: drive temperature, with the thresholds (`cN_sS_temp` for
  drives attached without an enclosure)
- `cN_eE_sS_media_err`, `_other_err`, `_pred_fail`: drive error counters
- `cN_cachevault_temp`, `cN_bbu_temp`: CacheVault/BBU temperature, if present

## Bash completion

`completions/check_storcli` completes the options and the path of storcli64
for `-s`. The packages install it; otherwise copy it to bash-completion's
directory:

```sh
install -D -m 0644 completions/check_storcli /usr/share/bash-completion/completions/check_storcli
```

## Tests

```sh
tests/run_tests.sh
tests/test_completion.sh
```

`run_tests.sh` replays recorded storcli JSON (from a MegaRAID 9580-8i8e,
serial numbers removed) through a fake storcli and sudo, and needs `jq`.
`test_completion.sh` tests the bash completion. The Windows variant has no
automated tests.

## License

GPL-2.0-or-later, see [LICENSE](LICENSE).
