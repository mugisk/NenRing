# NAND Model v2.4.1 — Direct topology, residuals and internal FTL events

[日本語](NAND_MODEL_V2_4.md) · [Documentation](README.en.md)

Updated 2026-10-02. Scope: NenRing's research endurance estimate for Apple Silicon SSDs.

## v2.4.1 review revisions

This compatible update revises how v2.4 interprets inputs. On build 25G83, keys 327–331 are opaque histograms:

| Key | Normalized name |
|---|---|
| 327 | `bandsMaxTempHistogram` |
| 328 | `bandsMinTempHistogram` |
| 329 | `bandsLifetimeTempHistogram` |
| 330 | `bandsDeltaTempHistogram` |
| 331 | `bandsCrossTempHistogram` |

Preserve bin indices without converting them to temperatures, reclassifying them as read retries or assuming cumulative histograms. Old JSON keys such as `readTemperatureHistogram` are decode-only aliases. New records use the v2.4.1 names. This preserves storage compatibility without validating old readings under a new interpretation.

Retain the original acquisition time, build and contract version. Missing arrays in an older record stay missing even when a current snapshot has them. Keep legacy values for diagnostics and comparison, outside the current semantic mapping and TBW, WAF or retention adjustment. A change to the research contract alone does not split the core wear series. Research deltas require compatible contracts. See [Data acquisition](DATA_ACQUISITION.en.md).

At acquisition, a Direct FTL snapshot can store `deviceID`, firmware epoch, source build, firmware, MSP version and chip ID. Missing context remains nil. IORegistry values from a different time cannot fill it. Acquisition eligibility uses the major macOS version with a SMART cross-check on each read and continuity checks at update boundaries. The UI labels unverified research keys.

`retentionDays` specifies a future powered-off requirement, default 365 days. Off-equivalent exposure inferred from SMART Power On Hours is saved separately as an observation. For pSLC, use the observed controller EOL and a central retention factor of 1.0. Do not transfer the TLC curve or ratio. For WAF components, display a negative residual within 0.5% of the total as zero to allow for rounding and acquisition timing. Component accounting does not feed back into forecast WAF.

## Purpose

Version 2.4 builds TLC and Intermediate pSLC write budgets from reviewed partition boundaries in `FTL all`. It combines the interpretation of a private buffer reviewed on 25G83 with P/E and Host/NAND counters observed on this Mac. It establishes neither an Apple TBW rating, JEDEC compliance, independently verified physical capacity, failure probability nor guaranteed retention.

The earlier estimate of 80 pSLC bands inferred from cumulative NAND and P/E remains available in Research as a consistency comparison. It supplies no input to the central forecast, remaining Host writes or projected date.

## Acquisition and interpretation

The semantic parser extracts interpreted values only from a timestamped `FTL all` artifact matching the reviewed `GetNVMeSMARTInterface` plugin/interface UUIDs, the verified vtable offset for `all`, the expected response size and record mapping. Distinguish the acquisition and parsing contract from the runtime build. macOS 26 and 27 are reviewed runtime environments. Versions 14 and 15 are provisional automatic-collection targets. Extraction uses the UUID/vtable/record map interpreted on 25G83 (`DirectFTLContractRegistry.reviewed25G83`). An unverified runtime retains that designation.

On every read, `DirectFTLReadCrossCheck` requires FTL Host writes to agree with SMART within the greater of 1% and 5 GB, positive EOL P/E and average P/E no greater than maximum. A mismatch prevents saving and stops automatic collection. A read missing necessary comparison data is also withheld. Automatic collection is limited to Apple internal SSDs on Apple Silicon. macOS 14/15 start in `compatibilityTrial`. On other unreviewed versions a successful manual read and SMART cross-check can enable `locallyVerified` collection. Success on 14/15 is also recorded as local verification without validating research key meanings. Automatic collection uses the SMART interval (default 10 minutes, adjustable from five minutes to one hour). The configured delay still applies after a failure. Preserve manual-only settings.

Other interfaces, `perm` and unknown layouts do not produce semantic values under this map. Core values extracted on an unverified runtime may be displayed provisionally. Saving and admission to a forecast use the read cross-check and a separate continuity check. Interpret research telemetry separately from runtime mapping review. Routine monitoring does not automatically revalidate, invoke sysdiagnose or request additional privileged reads. The former 0x106 tunnel probe was removed. Saved tunnel artifacts can still be analyzed manually.

Scalar zero is a valid observation. Missing fields, wrong scalar/pair/array shape, duplicate keys and oversized arrays yield nil and a warning. Validate `min <= avg <= max`. Reaching or exceeding EOL is a valid P/E reading; the domain's remaining budget then becomes zero.

Keep the raw record sequence only while parsing. Store normalized optional values losslessly in existing ASP history. Read old JSON with absent optional fields without backfilling contemporary topology or events.

## 25G83 key map

This table covers only reviewed private records. Unless specified, raw units have no public definition.

| Key | Shape | Normalized value or use | Units or evidence |
|---|---|---|---|
| 4 / 18 / 19 | scalar | Host writes / NAND writes / NAND reads | 4 and 18 provisionally use 4 KiB from near-simultaneous asptool readings. 19 is raw. |
| 20 / 34 | scalar | Band erases / power-on hours | Raw / hours |
| 46 / 47 | scalar | Factory / grown bad blocks | Raw counters |
| 49 / 50 / 129 | scalar | Bytes/page, native pages/block, pSLC pages/block | Direct geometry |
| 52 / 85 / 86 | scalar | Virtual blocks, Intermediate start, User start | Direct topology |
| 84 | scalar | Intermediate erases | Raw, accumulation scope unconfirmed |
| 124 / 503 / 125 | pair | TLC/pSLC minimum, average, maximum P/E | Verify min ≤ avg ≤ max |
| 942 / 943 | scalar | pSLC / TLC controller EOL P/E | Positive P/E reference |
| 93 | array (max 64) | Age refresh tiers | Raw, compare array lengths too |
| 97 / 112 | scalar | Background refresh moves / bands padded for age | Raw |
| 327–331 | array (max 1024) | Bands max/min/lifetime/delta/cross-temperature histograms | Store bin indices |
| 340 / 343 / 414 | scalar | Cross-temp UECC / utility UECC / UECC reads | Reliability evidence |
| 422 / 423 / 424 | scalar | Native / reduced native / pSLC read verify | Recovery evidence |
| 427 / 461 / 462 / 485 | scalar | Direct→TLC / waterfall write path | Raw display only |
| 659 / 953 | scalar | RAID verification reads / cross-temp RAID UECC | Raw / reliability evidence |
| 1050–1053 | scalar | Host/GC pSLC/TLC read-verify failures | Reliability evidence |
| 349–352, 430–433, 531–532, 561, 565, 707–708 | scalar | Existing internal ASP statistics | Raw fields cross-checked against asptool labels |

The keys for `numPfail`, `numEfail`, Host write composition and individual RAID components remain unmatched. Show that state without assigning zero, a normal status or a TBW adjustment.

The additional audit exposes whether keys 5, 6 and 27 exist as scalars in a Direct FTL artifact. Save candidates as raw values in `ASPToolDiagnosticsSnapshot` and compare their summed deltas with key 4 Host Writes within the same series. Repeated checks against contemporaneous asptool labels, deltas and sum invariants are needed before assigning the names `hostWritesDyn`, `hostWritesStatic` and `hostWritesMeta`. Exclude candidates from Host writes, WAF and endurance forecasts.

The 25G83 key numbers for `numPfail`, `numEfail`, `bandsRefreshedOnError`, `openBandReadFail` and `offlineBlocksCnt` have not been matched to named asptool fields. Keep them unmatched in Research without guessing keys or filling zeros.

For histograms, show bin count, mean bin, P50/P90/P99 and last nonzero bin. Distinguish empty arrays from nonempty arrays containing only zeros. The `tailFraction` at or above a user-selected start bin is a research statistic with no alert threshold or endurance multiplier.

## Central forecast from direct topology

Use the following when direct topology is present, geometry products are positive and available contemporaneous IORegistry geometry shows no clear inconsistency:

```text
Intermediate bands = userPartitionStart - intermediatePartitionStart
TLC bands          = numVirtualBlocks - userPartitionStart

TLC band bytes     = bytesPerPage × pagesPerVirtualBlock
pSLC band bytes    = bytesPerPage × pagesPerVirtualBlockSlc

TLC capacity        = TLC bands × TLC band bytes
pSLC writable cap.  = Intermediate bands × pSLC band bytes
pSLC physical space = Intermediate bands × TLC band bytes
```

Show pSLC writable capacity and TLC-mode physical occupancy separately. Endurance uses writable capacity. `topologyContractValidated=true` verifies keys and shapes against the 25G83 map. Independent physical allocation remains unverified (`physicalCapacityAllocationVerified=false`).

The 25G83 fixture has `numVirtualBlocks=722`, `intermediateStart=1`, `userStart=80`: **79 Intermediate pSLC bands and 642 TLC bands**. At 16,384 bytes/page, 24,576 native pages and 8,192 pSLC pages, each band is respectively 384 MiB and 128 MiB. These are fixture values, not constants across builds.

### Budgets and retention

```text
TLC target P/E  = TLC controller EOL × Kret  (central forecast: Kret = 1)
pSLC target P/E = pSLC controller EOL

domain baseline budget = domain capacity × domain controller EOL
domain used            = domain capacity × current average P/E
domain remaining       = domain capacity × max(0, target P/E - current average P/E)
remaining NAND         = Σ domain remaining
```

Kret is a research derating factor derived from the configured storage duration and temperature, capped at 1. Apply it only to TLC in the research budget. Without an independently verified pSLC curve, use 1 for pSLC. Do not compound a program-temperature adjustment into domain budgets.

### Baseline and research budgets

```text
baseline budget: Kret = 1.0
research budget: Kret from the current research retention policy
```

The central forecast uses the baseline. The **With retention** scenario assumes powered-off storage. This separation does not establish that powered-on cells experience no retention loss. Save research remaining NAND and its difference separately. Research telemetry, histogram interpretation, residual diagnostics and reliability events leave both budgets unchanged. [Retention research estimate](RETENTION_RESEARCH_ESTIMATE.en.md)

### Host and WAF counters

For both lifetime and interval WAF, use counters from the same FTL instrument:

```text
FTL WAF = FTL NAND writes / FTL Host writes
```

For historical Host writes in `total Host = historical Host + future remaining Host`, prefer standard NVMe SMART Data Units Written matched to the accepted FTL endpoint. Require the same device, readings within 24 hours, compatible firmware if known on both sides, and agreement within 10% of the FTL Host counter. Otherwise use the FTL Host counter as a labeled provisional fallback. Same-instrument units cancel in WAF. The absolute historical total can thus avoid unnecessary dependence on the provisional 4 KiB unit.

### Weight of evidence for forecast WAF

Additional SMART Host writes since the FTL input adjust dates projected from today. The input-time totals and remaining amounts stay in the table. Subtract the Host increment for Actual use, With retention and Reference. For Client workload, subtract the increment times `Forecast WAF / 3.5`, estimating the NAND consumed since input and converting to client Host units under continued domain allocation. Skip this client correction without forecast WAF. After at least two days without FTL, mark the forecast stale, including after automatic collection stops or in manual mode.

Recent WAF weighting is independent of Retention Research:

```text
q = observed Host / (observed Host + forecastWAFPriorEquivalentHostBytes)
forecast WAF = exp((1-q) ln(lifetime WAF) + q ln(recent WAF))
```

The evidence scale defaults to 1 TB. `retentionDailyWAFPriorHostBytes` controls only the prior in Retention Research.

### Converting domain budgets to Host writes

pSLC acts as a large write cache. Longer-lived data moves into TLC through folding. The domains therefore wear at different rates per Host byte. Over the reference machine's history these were about 0.66–0.67 for TLC and 0.90–0.91 for pSLC, depending on lifetime/recent weighting. Convert each domain's remaining writes into Host units and take the first to reach its target. The old method of summing before dividing by WAF could obscure a TLC limit.

```text
TLC share s = TLC NAND writes / (TLC + pSLC NAND writes)
recent s_r  = (ΔNAND − ΔpSLC average P/E × pSLC capacity) / ΔNAND
a_TLC       = forecast WAF × s
a_pSLC      = forecast WAF × (1 − s)
remaining Host (actual use) = min(remaining TLC NAND / a_TLC, remaining pSLC NAND / a_pSLC)
remaining Host (client)     = same calculation with WAF 3.5
total Host per scenario     = cumulative Host + remaining Host
```

Log-blend the lifetime share (P/E × capacity) and the recent share from the forecast WAF window using the same q. Sum deltas over pairs in that window, excluding only pairs overlapping rate-learning exclusions. Use only the lifetime share if pSLC average P/E advances by less than 50 or the pSLC contribution exceeds ΔNAND.

Remaining NAND uses Kret = 1. A Mac in everyday use spends little time in extended powered-off storage. Model that storage separately for TLC. Apply no retention derating to pSLC (reference EOL 100000). On 2026-10-17, after revising the recent share, pSLC narrowly limited the reference estimate at about 1.09 PB remaining Host.

If the share is unavailable (e.g. pSLC P/E still zero on a new Mac), sum unadjusted domain remainders and divide by forecast WAF. A suspended series after a counter reset or SMART/FTL firmware mismatch withholds all Host forecasts, including Actual use and Client. Headline wear uses cumulative Host / projected total Host as in Actual use. Without a Host forecast, use domain wear (the limiting domain if individual forecasts exist). Always use domain wear for comparisons with Percentage Used.

#### Showing TLC and pSLC together

On 2026-10-01 the reference machine showed 5.6% TLC wear and 5.5% pSLC wear, with about 1.11 and 1.12 PB Host remaining, only about 1% apart. `DomainForecastRow` places both NAND bars below the Host-based Actual use row so both remain visible.

- In NAND units, total = target P/E × domain capacity. The used amount matches that domain in the Writes composition card.
- The wear fraction uses average P/E / target P/E. Remaining NAND = (target − current average P/E) × domain capacity, without a Host conversion ratio.
- For years remaining, convert remaining NAND to Host using the corresponding a_TLC or a_pSLC, then divide by the current Host write rate.
- The smaller Host equivalent equals the Actual use remainder. Different P/E resolution makes a close ranking or reaching a reference target insufficient evidence of failure.
- Use one calculation throughout. There is no switch at 30 days. The lifetime share is available from the first eligible FTL reading. The recent share enters gradually with q once window pSLC P/E advances by at least 50.
- Use NAND writes and pSLC P/E for recent share. TLC P/E may increase by only one every few days, producing swings of tens of percent in a short window. In 7- and 14-day reference windows, the method had the same mean as the TLC-P/E estimate with less than half its scatter (2026-10-17). NAND writes include other writes, but the lifetime difference from capacity × average P/E was about 1%.
- The recent mix favored pSLC on the reference Mac. The revision shifted the limiting domain from TLC to pSLC and remaining Host from about 1.11 to 1.09 PB on 2026-10-17.
- Average TLC P/E is integer-valued and advanced about once every three days. Dates use the more continuously observable SMART Host rate.
- Hide the domain rows without FTL (SMART-only or reference-TBW estimates).

Client workload, With retention and Reference stay in Host units. Retail TBW denotes Host writes and client WAF relates total NAND to Host writes. A TLC-only conversion would need an additional allocation assumption. Since 2026-10-12, Reference uses NAND generation and logical capacity, labeling the default for unknown NAND. It gives no Apple rating. Client WAF 3–4 combines TLC and pSLC without a published split. The scenario assumes the machine's observed allocation continues. [Reference TBW](REFERENCE_TBW.en.md)

Card order: **Actual use** (with TLC/pSLC NAND bars), **With retention** (days and temperature), **Client workload** (WAF 3.5), **Reference** (selected TBW). Conditions are separate from names. Row/header information buttons give details. Select a row by `Projection.Kind` rather than its display name.

Actual use takes observation-weighted ForecastWAF. Client keeps Kret = 1 and the same Host pace, changing only future WAF to 3.5 (comparison range 3–4). With retention applies only to TLC and selects storage temperature from an explicit override, powered-on low-load observations, saved candidates or the JEDEC Client reference of 30°C. [Temperature selection](RETENTION_RESEARCH_ESTIMATE.en.md)

A domain at or above target/EOL has zero remaining. At zero write pace the date is unavailable. Without direct topology, with invalid boundaries or products, or with confirmed IORegistry geometry mismatch, fall back to the `N / u` cumulative-wear approximation labeled as lacking domain allocation. The inferred 80-band proxy never enters this fallback.

## Residuals and WAF components

Let Nknown be reconstructed usage of known domains and Nmeasured cumulative measured NAND.

```text
signed residual = Nmeasured - Nknown
current reconstruction error = |Nknown - Nmeasured| / Nmeasured
budget reconciliation error = |Direct baseline budget - (N/u budget)| / (N/u budget)
```

Do not allocate the residual to Utility/Special bands or “about one pSLC band,” or add it to the budget. Research retains the difference between the raw pSLC-equivalent band count and direct band count. Reconstruction error and agreement with the older N/u budget measure different things. A small reconstruction error cannot independently verify capacity.

Show existing WriteAmp and IntermediateWriteAmp as components reconstructed from erases and geometry:

```text
component residual = total WAF - native component - intermediate component
```

Show a negative residual within 0.5% of total WAF as zero for rounding/acquisition skew. Preserve larger negative values as inconsistencies. Component WAF, raw Direct→TLC and saved test WAF never substitute directly for ForecastWAF.

## Evidence for FTL reliability events

Compare chronological Direct FTL snapshots with matching device, artifact, build, firmware epoch, extraction/format and key map. The first observation has no comparison history. Reversed timestamps, duplicates within the same second or decreasing Host/NAND write counters start a new series and invalidate the whole interval.

A decrease in an individual event or NAND-read counter, or a shape change in the refresh-tier array, excludes only that counter. Continue other valid comparisons and show exclusion reasons in Research.

- Recovery activity includes age/background refresh, age padding and read verify.
- Reliability events include UECC, read-verify failures, grown bad blocks and die failures.
- “No new events in the available data” means comparable counters showed no increase. Unavailable counters have unknown status.

Show rates per day and per NAND read separately. Omit a rate with missing or zero denominator. Keep events overlapping lightweight research tests and label possible test influence. Events never automatically change the TBW multiplier.

## Interface and history

Alongside four Host forecast rows and the two domain bars, the standard view shows the direct domain baseline budget, measured cumulative NAND, estimated usage and unadjusted remaining writes. Research exposes:

- Direct topology mapping, IORegistry cross-check, direct 79 versus inferred ~80 bands and pSLC physical occupancy.
- TLC/pSLC capacities, current/EOL/target P/E, budgets, usage and remaining amounts.
- Signed residual, both reconciliation measures, WAF component residual and limiting-domain comparison.
- Raw refresh, read recovery, failure, write-path and histogram values and their comparison status.
- Unmatched keys and reasons for excluding individual counters.

Analysis updates in the background on collection, history and settings changes rather than rescanning history on redraw. Version 2.4 retains the collection interval and normal smartctl/ioreg collection. The in-app lightweight test runner was subsequently removed. Saved sessions still identify overlapping intervals.

## Regression coverage

Automated tests cover at least the following:

- Fixture 722/1/80 yields 79 pSLC and 642 TLC bands, at 128 MiB and 384 MiB respectively. Keeping the inferred 80-band proxy leaves the direct 79-band budget intact.
- Invalid boundaries, IORegistry mismatch, reaching or exceeding EOL, missing-direct fallback and exclusion of residuals from budgets.
- Changing retention settings adjusts only research values and With retention. Actual use and Client stay at Kret = 1. Missing TLC share does not introduce derating. Suspended series withhold all Host forecasts.
- Changing WAF leaves NAND budgets intact. Total Host always equals cumulative plus remaining Host.
- Duplicate keys, zero scalars, oversized, empty and all-zero histograms, and legacy JSON.
- v2.4.1 histogram names, Direct FTL context, required duration separate from observed off-time, and pSLC retention factor 1.
- First observation, series resets, individual counter decreases, research test overlaps and separation of reliability events from recovery.

The v2.4 acceptance criterion is that a reader can trace inputs, assumptions and unverified areas through the UI and history.
