# Diagnostic reports from other Macs

[日本語](DIAGNOSTIC_REPORTS.md) · [Documentation](README.en.md)

This page describes how to share a diagnostic report, which helps investigate acquisition on other Mac models, capacities and macOS versions, and how maintainers review it. A workload test or sysdiagnose is not required to submit a report.

## Share a report

1. Perform a normal SMART read. smartmontools is required.
2. Open Settings → General → Application → Diagnostic report → Share…. In the Japanese UI this is 設定 → 一般 → アプリ → 診断レポート → 提供する….
3. Save the JSON using Save…. Its name is `nenring-report-<UTC date>-<model ID>.json`.
4. Inspect it and remove usage or configuration information you do not want to share.
5. Choose Open an issue on GitHub, which opens an issue from the Diagnostic report template with the model ID, capacity and macOS build in the title. Drag the file into the Diagnostic report field, check the required Sharing review box and submit. Attachments to an issue in a public repository are public too, so submit only what you agree to share.

The app only opens the issue page; it never uploads the file.

A report is useful even without Direct FTL. Do not fill missing values with zero. If acquisition failed, describe what the screen showed and how to reproduce it. Do not repeat administrator authentication for the sake of a report.

## Included information and privacy

Schema version 3 includes the Mac model, CPU, OS build, app revision, SSD model/firmware/logical capacity, `smartctl` version and exit status, SMART usage counters, temperature, available NAND configuration, an FTL summary, observed instrument combinations and the environments checked against an asptool log (macOS build, macOS version, firmware and log date). Timestamps are reduced to UTC days. Checked environments can be deleted in Settings → Research; deleted records are not included. Schema version 3 differs from version 2 only by adding the checked environments.

The FTL summary includes only records whose device ID matches the selected SMART device. Records with an unknown device and FTL history when SMART is unavailable are omitted. Original history is preserved.

The report contains no serial numbers, device IDs or device paths, and the app never sends it automatically. Nevertheless, the combination of model, configuration and usage can help identify a unit, so the report is not described as completely anonymous. Do not attach raw SMART JSON, probe captures, full sysdiagnose archives or logs in addition to the report.

For environments checked against an asptool log, the report contains only four items: macOS build, macOS version, firmware and log date. The contents of `asptool_snapshot.log` are not included. The log holds thousands of lines of internal SSD counters, such as write totals, P/E, bad blocks, RAID recovery statistics, write cache histograms and boot times after unclean shutdowns, which amount to a detailed usage history. It does not need to be attached to an issue; if you share it for another purpose, review its contents first. Do not share a whole sysdiagnose archive, which also contains system logs, the process list and network state. NenRing copies only `asptool_snapshot.log` out of the archive.

## Reviewing a report

- Check the app revision and schema; do not assume an unknown schema is the current one.
- Distinguish internal Apple SSDs from external devices. Never associate an internal SSD's FTL with external SMART.
- Check the runtime build, contract build, provenance, firmware, controller, geometry and unit state separately.
- SMART and FTL cumulative values are read at different times. Do not demand an exact match; check the evidence from the existing cross-validation and boundary checks.
- A single report is an acquisition example, not evidence of long-term continuity, P/E progression or retention.
- Record unknown hardware and formats as unconfirmed. The number of reports alone does not promote a key table to confirmed.
- Ask contributors only for the minimum additional information. Workload tests, unknown-opcode scanning and sysdiagnose are not part of the standard reporting procedure.

See `DiagnosticReportBuilder` for the implementation and `DiagnosticReportTests` for the compatibility and personal-information exclusion checks.

The tests also confirm that a report without SMART or FTL keeps missing values missing, and that internal FTL history with a different ID from the selected external device does not appear in the output. The device ID is used only for matching and is not written to the report. These checks use synthetic input and do not guarantee that acquisition succeeds on another Mac model.
