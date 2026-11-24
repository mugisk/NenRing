# Reading the endurance forecasts

[日本語](FORECAST_GUIDE.md) · [Documentation](README.en.md)

NenRing estimates writes from the recorded history and stated assumptions about future use. It does not predict a failure date or guarantee data retention. When history is incomplete, it shows provisional estimates where calculation is possible rather than replacing missing inputs with zero.

## The four comparisons

| Row | Changed condition | Meaning |
|---|---|---|
| Actual use | Forecast WAF from observations | Remaining writes until the first of TLC or pSLC reaches its P/E target. No retention derating. |
| With retention | TLC P/E allowance | A hypothetical storage scenario using a low-I/O temperature proxy for the selected duration, normally 365 days. |
| Client workload | Future WAF of 3.5 | The baseline write budget with different future amplification. The 3–4 comparison range is a research assumption, not a JEDEC requirement. |
| Reference | NAND profile and logical capacity | A reference value for similar NAND, not an Apple rating or a fixed 250 TB value. |

The “Wear” value at the top of the dashboard and in the menu bar is the same as Actual use. It is a Host-based value calculated as cumulative Host ÷ (cumulative Host + remaining Host). Remaining Host changes with the forecast WAF and the TLC/pSLC write share, so the value can fall even while wear progresses. TLC and pSLC wear is average P/E ÷ target P/E, and the comparison with Percentage Used uses this value for the domain that reaches its target first. While there is no FTL-based projection, NAND wear or Percentage Used is shown instead.

An explicitly enabled manual override takes precedence for retention temperature. Automatic selection combines newly identified low-I/O intervals from the last 30 days with saved evidence across the available history for the same device and firmware lineage. If no candidates are available, it falls back to 30 °C. Earlier intervals that were not saved are not included. The firmware lineage is the leading number of the version, so a point update such as 591 to 591.40.3 stays in the same lineage. Right after a lineage change, before any new observation, evidence from the earlier lineage is used as a provisional value with low confidence. Automatic selection uses the median of daily representative temperatures across stable and non-stable low-I/O intervals; a stable-interval median and a time-weighted mean are available for comparison. 30 °C is the reference condition and the default when observations are insufficient. None of these values is measured while powered off. Powered-off temperature cannot be measured, so its difference from the powered-on low-I/O proxy is unknown.

The retention scenario derates TLC only, compares against its current maximum P/E, and also respects the pSLC remaining limit. Temperature conversion, the reference P/E at 30 °C for 365 days, and the time/P/E relationship are research assumptions, not measured Apple retention characteristics. See the [retention research model (Japanese)](RETENTION_RESEARCH_ESTIMATE.md).

Low-I/O selection now prefers disk I/O deltas saved with the temperature readings. An interval can qualify after 10 minutes with at least five temperature readings; counter resets and long collection gaps split intervals. Older history without I/O counters uses S.M.A.R.T. interval averages, labeled as fallback. Short observations can contribute to the provisional value, while confidence still depends on observed dates, duration and freshness rather than interval count alone. See the [temperature selection rules (Japanese)](RETENTION_RESEARCH_ESTIMATE.md#低負荷温度の観測規則-v3現行).

## Total, remaining writes and dates

FTL partition boundaries and geometry provide estimated TLC/pSLC capacities. Capacity, current average P/E and reported Controller EOL give each domain's remaining NAND budget. The central forecast converts it through the estimated write share and uses the domain with the smaller Host-equivalent remaining budget. TLC and pSLC P/E values have different quantization, so a small difference in their ordering does not establish a failure.

```text
domain remaining NAND = capacity × max(0, target P/E − current average P/E)
domain remaining Host = remaining NAND / (future WAF × domain write share)
remaining Host        = minimum of domain remaining Host values
total Host            = actual cumulative Host + remaining Host
```

When topology or write shares are unavailable, pooled-budget or cumulative-wear fallbacks are labeled with their limitations. Estimated capacities and shares are not independent measurements of physical allocation.

Future WAF affects only the remaining-write conversion; it does not reprice past Host writes. Reference remaining writes are the selected reference TBW minus actual cumulative Host writes, bounded below by zero.

Dates divide remaining Host writes by a write rate. The dashboard and menu bar use the rate from the complete saved continuous history; the Endurance page compares recent and recorded-history rates and shows their observation periods. A recent rate observed for less than its target window (normally 30 days) is marked with *. While the rate used has fewer than 7 observed days, arrival times are marked provisional. When a start date is set, the average rate since first use is used provisionally only until saved history reaches 7 observed days. That average includes use before recording, so the Endurance page shows it as a separate comparison column. When a start date is set, the write rate section shows both the recorded-history rate and the rate since first use. Years are shown as calculated, without a cap such as "20+ years". A date using the recent write rate alone is not a separate forecast with its remaining budget recalculated using recent WAF.

On the dashboard, Last 24 hours shows the host write rate over the 24 hours ending at the latest SMART reading. A measurement interval that crosses the start of the window is prorated by time. A shorter history yields a provisional rate. The rate is unavailable until there are comparable readings. The menu bar’s Today’s writes figure follows the local calendar day.

## WAF and write amounts

WAF is the ratio of Direct FTL NAND writes to Host writes. SMART Host writes are a separately acquired value and are not added to NAND writes. TLC/pSLC breakdowns are capacity-and-P/E estimates, not directly read domain write counters.

Forecast WAF logarithmically blends the cumulative ratio with an observed interval ratio, using observed Host bytes and a prior-equivalent Host amount for the weight. The 7/30/90-day comparisons use the actually comparable history. Short history can produce equal window values. Acquisition gaps, research sessions and post-update exclusion periods are shown with their evidence.

## Confidence and warnings

Low/medium/high confidence describes observation evidence under application rules, not prediction accuracy or a guarantee. Retention also depends on temperature evidence. Total temperature-history days and accepted low-I/O days are different quantities.

SMART warnings, FTL internal-error increases, and retention work and its pace are separate from the write-budget estimate. “No new events in the observed fields” and “No anomalies found” do not establish overall health; “Awaiting comparison” is neither a healthy nor a failed result. Keep backups regardless of the displayed remaining budget.

## Checking the inputs

Disk information exposes SMART/IORegistry values. Research exposes topology, residuals, WAF intervals and temperature provenance. Continuity checks distinguish the newest raw snapshot from the validated forecast input across OS, firmware and acquisition changes. See [cross-validation](DIRECT_FTL_CROSS_VALIDATION.en.md) and the [detailed NAND model (Japanese)](NAND_MODEL_V2_4.md).
