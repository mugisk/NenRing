# Documentation

[日本語](README.md) · [Project README](../README.md)

This index and the seven entry documents below are available in English and Japanese. The project [README](../README.md), [contribution guide](../CONTRIBUTING.md), [security policy](../SECURITY.md) and [third-party notices](../THIRD_PARTY_NOTICES.md) also have both versions. Existing Japanese paths are unchanged, and English file names use the `.en.md` suffix. Detailed research specifications are Japanese-only for now and are marked "(Japanese only)" below.

## Start here

- [Reading the endurance forecasts](FORECAST_GUIDE.en.md): the difference between actual use, retention-aware, client workload and reference baseline; totals, remaining amounts, dates and confidence.
- [Data acquisition](DATA_ACQUISITION.en.md): SMART, IORegistry, Direct FTL and live disk I/O; read intervals, permissions and commands for checking.
- [Direct FTL cross-validation](DIRECT_FTL_CROSS_VALIDATION.en.md): checks before saving, and the difference between read values and forecast inputs.
- [Diagnostic reports from other Macs](DIAGNOSTIC_REPORTS.en.md): shared fields, handling of personal information and the reporting steps.
- [Lossless history storage](LOSSLESS_HISTORY_STORAGE.en.md): what to back up, recovery and memory behavior.
- [ASP probe signature checks](PROBE_SIGNATURE.en.md): checks before launch and the limits of ad-hoc signing.

## Forecast basis (Japanese only)

- [NAND Model v2.4.1](NAND_MODEL_V2_4.md): the current forecast calculation and the conditions for reading Direct FTL.
- [Reference TBW and workload assumptions](REFERENCE_TBW.md): the dashboard's comparison baseline, the provisional estimate when FTL data are insufficient, and their sources.
- [Retention research estimate](RETENTION_RESEARCH_ESTIMATE.md): the "retention-aware" row and research diagnostics for retention.

## Screens

- [Dashboard reliability indicators](DASHBOARD_RELIABILITY_INDICATORS.md) (Japanese only): the scope and limits of showing SMART warnings, abnormal FTL counters (internal errors), retention work and its pace, and the light check separately.

## Hardware and security

- [Apple Silicon internal SSD hardware](APPLE_SSD_HARDWARE.md) (Japanese only): controllers and NAND per model as known from public information, and the items diagnostic reports could fill in.
- For the security approach, see the [security policy](../SECURITY.md).

The authoritative license text is the MIT [LICENSE](../LICENSE). The [icon and logo license](../Resources/NenRingIcons/LICENSE.md) is defined separately.
