# Documentation

[日本語](README.md) · [Project README](../README.md)

This index and the seven entry documents below are available in English and Japanese. The project [README](../README.md), [contribution guide](../CONTRIBUTING.md), [security policy](../SECURITY.md) and [third-party notices](../THIRD_PARTY_NOTICES.md) also have both versions. Existing Japanese paths are unchanged, and English file names use the `.en.md` suffix. Detailed research specifications are Japanese-only for now and are marked "(Japanese only)" below. Documents that describe current behavior are kept apart from records of past designs and reviews.

## Start here

- [Reading the endurance forecasts](FORECAST_GUIDE.en.md): the difference between actual use, retention-aware, client workload and reference baseline; totals, remaining amounts, dates and confidence.
- [Data acquisition](DATA_ACQUISITION.en.md): SMART, IORegistry, Direct FTL and live disk I/O; read intervals, permissions and commands for checking.
- [Direct FTL cross-validation](DIRECT_FTL_CROSS_VALIDATION.en.md): checks before saving, and the difference between read values and forecast inputs.
- [Diagnostic reports from other Macs](DIAGNOSTIC_REPORTS.en.md): shared fields, handling of personal information and the reporting steps.
- [Lossless history storage](LOSSLESS_HISTORY_STORAGE.en.md): what to back up, recovery and memory behavior.
- [ASP probe signature checks](PROBE_SIGNATURE.en.md): checks before launch and the limits of ad-hoc signing.

## Detailed specifications

- [Binding disks to acquisition targets](STORAGE_TARGET_BINDING.md) (Japanese only): fixing the SMART, FTL and NAND targets, deferral for multiple candidates and namespaces, and the scope of diagnostic reports.
- [NAND Model v2.4.1](NAND_MODEL_V2_4.md) (Japanese only): the current forecast calculation and the conditions for reading Direct FTL.

## Endurance forecasts

- [Forecast evidence and dashboard roles](ENDURANCE_FORECAST_EVIDENCE_PLAN.md) (Japanese only): reach dates, WAF periods and handling of free space.
- [Forecast calculation architecture](ENDURANCE_CORE_ARCHITECTURE.md) (Japanese only): the components that share the calculation.
- [Reference TBW and workload assumptions](REFERENCE_TBW.md) (Japanese only): the dashboard's comparison baseline, the provisional estimate when FTL data are insufficient, and their sources.
- [Retention research estimate](RETENTION_RESEARCH_ESTIMATE.md) (Japanese only): the "retention-aware" row and research diagnostics for retention.
- [Forecast display terminology](FORECAST_UI_TERMINOLOGY.md) (Japanese only): short labels, levels of explanation and how research assumptions are explained.

## FTL time series and continuity

- [Instrument boundary continuity](INSTRUMENT_BOUNDARY_CONTINUITY.md) (Japanese only): checks across macOS, firmware and acquisition-path updates, and the rules for excluding data from learning.
- [Direct FTL time-series analysis](FTL_TIME_SERIES_ANALYSIS.md) (Japanese only): interval differences and handling of residuals.
- [Long-baseline NAND residuals](FTL_LONG_BASELINE_RESIDUAL.md) (Japanese only): reconstruction residuals over long periods.
- [Direct FTL cross-validation](DIRECT_FTL_CROSS_VALIDATION.en.md): the SMART cross-check on every read, supplemental comparisons and handling of residuals.

## Screens

- [Dashboard reliability indicators](DASHBOARD_RELIABILITY_INDICATORS.md) (Japanese only): the scope and limits of showing SMART warnings, abnormal FTL counters (internal errors), retention work and its pace, and the light check separately.
- [Reading the writes chart](WRITE_GRAPH_DOMAIN_DISPLAY.md) (Japanese only): Host and NAND increments and totals, estimated TLC/pSLC writes, and WAF by period.

## Hardware and security

- [Apple Silicon internal SSD hardware](APPLE_SSD_HARDWARE.md) (Japanese only): controllers and NAND per model as known from public information, and the items diagnostic reports could fill in.
- [ASP probe signature checks](PROBE_SIGNATURE.en.md): checks before a probe is launched.
- For the security approach, see the [security policy](../SECURITY.md).

## History storage and memory

- [Lossless history storage](LOSSLESS_HISTORY_STORAGE.en.md): a storage format that keeps every observation, migration from older history, recovery and backup scope.

## Development, publishing and distribution

- [Diagnostic reports from other Macs](DIAGNOSTIC_REPORTS.en.md): acquisition, sharing, maintainer-side checks and privacy constraints.
- [English UI terminology and implementation policy](UI_LOCALIZATION.md) (Japanese only): labels, units, dates and times, and compatibility when extending the Japanese UI to English.
- [Menu bar popup appearance](MENU_BAR_APPEARANCE.md) (Japanese only): applying appearance settings while retaining native menu corners and shadows, and checking the rendered result.
- [Building the release and first launch](RELEASE.md) (Japanese only): building the DMG, what the release page states, and what the first-launch check found.

The authoritative license text is the MIT [LICENSE](../LICENSE). The [icon and logo license](../Resources/NenRingIcons/LICENSE.md) is defined separately.
