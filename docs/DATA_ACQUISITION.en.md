# Data acquisition

[日本語](DATA_ACQUISITION.md) · [Documentation](README.en.md)

This document describes what NenRing collects, where the data comes from and how it is read. It also covers the path from acquisition to the endurance forecast and the commands for checking the same information in Terminal. For reading the forecast, see the [forecast guide](FORECAST_GUIDE.en.md); for the calculation, see the [NAND model (Japanese)](NAND_MODEL_V2_4.md).

NenRing collects the following. Reading statistics does not change SSD settings or firmware; history and settings are written to local files.

| Data | Source | Default interval | Permissions |
|---|---|---|---|
| SMART | `smartctl` (smartmontools) | 10 minutes | Normal user |
| NAND configuration | IORegistry (public IOKit API; `ioreg` in Terminal) | One day, with additional updates for lifecycle and availability changes | Normal user |
| FTL statistics (Direct FTL) | Apple private interface (bundled probe) | 10 minutes (same cycle as SMART) | Normal user (only a manual retry may request administrator authentication) |
| Live disk I/O | IOBlockStorageDriver cumulative byte counters | 2 seconds by default while background monitoring | Normal user |

## SMART

The full SMART interval can be 5, 10, 15 or 30 minutes, or one hour; the default is 10 minutes. A saved value from an older version outside this range is mapped to a selectable interval. Temperature is recorded on an independent cycle that updates only the current temperature and the temperature chart. Boundary checks, wear, WAF, retention estimates and event analysis run when the full input (SMART, FTL, IORegistry, settings and so on) changes. Temperature history is not discarded; it is passed to the next full analysis. If the temperature updates while a full analysis is running, the older analysis result does not overwrite the newer temperature chart.

**Disk information** shows the saved SMART and IORegistry values with the capture time of each source. Opening it does not start a new read. SMART JSON can contain identifiers, which must be removed before sharing. The full IORegistry output is not stored; the parsed configuration is shown instead.

When an automatic SMART read fails, the main window and the menu bar show the failure. The last successful value remains, and the notice gives the time of the last success. Automatic reads do not switch the display to **Checking**; the failure notice clears on the next successful read. A temperature-only success does not clear a full SMART failure.

SMART (S.M.A.R.T., Self-Monitoring, Analysis and Reporting Technology) is how SSDs and HDDs report their own condition. NVMe defines it as the "SMART / Health Information" log. smartmontools is required and is not bundled with the app. NenRing runs the user-installed `smartctl` as a separate program and reads its JSON output.

The main fields used are Percentage Used, Data Units Written/Read (one unit is 512,000 bytes), Power On Hours, Power Cycles, Unsafe Shutdowns, temperature, Available Spare and Critical Warning.

### Selecting the internal SSD

1. `smartctl --scan-open -j` lists devices that can return SMART data.
2. Each candidate is checked with `diskutil info -plist`; devices macOS reports as internal (`Internal`) are preferred.
3. Values are read from the selected device with `smartctl -j -i -H -A -c`. `-c` formats the supported features from the same Identify data. Temperature-only reads run `smartctl -j -i -A` on the previously selected device. The serial number and similar values read with `-i` must match the previous ones; otherwise the device is selected again.
4. When temperature is recorded, read and write byte counts (`Bytes (Read)` and `Bytes (Write)`) are also read from the same device's IOBlockStorageDriver `Statistics`. NenRing looks for the driver that belongs to the selected SMART device and records nothing if more than one matches. The counters belong to a driver instance, so they restart not only at reboot but also when the driver is recreated. The boot time (`kern.boottime`) and, when available, the driver ID are stored with them. These records identify low-load periods between SMART reads; they do not replace SMART lifetime counters.

### Checking in Terminal

```bash
smartctl --scan-open -j
```

```bash
smartctl -j -i -H -A -c /dev/disk0
```

```bash
diskutil info -plist /dev/disk0
```

`/dev/disk0` is often the internal SSD, but this can differ between Macs. Check the output of the first command.

### Additional counters and capabilities

Host Read/Write Commands, Controller Busy Time (minutes) and Error Information Log Entries from the same SMART log are stored as optional fields. **Disk information** shows the totals and the change since the immediately preceding SMART read with the same device and firmware. Duplicate timestamps, decreasing power-on hours and firmware changes defer the comparison; a decreasing individual counter defers only that counter. Missing values are not stored as zero, and older history is not backfilled.

Average request size is the Data Units increase × 512,000 divided by the command-count increase over the same interval. It is not shown when the denominator is zero or a counter has decreased. It does not classify access as random or sequential. A Busy Time of zero is not treated as proof that the controller was idle.

NVMe feature bits are capabilities reported by the device. TRIM/Deallocate support is not a record of execution, and self-test support does not show that macOS can start a self-test. On the IORegistry side, `IOStorageFeatures.Unmap` of the selected SMART service is read during the existing (daily or similar) IORegistry read. Neither another disk's value nor the NVMe feature bit is used in its place.

Scheduled collection does not request detailed logs with `-a`, `-x`, `-l error` or `-l selftest`. Logs that cannot be collected are not queried repeatedly; the UI shows **Not collected (no scheduled reads)**. The error-log entry count in the normal SMART log is separate from that detailed log. NenRing adds no feature that runs TRIM, self-tests or firmware operations.

## Live disk I/O

While background monitoring is active and a SMART target is selected, NenRing reads only that device's IOBlockStorageDriver `Statistics`, every 1, 2 or 5 seconds (default: 2 seconds). The **Show I/O rates in the menu bar** setting switches only the rate text beside the icon; it does not stop sampling. The menu bar can show read, write, both or no rate text. The popup shows current rates on the left and a five-minute chart on the right. Red writes appear above the center line and blue reads below it, on a shared rate scale. The two are not stacked, and the downward direction does not mean negative I/O. **Write details** and **Short-term totals** appear below the chart, including totals and observed seconds.

**Write details (last 30 s)** shows the selected SSD’s block write rate alongside the three most active observable writers across the Mac. Rates are averaged over observed intervals in the last 30 seconds so brief bursts remain visible. Swap-out rates use the system page size to convert pages to bytes. They do not measure compressed SSD traffic or identify a process’s destination disk.

Rates are cumulative-counter deltas divided by the actual elapsed time on a monotonic clock. The driver is cached and resolved again when the target changes or a read fails. New temperature records also store the optional registry driver ID. A driver ID or boot-time change, a decreasing counter, a failed read or a gap longer than three sampling intervals breaks the delta and returns to waiting for a comparison. Sampling stops during sleep and while background monitoring is off, and the gap is not interpolated after wake.

Only up to 301 intervals from the last five minutes are kept in memory. Only an interval at the window edge is prorated, and observed seconds are shown with the totals. Session totals are the sum of valid intervals, so I/O while stopped or unobserved is not included. App restart or a target change clears this data; it is never written to disk. High-frequency updates notify only a dedicated view model and do not trigger SMART, FTL, retention analysis or forecast recalculation.

These are OS block I/O statistics, defined differently from SMART lifetime Host traffic and FTL NAND traffic. They are not added to those counters or automatically fed into WAF or retention-temperature learning. Their use for low-load temperature judgment is still awaiting separate validation.

## IORegistry (NAND configuration)

A successfully read configuration is cached for the exact target during the app session. Routine SMART updates reuse the cache for the same target without running ioreg again. If the binding is temporarily lost, the configuration is withheld; when the same target returns, the next SMART update restores it. A failed re-read does not clear the last successful cache, and the original capture time is kept. Restoring the cache is not treated as a new FTL identity observation.

macOS keeps device information in a registry called IORegistry. NenRing reads the internal SSD controller's "Controller Characteristics" from it: NAND vendor (`vendor-name`), generation (`nand-marketing-name`), page and block sizes, die count, `chip-id`, `firmware-version`, `msp-version` and similar values.

The controller class name depends on the macOS version: `AppleANS3NVMeController` up to macOS 26 and `AppleANS3CGv2Controller` on macOS 27. NenRing looks them up in this order:

`AppleANS3NVMeController` → `AppleANS3CGv2Controller` → `AppleANS2NVMeController` → `AppleANSNVMeController`

### Checking in Terminal

```bash
ioreg -lrw0 -d2 -c AppleANS3CGv2Controller
```

On macOS 26 and earlier, use the class name `AppleANS3NVMeController`.

> **Before sharing the output:** the full output can contain `controller-unique-id`, an identifier unique to the SSD. Do not paste it into an issue. To provide data, use the [diagnostic report](DIAGNOSTIC_REPORTS.en.md) with identifiers removed (Settings → General → Application → Diagnostic report). NenRing itself does not read `controller-unique-id`.

## Direct FTL (FTL statistics)

The target is bound by walking the selected disk's IORegistry ancestry. FTL and NAND information are both fixed to the same target; the first controller found is not simply taken. APFS synthesized disks are not counted as physical SSDs, and association is deferred when there are multiple namespaces or long-term identity is ambiguous. The number of FTL targets is not inferred from the NAND-module count or the Mac model, and values are not summed. See [target binding (Japanese)](STORAGE_TARGET_BINDING.md).

### What the FTL is

Inside the SSD, the FTL (Flash Translation Layer) decides where writes are placed in NAND. It records how much was actually written to NAND and how many times blocks were erased and rewritten (P/E). NenRing reads the following values from it, which SMART alone does not provide:

- NAND writes (SMART reports only Host writes)
- Average, minimum and maximum P/E for TLC and pSLC (cache), and the P/E limit (EOL)
- Sizes of the TLC and pSLC domains (topology)

### How it is called

Apple's NVMe SMART plug-in is a public interface that smartctl also uses. The plug-in UUID is `AA0FA6F9-C2D6-457F-B10B-59A13253292F` and the interface UUID is `CCD1DB19-FD9A-4DAF-BF95-12454B230AB6`. Outside the published part of this function table (vtable) are functions Apple uses for diagnostics (sysdiagnose).

| Kind | vtable offset | Contents |
|---|---|---|
| `all` | 0x108 | Full FTL statistics; this is what NenRing uses for forecasts |
| `perm` | 0x110 | Partial statistics in an unconfirmed format; manual research reads only |

The bundled probe (`asp-ftl-stats-probe`) reads them as follows:

1. Among devices with the "NVMe SMART Capable" property, it selects only those under Apple's internal NVMe controllers (`AppleANS2NVMeController` and its subclasses). Third-party NVMe devices are not opened.
2. It opens that device's SMART plug-in and calls the `all` (0x108) function.
3. It saves the returned data (up to 1 MiB) unchanged.

The probe runs as a separate, time-limited process. Before launching it, NenRing checks that the app is in the expected location and verifies its code signature ([probe signature](PROBE_SIGNATURE.en.md)).

### Data format and keys used

`all` data is a sequence of key/count/value records. Each record starts with a little-endian 64-bit value whose low 32 bits are the key and high 32 bits the number of following values; that many 64-bit values follow. This format is not a published Apple specification; it was analyzed on macOS 26 (25G83).

The main keys used for the forecast are:

| Key | Meaning | Shape |
|---|---|---|
| 4 | Host writes | One value (provisional 4 KiB units) |
| 18 | NAND writes | One value (provisional 4 KiB units) |
| 34 | Power-on hours | One value |
| 124 / 503 / 125 | Minimum / average / maximum P/E | Two values (TLC, pSLC) |
| 943 / 942 | TLC / pSLC P/E limit (EOL) | One value |
| 49 / 50 / 129 | Page size; TLC / pSLC pages per block | One value |
| 52 / 85 / 86 | Total virtual blocks; start of the pSLC (Intermediate) and TLC (User) domains | One value |

Domain size is block count × pages per block × page size. On the 256 GB reference Mac, TLC is 642 blocks (about 258.5 GB) and pSLC is 79 blocks (about 10.6 GB).

### When the values are trusted

Because the interface is private, several checks are layered:

- **SMART check on every read:** Host writes must be within 1% or 5 GB, whichever is larger, of SMART from the same device within 24 hours. The P/E limits must be finite and positive, and average P/E must be consistent with maximum P/E. NAND writes are checked with a wide margin that catches only unit mistakes: a read fails if NAND writes are less than half of Host writes, or, when capacity × average P/E is at least 1 TB, outside 0.5–2× that value (on the reference Mac, NAND/Host is about 1.59 and the ratio to capacity × average P/E about 1.01). When earlier comparison data exists, the change in the Power On Hours offset must be within 2 hours plus the capture-time difference. A failed read is not saved and stops automatic collection. Missing data for the Host check, or a mismatch against SMART older than two minutes, only defers saving; missing POH data waits for the supplementary comparison.
- **Supplementary checks and residuals:** controller/SMART wear, pSLC wear and the P/E ratio are shown in Research under the read values and raw data/Residual. Differences in definition or rounding alone do not stop saving. The existing D7 checks, lifetime/interval residuals and raw increments of internal activity are shown alongside. See [cross-validation](DIRECT_FTL_CROSS_VALIDATION.en.md). These checks do not guarantee the meaning of every private key or retention capability.
- **Conditions for automatic collection**
  - Only internal Apple SSDs on Apple Silicon are targeted. In addition to the reviewed macOS versions (26 and 27), automatic FTL `all` reads are also attempted on macOS 14 and 15 assuming compatibility. The ABI and key meanings on 14 and 15 are not declared verified.
  - On other macOS versions, automatic collection starts for that Mac and major version after a manual read passes the SMART check. On 14 and 15, a passing check is also recorded as "checked against SMART on this Mac", but this does not mean every key's meaning has been verified. Coverage has not been confirmed on every supported Mac model.
  - After an automatic read fails, NenRing waits for the configured interval and stops after three consecutive failures. A check mismatch stops collection immediately and revokes the local validation record. A saved manual-only preference is not overridden, and collection never starts an administrator read or sysdiagnose on its own.
- **Boundary checks:** across macOS and firmware updates, NenRing checks that values continue across the update ([boundary details, Japanese](INSTRUMENT_BOUNDARY_CONTINUITY.md)). Counter continuity does not validate the meaning of research keys or retention capability.

### Checking in Terminal

There is no standard command for reading FTL statistics. The probe bundled with the app can be run directly:

```bash
/Applications/NenRing.app/Contents/Resources/ASPProbes/asp-ftl-stats-probe --kind all
```

On an unreviewed macOS build it does not run unless `--allow-unreviewed-build` is given. With `--output-dir` set to a folder that other users cannot write to, the captured data is saved there.

> **Caution:** this calls the same Apple private interface as the app. It only reads, but Apple does not support the interface, and it may change with macOS updates. Running it on an unreviewed macOS is at your own risk. A manual probe result is not proof that automatic monitoring or forecast admission succeeded.

## snapshot probe (research)

`asp-snapshot-probe` is a research probe that reads a diagnostic snapshot through another controller entry point (user-client selector 9). It has two kinds, header (0x91) and body (0x16); the format of neither has been confirmed. It is used only when run manually from Settings and is never used for the endurance forecast. Controllers are looked up as `AppleANS2NVMeController` and its subclasses, and header reads have been confirmed on the macOS 27 `AppleANS3CGv2Controller`.

The former tunnel probe (0x106, 0x129, 0x12b) was removed because it always required administrator rights and mostly failed.

## asptool log (optional)

`asptool_snapshot.log`, written by Apple's `asptool` and included in sysdiagnose, can be imported for research. NenRing never runs `asptool` or sysdiagnose itself.

- **Import:** in Settings → Research, use **asptool log comparison** to choose the log, a sysdiagnose `.tar.gz` or an expanded sysdiagnose folder. Only `ASPSnapshots/asptool_snapshot.log`, plus `sw_vers.txt` and `SystemProfiler/SPNVMeDataType.spx` for checking the source, are extracted from an archive. The log is saved in `~/Library/Caches/io.github.mugisk.NenRing/asptool-imports/`, and a `-asptool_source.json` file next to it keeps the macOS build, macOS version, internal SSD model and firmware, and the log's output time. The SSD serial number is not kept. The archive itself is unchanged. Extraction stops after 180 seconds or when the extracted files exceed 512 MiB, and **Cancel** stops it while it runs. Partly extracted files are removed in every case. Do not share a whole sysdiagnose archive, which also contains system logs, the process list and network state.
- **Creating a sysdiagnose:** **Run in Terminal…** starts `sudo sysdiagnose` in Terminal. The password (or Touch ID, depending on settings) is entered and confirmed in Terminal; NenRing never handles it. When it finishes, Finder shows the output file. NenRing waits for a new archive in `/private/var/tmp`, confirms it has been fully written and then loads it automatically. Waiting ends after 30 minutes; afterwards, **Load from Latest sysdiagnose** loads it by hand.
- **Comparison:** a Direct FTL read at the same time as the log is compared directly. Host and NAND writes and power-on hours are interpolated only when the two surrounding reads are no more than 48 hours apart, share the device, key map, firmware and units, have no decreasing cumulative counters or P/E, and are both admitted to the current continuity lane. With a read on one side only, it must be within 24 hours and admitted to the continuity lane. A series change, a decrease or an excessive gap defers the comparison, and P/E and EOL are not reported as comparison values. Results appear under Research → **Raw data**.
- **Verdict:** the comparison is **Matched within the criteria** when every compared value meets these limits: Host and NAND writes within ±0.1%, Power On Hours within ±1 hour, TLC and pSLC average P/E within the surrounding Direct FTL values, and EOL exactly equal. Without Direct FTL reads on both sides and without one within 30 minutes, or when a compared value or the Direct FTL macOS build or firmware is missing, the result is "Cannot judge".
- **Time source:** a log extracted from an archive uses the output time recorded in the archive (when asptool wrote the log), which copying or moving the archive does not change. A log read on its own uses its file modification time, which can change when the file is copied, so it is judged only when it lies between two Direct FTL reads.
- **Source:** separately from the numbers, NenRing checks whether the macOS major version and SSD firmware lineage (the leading number; 591 and 591.40.3 are the same lineage) in the log's own sysdiagnose, read from `sw_vers.txt` and `SPNVMeDataType.spx`, match the Direct FTL read, and shows "Matched", "Not confirmed" or "Mismatch". A log read on its own or from an expanded folder, or a sysdiagnose without these files, is "Not confirmed". A mismatch makes the result "Cannot judge".
- **FTL read during comparison:** when the imported log is no more than 30 minutes old, NenRing takes one Direct FTL read before comparing. This read is handled like a manual read and is saved only if it passes the SMART check.
- **Record of checked environments:** an environment whose numbers matched within the criteria and whose source also matched is recorded as checked on this Mac, one record per macOS major version and firmware lineage (for example macOS 27 · 591), and shown in Settings. Each record shows the macOS build, firmware and log date of the latest confirmation. Nothing is recorded while the source is not confirmed. It is also included in the diagnostic report, which receives only the macOS build, macOS version, firmware and log date, not the log contents. A mismatch on a log from the same source removes the record. Records can be deleted one by one in Settings, and a deleted record is not added back when the same log gives the same result again. Records are kept in the app preferences, not in the measurement history files. They are informational only and do not affect whether automatic Direct FTL collection is allowed, the list of reviewed builds or the forecast.
- **Input limits:** 1 MiB per line and 512 MiB per file. An overlong line or oversized file stops the import with the reason shown. The original is unchanged.
- **Not used for forecasts:** imported logs do not enter the forecast, WAF or wear series. asptool data imported by earlier versions is treated the same way.

## From acquisition to forecast

1. **Storage:** values are saved under `~/Library/Application Support/NenRing/`.
   - `history.jsonl`: SMART
   - `temperature-history.jsonl`: temperature and the read/write byte counts read with it
   - `asptool-snapshots.jsonl`: FTL
   - `usage-settings.json`: usage settings
   - `ASPDirectProbes/`: probe captures (successful scheduled captures are deleted after parsing; failed ones are kept for review)
   - `history.lossless/`, `temperature-history.lossless/`, `asptool-snapshots.lossless/`: sealed observation blocks and their manifests
   - `archive/`: records thinned by older versions (restored during migration to the new format)

   Unreadable lines are not discarded; they are moved to a separate file (`*.rejected-*.jsonl`). If unreadable lines outnumber readable ones, the file is not rewritten: it is kept as is, renamed to `*.unreadable-<UTC time>.jsonl`, and a new file starts from the readable lines only. This keeps most of the history from moving into base64 rejection files when, for example, an older version opens a file in a newer format.

   **Lossless history grouping:** SMART, temperature and FTL observations are grouped into blocks of up to 256, with shared values stored once and then compressed. IDs, timestamps and changed values all remain, and statistics receive the original series. Old observations are never replaced with daily or average values for storage; point reduction for charts is separate.

   - `.jsonl` files hold the most recent appends. Sealed records move to `.lossless/`. Back up the whole directory, including `.lossless/`, not just the `.jsonl` files.
   - Each compressed block is read back and checked against all observations, and its SHA256 is recorded. Normal appends do not rewrite the past history.
   - The JSONL from before the first migration is kept as `*.pre-lossless-v1.jsonl`. Records in the old `archive/` are also restored, and the original archive is unchanged. Old daily temperature summaries are excluded from analysis input when the original observations can be restored.
   - Older versions of the app may not read the new format. See [lossless storage](LOSSLESS_HISTORY_STORAGE.en.md) for recovery steps, the format and its cost.
2. **Continuity:** NenRing checks whether readings across macOS, firmware and acquisition-path changes can be treated as the same instrument.
3. **Write amplification (WAF):** FTL NAND writes ÷ Host writes. The lifetime value and the recent value are combined for the forecast.
4. **Forecast:** remaining TLC and pSLC P/E are converted to Host writes. The domain that runs out first sets the limit, which is converted to years at the write rate of the complete saved history ([NAND model, Japanese](NAND_MODEL_V2_4.md)).

When FTL is unavailable, a provisional estimate is made from SMART Percentage Used and Host writes, or from a reference TBW ([reference TBW, Japanese](REFERENCE_TBW.md)).

## What the app does not do

- Change SSD settings or operate on firmware while reading statistics (saving history and settings is separate)
- Brute-force arbitrary functions or opcodes
- Send measurements, serial numbers or similar data without the user's permission
- Request administrator authentication without a user action

Even when these checks pass, research limitations remain: reads through a private interface, inferred topology, provisional units and transfer to other Mac models.
