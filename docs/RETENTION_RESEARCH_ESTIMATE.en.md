# Retention research estimate

[日本語](RETENTION_RESEARCH_ESTIMATE.md) · [Documentation](README.en.md)

## Dashboard “With retention” scenario

`RetentionScenario.swift` estimates the remaining Host writes under a hypothetical condition: power off the drive for D days at T°C. The automatic temperature comes from intervals with little disk activity while powered on. The actual storage temperature while powered off cannot be measured. The display identifies user overrides, historical observations and defaults separately.

The central forecast for everyday use takes Kret = 1. The separate storage scenario derates TLC only and uses the observed pSLC controller EOL. This choice does not establish a pSLC retention curve, rule out retention loss while powered on, or confirm that an Apple SSD always refreshes as needed.

```text
AF(T)        = exp(Ea/k × (1/303.15 − 1/(max(T, 25°C) + 273.15))), Ea = 1.1 eV
P_allow(T,d) = min(EOL, P_ref ÷ ((d / 365) × AF(T)))
P_ref        = 3000 P/E (alternative reference: 1500)
remaining Host = min(TLC capacity × max(0, P_allow − maximum TLC P/E) ÷ a_TLC,
                     remaining pSLC Host writes)
```

- **Reference at 30°C for one year.** JESD218 requires client drives to retain data powered off for one year at 30°C at rated TBW. JEDEC does not prescribe a P/E count. Vendor examples use 3000 P/E. Applying this value to Apple NAND is a model assumption. The alternative of 1500 P/E comes from a Micron document cited by Park et al. (2021). The original was unverified. It provides neither a validated lower bound nor a confidence interval. See Cox, *JEDEC SSD Specifications Explained*, pp. 25–26, and [Reference TBW](REFERENCE_TBW.en.md).
- **Wear input.** Use the highest observed TLC P/E, about 1.1 times the average on the reference machine. This is a conservative choice of wear input, not a retention test.
- **Temperature conversion.** Ea = 1.1 eV is a reference coefficient rather than a measurement on Apple NAND. Clamping temperatures below 25°C is an extrapolation policy. The JEDEC explanatory material and HeatWatch (HPCA 2018) concern different NAND or evaluation conditions.
- **Time versus P/E.** Inverse proportionality (n = 1) follows a component-specification convention of ten years at 10% of rated wear and one year at 100%. The project found no public 3D TLC data establishing this slope.
- **Temperature selection.** An explicitly enabled override takes priority. Otherwise combine low-load intervals newly extracted from the last 30 days with saved candidates from the entire history for the same device and firmware family. Unsaved past intervals are unavailable. The leading firmware number defines the family (591 and 591.40.3 match). After a family change, until fresh observations exist, label earlier candidates as observations from the previous firmware and assign low confidence. With no candidates, use 30°C. A legacy stored 30°C setting serves as a reference and does not disable automatic selection. Selection is independent of the cooldown fit in `ThermalRetentionAssessment`.
- **Required duration.** Use `UsageSettings.retentionDays`, default 365. Elapsed time minus Power On Hours can include sleep and cannot substitute for a future storage requirement.
- **Write temperature.** An optional research adjustment is off by default. Its ±2% bound is imposed by the model.
- **Reference machine, 2026-10-02.** At 30°C for 365 days, P_allow was 3000 P/E, equal to TLC EOL. Remaining Host writes were about 1.10 PB, or 20 years at the then-current pace. The unadjusted central estimate was about 1.11 PB. Here the difference came solely from using maximum rather than average P/E. The earlier choice of idle temperature (39°C) gave 836 P/E and 256 TB remaining.

### Low-load temperature observation rules v3 (current)

The selector uses the selected disk's Block I/O counters saved alongside temperature samples. Earlier versions already recorded these counters but selected candidates from SMART deltas. This requires no additional collection or change in sampling frequency.

Divide the change in bytes read plus written between adjacent temperature readings by elapsed time. Require the same device, boot time and driver ID. Split at counter reversals, research tests, learning exclusions and collection gaps. SMART supplies continuity checks for firmware, power cycles, powered-on hours and counters. Reject new candidates if SMART context is older than three times the median collection interval, bounded to 30 minutes–6 hours.

**I/O candidates require at least 10 minutes and five temperature samples.** Allow one second of timestamp skew in duration. Limit temperature gaps to three times the median interval, bounded to 2–5 minutes. Split and evaluate both sides of a longer gap separately. New records include a monotonic clock during the boot session. Split when its elapsed time differs from wall time by more than five seconds. Older records cannot reliably distinguish short sleeps.

Use the time-weighted lower 20th percentile of comparable I/O rates, bounded to 1–8 MiB/s. With less than six hours of observations, use 1 MiB/s. Calculate separate thresholds for I/O and SMART because their counters and intervals differ. Legacy intervals without I/O use SMART deltas and retain the 30-minute, four-sample and missing-data requirements. Never fill a reset, inconsistency or partial gap in an I/O interval with the SMART average.

The primary value is the median of daily representative temperatures across all accepted history. Short candidates can contribute to a provisional value. Confidence depends on stable days, total duration, temperature spread and freshness. Counting ten-minute candidates alone cannot raise confidence to medium or high. For stability, require a spread within 2°C across a short candidate or across at least 15 minutes of the last 30 minutes of a longer candidate. Six-hour segmentation, manual override priority and long-term candidate retention still apply.

Each candidate can record the source, maximum I/O gap and whether monotonic time was checked. For I/O candidates the SMART interval is unset. Older v1/v2 candidates and I/O records without monotonic time remain readable. Details show counts and thresholds by source and each candidate's source and maximum interval.

### Low-load temperature observation rules v2 (previous)

Show the days and sample count with any temperature history in the last 30 days separately from days and hours of accepted low-load observations. Extract new candidates from 30 days and use valid saved candidates regardless of age. Assign each candidate to the local calendar day containing its midpoint. Mere availability of history does not improve the assessment.

For structurally comparable SMART intervals, use the time-weighted lower 20th percentile of the combined read/write rate, bounded to 1–8 MiB/s. Keep the fixed 1 MiB/s threshold until six comparable hours exist. Time weighting keeps subdivisions of the same interval from changing the cutoff. This identifies a relatively low-load band within this environment without establishing that the SSD was idle.

Save candidates containing intervals above 1 MiB/s with `relativeLowIO=true` and the threshold. Label them as low-load observations with confidence at most medium. Exclude rates above 8 MiB/s even when relatively low. Retain duration, stability, reset, test and missing-data rules. Interpret v1 candidates as fixed-threshold observations and discard old v2 candidates whose threshold exceeded 8 MiB/s.

### Idle temperature observation rules v1 (initial implementation)

`IdleRetentionTemperatureAnalyzer` selects intervals using SMART read/write deltas from the last 30 days. The documented threshold runs from 1 MiB/s up to 8 MiB/s depending on observations. Require 30 minutes and four temperatures. A candidate is stable if its final 30 minutes contain at least three readings spanning at least 15 minutes within 2°C. Use the median of that tail for stable candidates and the interval median otherwise. Use the median of daily representatives across all accepted candidates as the primary value. Show the stable-only median for comparison. Split long runs every six hours and group by the device's calendar.

Limit SMART gaps to three times the median (30 minutes–6 hours). Limit temperature gaps to three times the median (10–30 minutes), with readings within ten minutes of both boundaries. Exclude resets, firmware family or power-cycle changes, research tests and rate-learning exclusions at validated boundaries. Exclude intervals where powered-on time and wall time differ by over one hour. Integer hours cannot identify every short sleep. SMART interval averages can hide bursts. Daily-compressed temperatures cannot establish idle intervals.

Medium temperature confidence requires stable candidates on three days totaling at least three hours with daily spread ≤8°C. High requires seven days, 14 hours and spread ≤5°C. Otherwise confidence is low/provisional. If the newest candidate is older than seven days, label it historical and low. These are app selection criteria.

Atomically save candidates in `idle-temperature-evidence.json` with device, contemporaneous firmware, interval, temperature, count, Host I/O, sample gaps, stability and rule version. Reuse qualifying candidates without a time cutoff. For overlapping candidates in the same series, count only the one with more points. Report a corrupt file without overwriting it. Preserve the original SMART and temperature history.

### Median and mean

Automatic temperature uses the median of daily representative values without adjustment by the mean. The evidence details and dashboard tooltip also show a time-weighted mean for comparison.

Integrate adjacent temperatures by the trapezoidal rule over the same points used for the median, then divide by observed seconds. For stable intervals use the last 30 minutes, otherwise use accepted observations across the interval. Integrate only within intervals that passed gap, sleep and test exclusions. Do not interpolate across gaps or past endpoints. Sum integrals and seconds across intervals, so a higher sampling frequency alone adds no weight. Label the daily median and time-weighted mean separately.

Optional saved fields are `timeWeightedTemperature` and `temperatureObservedSeconds`. Report the number of usable intervals and actual observation time without estimating a mean from old medians. With only legacy candidates the median remains usable and the mean is unavailable. Observed statistics remain visible independently of a manual override.

### Dashboard confidence v1

Confidence describes observations supporting the current domain forecast. It does not reuse the legacy SMART/controller score, measure forecast accuracy, guarantee retention or verify physical allocation.

| Component | Medium | High |
|---|---|---|
| Wear | Both domains, two normal intervals each, 14 days, ≥1 P/E each | Three normal intervals each, 90 days, ≥3 P/E each |
| WAF | Seven days and ≥100 GB eligible Host writes | 28 days and ≥1 TB |
| Write pace | ≥14 valid days observing the current pace | ≥28 days |

Current pace and adopted WAF normally use 30-day windows. A 28-day threshold accommodates missing endpoints. Normal intervals are nonoverlapping aggregates under the existing 24-hour, 1 TB and P/E progression rules. Overall confidence takes the lowest component. Missing domains or a suspended forecast give low wear confidence. Lifetime-only WAF or snapshot-only wear also scores low. A provisional byte unit is disclosed without automatically capping the overall score at low.

With retention additionally takes the lower of overall and temperature confidence. A manually selected temperature is a condition and does not alter the score for observed temperature. The reference and hypothetical client rows receive no observation-based confidence rating. Analysis runs in the existing background updates for SMART, FTL or settings changes. Temperature-only polling updates lightweight charts. Redrawing a view does not scan history.

## Purpose of the separate research estimate

The remaining sections describe `RetentionResearch`. Its retention/RBER fit combines published NAND data with this Mac's SMART Host writes and Apple Direct FTL P/E observations. It is a transfer scenario, with no claim to an Apple rating, JEDEC Client TBW, guaranteed retention or failure date. The current central calculation and acquisition contract are in the [NAND model](NAND_MODEL_V2_4.en.md). Older descriptions of the TLC-only capacity formula as the normal dashboard TBW are superseded.

The research calculation uses effective capacity proxy × adjusted P/E ÷ WAF. Controller EOL is a research anchor. No calibration to the former 250 TB comparison or any PB target was performed.

## Research estimate and legacy slope diagnostics

Separate the capacity estimate from domain-specific extrapolation of Host bytes per P/E. Short intervals and integer P/E steps can inflate the latter. Raw/Prior/Blend remain diagnostics and do not set the dashboard budget. See the [forecast guide](FORECAST_GUIDE.en.md) and [NAND model](NAND_MODEL_V2_4.en.md).

Luo et al. studied one manufacturer's 3D MLC charge-trap NAND. Manufacturer and process details were withheld. Retention was measured at 20°C over 0–10,000 P/E and seven minutes to 24 days. Their system example assumes an ECC limit at RBER `3 × 10⁻³`. Apple's ECC threshold is unknown. [Luo et al., 2018, §§4.1, 4.3, 5.2, 6.5 and Table 2](https://www.pdl.cmu.edu/PDL-FTP/NVM/18sigmetrics_3dflash.pdf)

## Fit and unresolved assumptions

```text
ln(RBER) = (α × P/E + β) × ln(t_seconds) + γ × P/E + δ
```

| Bit | α | β | γ | δ | Adjusted R² |
|---|---:|---:|---:|---:|---:|
| MSB | 5.49e-6 | 0.16 | 1.33e-4 | -13.11 | 0.9717 |
| LSB | 7.92e-6 | 0.25 | 3.28e-5 | -12.72 | 0.9005 |

The paper writes `log(t)` without specifying the base or time unit of the fitted coefficients. The initial app profile explicitly assumes natural logarithms and seconds. Golden tests reproduce the app's interpretation of Table 2 under those assumptions. They do not independently verify the authors' fit or resolve the missing convention.

Convert target retention time to equivalent time at the paper's 20°C reference using an Arrhenius factor:

```text
t_equivalent = t_target × exp(−Ea/k × (1/T_target − 1/T_reference))
```

The initial Ea = 1.1 eV is configurable. A storage temperature override takes precedence over a labeled automatic proxy. The client reference uses 30°C, 365 days and the default threshold 3e-3. The current-condition calculation takes the future requirement (`retentionDays`, default 365). Separately record the longest directly observed off-equivalent interval from consecutive SMART Power On Hours readings: elapsed wall time minus the counter increase. Never annualize, interpolate or extrapolate this diagnostic or substitute it for the requirement.

Solve the linear equation for P/E for each bit class and take the smaller nonnegative solution. Research shows the raw result. The client P/E allowance is the domain's controller EOL. For current conditions, separate the duration and environment contributions:

```text
R_days = researchPE(30°C, observed or fallback days) / researchPE(30°C, 365 days)
R_env  = researchPE(current temperature, observed or fallback days)
         / researchPE(30°C, observed or fallback days)
K_ret  = R_days^w_days × R_env^w_env
current PE allowance = controller EOL × K_ret × optional program factor
```

Default w_days = 0.50 weights only the contribution from directly observed retention duration. Default w_env = 0.20 downweights the larger temperature/model extrapolation. The old optional `retentionResearchWeight` aliases w_days. The former default 0.20 migrates to 0.50. Preserve other explicit legacy values. Use the same configured RBER threshold for all comparisons. It is independent of any measured Apple ECC value. The research adjustment can exceed controller EOL, which is an anchor rather than a certified retention limit. The client program factor always equals 1. Results include the time and P/E extrapolation ratios beyond the paper's 24 days and 10,000 P/E.

## Applying the reference curve to Apple NAND

Transferring a 3D MLC curve to Apple TLC crosses cell types and generations. There is no independent pSLC retention curve in this profile. Use observed pSLC controller EOL with retention factor 1.0 as its central target. Use observed pSLC P/E and its own Host-bytes-per-P/E slope when available. The former proportional transfer from TLC remains historical only.

Use observed average and maximum P/E separately for each domain. Derive TLC and pSLC slopes independently from same-series wear intervals. The smaller domain result bounds the legacy Host/P/E diagnostic. The TLC-only capacity proxy does not set the [central dashboard budget](NAND_MODEL_V2_4.en.md), which uses direct topology and the first domain to reach its target.

The UI compares normalized average and maximum wear and the ratio of TLC/pSLC progression. Use identical valid intervals in which both domains exist and neither decreases. Retain a zero step in one domain when the other advances. Similarity describes behavior without proving equal capacity, identical retention curves or causality. Compute MSB and LSB allowances separately, use the smaller TLC allowance and identify the limiting bit class.

For a provisional estimate with short history, try these labeled sources **for each domain**, in order:

1. Same-series daily Host-bytes-per-P/E slope with at least two valid intervals.
2. One valid normal interval or aggregated short intervals.
3. Lifetime SMART Data Units Written in bytes divided by the domain's current average or maximum P/E.
4. An explicit domain prior.

Different sources for TLC and pSLC produce a mixed or partial result. Lifetime Host writes span TLC, pSLC, garbage collection and metadata, so this fallback can be biased and does not measure allocation. If current P/E is zero or missing, show the reason without dividing by zero or filling it. Without an observed slope, lifetime counter or explicit prior, the domain Host estimate is unavailable.

Keep each domain's interval count and evidence source in the result. Recalculation automatically adopts daily history once enough same-series intervals exist. Current domain P/E, controller EOL limits, reset/epoch safeguards and matched SMART/explicit Direct FTL requirements still apply. Maximum-P/E estimates use maximum-P/E slopes when available without an additional max/average correction. Keep the average-P/E estimate as a separate comparison. Test WAF is excluded. Intervals overlapping research sessions cannot train the daily estimate, although their resulting wear and writes remain in the latest device measurements.

## Validation, history and display

Require matched SMART and explicit Direct FTL snapshots for the same device and a Direct FTL series identity matching the wear-history summary. Missing or inconsistent inputs remain unavailable. Never substitute zeros or values from unrelated text logs. Mark provisional FTL units. Retain WAF prior, raw observed WAF, adopted current-condition WAF, blended WAF and its weight. The adopted WAF is provisional. The research blend is diagnostic and supplies no confidence interval.

Where available, Direct FTL context includes device, firmware epoch, source build, firmware, MSP and chip ID. A build mismatch marks an expected unverified state awaiting manual compatibility review. It is independent of disk health.

**Summary:** total client Host writes, current-condition total and remaining Host writes (prefer maximum P/E, otherwise average), projected date and evidence score. Use the recorded-history write pace, or pace since first use if observation spans less than seven days and a start date exists.

**Research:** profile coefficients and sources, raw and anchored P/E, storage assumptions, equivalent reference time, extrapolations and average/maximum calculations, current TLC/pSLC P/E and their relationship, per-domain fallback evidence and scores, WAF blend details, snapshot IDs, times, units and caveats. The score describes evidence coverage and model fit. It is not a probability of an accurate forecast or a guarantee.

**Settings:** optional per-device fields in `UsageSettings` preserve compatibility with old JSON. Default to 30°C if the automatic proxy is unavailable, RBER 3e-3, Ea = 1.1 eV, w_days = 0.50 and w_env = 0.20. For the observation fallback, 365 days applies only when there is no measured candidate. The UI and result retain the observed interval's start, end and provenance.

## Supplementary measurements

**Client proxy writes.** Version `client-proxy-v2` generates each write from a deterministic sequence that advances independently of the random sequence for block size and address selection. Keep working-set size, measured initial writes and overwrite volume separately. Display WAF across four intervals without claiming steady state. V1 records remain readable and manually selectable with a repeated-data warning. Automatic selection does not treat them as equivalent observations. Write-volume, time, free-space, temperature and AC-power limits remain in force.

**Internal Direct FTL counters.** Display deltas over same-series intervals. `hostAutoWrites` is raw with an unconfirmed unit. It supplies neither a GB conversion nor a refresh diagnosis. Bad blocks, die failures, spare space, oSLC transitions/reference P/E and changes in TLC/pSLC wear imbalance are descriptive and do not directly quantify retention margin.
