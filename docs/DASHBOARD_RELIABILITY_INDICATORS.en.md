# Dashboard reliability indicators

[日本語](DASHBOARD_RELIABILITY_INDICATORS.md) · [Documentation](README.en.md)

The dashboard shows SMART warnings, internal errors, retention work and changes in its pace. Light check can notify you about new findings. These indicators describe observations. They do not estimate the probability of failure.

## Internal errors and retention work

On the **Internal errors & retention** page, internal errors are abnormal FTL counter events. Retention work includes refresh, padding and read verification. The following interpretations are inferred from the counter names and typical NAND behavior. They have not been confirmed on hardware. Research and Raw data retain the original names for comparison.

| Counter | Display name | Inferred meaning |
|---|---|---|
| Age refresh | Rewrites as data ages | Times the SSD rewrote aging data to preserve it |
| Background refresh moves | Background moves | Times the SSD moved data to another location on its own |
| Bands padded for age | Closing partly written areas | Number of aging, partially written bands that the SSD padded and closed |
| Reduced read verify native | TLC read verification (reduced) | The meaning of “reduced” is unconfirmed |

| Indicator | Inputs | Interpretation |
|---|---|---|
| S.M.A.R.T. | Critical Warning, Available Spare and its threshold, Media/Data Errors, overall assessment | The card uses the SMART warning rules. Individual warnings take precedence over PASSED. All reasons are available separately from FTL findings. |
| Internal errors | UECC, cross-temperature UECC, Host/GC read-verify failures, grown bad blocks, die failures | Increases in comparable counters in the same series. Some record an error that has already occurred. |
| Retention work | Age/background refresh, band padding, native/pSLC read verify | Shows how many counters increased and their raw deltas. An increase alone cannot establish a failure, insufficient refresh or low ECC margin. |
| With retention | Assumed storage temperature and duration, maximum TLC P/E and modeled allowable P/E | Reaching an assumed limit. Actual retention and powered-off temperature have not been measured. |
| Monitoring deferred | Pfail/Efail, error refresh, open-band read fail, offline blocks | Mapping keys to named fields is incomplete. Missing values remain unavailable. |

The Internal errors card counts checks and retention-work counters that increased. A count of counters can differ from the number of events. Past events are labeled as recorded. The information button shows the comparison interval, each counter's delta and the date of the last recorded event separately. Without comparable history, the card shows **Awaiting comparison**, a short reason such as an unreviewed research key map, and a fuller explanation on hover.

Research keys were checked against hardware on build 25G83. On other builds, scalar UECC, read-verify failure, grown bad block and die failure counters can be compared provisionally if the key map and acquisition format are compatible and the shared core continuity checks accept the history. The card and history identify provisional comparisons. New events can store the runtime build, mapping build and provisional status. Older events retain their original metadata.

An increase has no upper cutoff. A decrease suspends comparison for that counter. A reset in Host writes, NAND writes or power-on hours, or an unverified boundary, suspends the interval. Unknown maps and incompatible formats cannot be compared. The parser treats malformed shapes, duplicate keys and missing values as unavailable. Histograms, refresh metrics and research correlations still require a matching runtime build. A provisional comparison cannot confirm semantics or reliably detect a key reassigned to another monotonically increasing counter.

The SMART information button shows every warning reason, overall status, raw Critical Warning, Available Spare and threshold, cumulative Media/Data Errors and acquisition time. Missing values stay unavailable. A cumulative error count may include earlier events. FTL details present possible signs of trouble with failure prediction deferred. Expand the latest raw values for UECC, cross-temperature UECC, Host TLC/pSLC verification failures and age/background refresh. No failure probability, replacement deadline or TBW multiplier is derived.

NenRing does not collect corrected ECC counts, correction limits or internal RBER. UECC records uncorrectable reads and cannot measure remaining correction margin. Factory bad blocks, Unsafe Shutdowns and Percentage Used alone do not establish failure probability.

The display reads cached analysis. It retains the collection interval, privileged collection path, mapping and boundary checks, history format and forecast multipliers. When an OS, firmware or mapping boundary prevents comparison, it shows the reason and skips the delta across that boundary. Retention pace also uses only consecutive, comparable snapshots.

## Retention pace

NenRing compares the last 14 days with the preceding eight weeks (up to 56 days). Retention work often occurs in batches several days apart, so a single batch can dominate a seven-day window. Background moves, age rewrites and bands closed are normalized per 24 powered-on hours. Reduced TLC read verification is normalized per million NAND reads. Only consecutive, comparable pairs qualify. Pairs containing a reset and intervals overlapping research sessions are excluded.

A metric has an elevated pace only when **all three** conditions hold:

1. Its recent rate is at least twice the baseline rate.
2. It exceeds twice the highest weekly rate across the seven-day baseline segments.
3. Its observed count exceeds the expected count by at least three Poisson standard deviations, calculated as `3 × √max(expected, 1)`. The expected count uses the baseline rate and recent exposure.

History is insufficient with fewer than 12 recent powered-on hours, fewer than 48 baseline powered-on hours, or fewer than four baseline weeks with at least 12 powered-on hours each.

An elevated pace means more retention activity. It does not diagnose data loss, exhausted ECC margin or drive failure, or alter endurance forecasts, TBW multipliers or sampling. The dashboard identifies elevated metrics or counts those in the usual range. The detail page shows recent and baseline rates, ratios and powered-on hours for each metric.

## Light check

In Settings, select Off (default), every collection, daily or weekly. Enabling Light check requests notification permission. Settings shows when permission is unavailable.

The check examines Critical Warning, increases in Media/Data Errors and error-log entries, FTL events recorded since the last check and newly elevated retention pace. Repeated findings do not trigger another notification. The first check establishes baselines for media errors, the error log and FTL events. It can report Critical Warning and elevated pace immediately. Selecting another drive establishes new baselines. Checks read cached analysis and previously collected values without polling the SSD. The app saves check records in its settings and shows the last time and result in Settings and on the detail page's pace card.

## Reference baseline

The [reference TBW calculation](REFERENCE_TBW.en.md) selects a retail comparison by NAND vendor, generation and logical capacity. It replaces the fixed 250 TB reference. An M1–M5 SoC name alone cannot identify NAND. Unknown NAND uses a labeled default of 600 TBW/TB. Remaining writes equal reference total minus the Host counter accepted for the forecast. This figure provides neither an Apple rating nor a lower bound on actual endurance.

## Validation scope

Automated tests cover model/capacity selection, unknown NAND, missing capacity, remaining writes and dates, reaching the assumed retention limit, indicator labels and FTL zero deltas, missing data and resets. Pace tests cover usual and elevated rates, busy weeks, insufficient history, resets and research-session exclusions. Light check tests cover baselines, duplicate notifications, a different drive's critical warning, scheduling and record persistence. These tests do not induce hardware faults, retention loss or ECC exhaustion. Visual checks and validation of early-warning behavior on hardware require separate observations.
