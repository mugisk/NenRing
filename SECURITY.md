# Security Policy

[日本語](SECURITY.ja.md)

NenRing reads storage statistics through private Apple interfaces, and one probe can run as root: the FTL statistics probe, only when a manual read is refused for lack of privileges and you approve the standard macOS administrator prompt. Security reports are welcome.

## Reporting a vulnerability

Report privately through GitHub: on this repository, open **Security → Report a vulnerability**. Do not open a public issue containing vulnerability details, credentials, or diagnostic evidence.

If that button is not shown, open a public issue titled "Security contact request" that contains no details, and the maintainer will arrange a private channel.

Include the macOS version and build, the NenRing commit or version, and the steps to reproduce. We aim to acknowledge reports within 7 days.

## Scope

In scope:

- The two probes bundled in `NenRing.app/Contents/Resources/ASPProbes`, built from `scripts/asp-ftl-stats-probe.c` and `scripts/asp-snapshot-probe.c`. `asp-ftl-stats-probe` runs as root only on a manual administrator retry. `scripts/asp-smart-export-probe.c` is a research tool and is not bundled.
- The administrator launch path (`ASPDirectProbeGenerator`), which runs `osascript` with `do shell script … with administrator privileges`.
- Probe signature and location checks (`ASPProbeSignature`, see [probe signature checks](docs/PROBE_SIGNATURE.en.md)).
- Parsing of an `asptool_snapshot.log` that the user loads under Settings → Research (`ASPToolSnapshotCollector`). NenRing never runs `asptool` itself; the log is only compared with Direct FTL reads and never used for the forecast.
- Importing `asptool_snapshot.log` from a sysdiagnose (`SysdiagnoseTerminalLauncher`, `SysdiagnoseASPToolLocator`). The app opens a `.command` file containing `sudo /usr/bin/sysdiagnose` in Terminal; the user authenticates there, and the app itself never runs it with administrator privileges. When the archive is complete, the app uses `/usr/bin/tar` to extract only that log from the newest `.tar.gz` starting with `sysdiagnose_` in `/private/var/tmp` into `~/Library/Caches/io.github.mugisk.NenRing/asptool-imports/`. The original archive is not changed.
- Handling of local data under `~/Library/Application Support/NenRing/`.

Out of scope: the accuracy of wear or endurance estimates, and bugs in smartmontools itself.

## Current safeguards

- **Fixed probes only.** The app can launch only a fixed list of probes with fixed arguments. It never passes a user-supplied opcode or shell string, and it never scans opcodes.
- **Checks before every launch.** Before launching a probe, the app checks that it is at the fixed location inside the app bundle and that its code signature passes a strict check with the expected identifier.
- **Stricter checks for administrator runs.** For an administrator run, every directory from the probe up to `/` must be owned by root and not writable by group or others. As a result, administrator probes are refused when the app is in the default `/Applications` folder, which is group-writable.
- **Build check.** Both probes refuse unreviewed macOS releases (only 26 and 27 are reviewed) unless `--allow-unreviewed-build` is passed. The app passes that flag for manual runs, scheduled FTL `all` compatibility trials on macOS 14/15, and scheduled FTL on other releases with a passing local SMART cross-check. The trial does not extend reviewed support or enable automatic snapshot-header/payload calls. Automatic FTL reads use normal rights only. Every saved read is cross-checked, and forecast inputs retain their separate boundary-continuity gates (on macOS 14/15 these catch discontinuities only; see Known limitations).
- **Apple controller only.** Both probes open only Apple's internal NVMe controller (`AppleANS2NVMeController` or a subclass, such as `AppleANS3NVMeController` on macOS 26 and `AppleANS3CGv2Controller` on macOS 27), so third-party NVMe drives never receive the private calls. The app also refuses manual probe runs unless the selected drive is Apple internal storage.
- **Checked FTL target.** The app passes the probe three IORegistry IDs for the selected drive: the SMART service, the ANS controller, and the Whole Media that represents the whole disk. Before opening the private FTL interface, the probe checks that these IDs match the current IORegistry and that there is exactly one Whole Media. If either check fails, the probe exits without calling FTL and does not read another drive instead. After the read, the app checks that the IDs reported by the probe match the ones it passed, and discards a result that does not match. When the probe is run on its own without IDs, it reads only if there is exactly one candidate Apple internal drive. IORegistry IDs can change, for example after a restart, so they are not used to identify history.
- **Cross-check before storing.** Every Direct FTL read is compared with SMART Host Writes from the same device, and sudden changes or reversals of the POH offset are checked when reference data are available. A consistency mismatch prevents storage and immediately stops automatic collection. Ordinary acquisition failures stop scheduled collection after three consecutive failures. Missing required inputs defer storage; missing optional POH evidence leaves that comparison pending ("waiting for comparison"). Supplemental wear percentages do not stop collection. See the [cross-validation specification](docs/DIRECT_FTL_CROSS_VALIDATION.en.md) for scope and limitations.
- **Exit status of administrator runs.** The probe's own exit status is read from the administrator run's output; if it cannot be read, the run is reported as failed.
- **Safe file handling as root.** Probes that run as root create files through directory descriptors opened with `O_NOFOLLOW` and use `openat(O_EXCL)` and `fchown`, so replacing a path with a symlink cannot redirect writes or ownership changes.
- **Time limit.** Each probe runs as a separate process with a hard time limit.

## Known limitations

- Local builds use ad-hoc signing unless `CODE_SIGN_IDENTITY` is set. Ad-hoc signing detects tampering but does not prove who built the binary.
- There is no notarized release yet.
- On a macOS release the project has not reviewed, the first Direct FTL read is a call into an interface whose layout has not been checked on that release. Outside the macOS 14/15 compatibility trial, it is always started by the user; scheduled collection follows only after that read passed the SMART cross-check.
- On macOS 14 and 15, scheduled reads start without a manual first read, and values that pass the per-read SMART Host-writes check feed the forecast. The boundary-continuity checks detect sudden changes, not a private value whose meaning differs on these releases, and a first install has no earlier history to compare with.
