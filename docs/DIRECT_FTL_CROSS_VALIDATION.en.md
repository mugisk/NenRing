# Direct FTL / SMART cross-validation

[日本語](DIRECT_FTL_CROSS_VALIDATION.md) · [Documentation](README.en.md)

## Before saving

Manual and scheduled FTL reads go through the same pre-save checks.

Positive finite EOL values, finite nonnegative average P/E and average ≤ maximum are required. Reaching or exceeding EOL is not itself a parse failure.

A SMART snapshot from the same device within 24 hours supplies Host writes. The allowed difference is `max(SMART Host × 1%, 5 GB)`. Physical NAND writes are also checked with deliberately broad unit-error guards: NAND must not be below half of Host, and, where reconstructed capacity × average P/E is at least 1 TB, NAND must lie within 0.5–2 times that reconstruction. These guards do not independently validate all counter meanings or physical allocation.

Power On Hours is checked for drift in the FTL-minus-SMART offset rather than exact equality:

```text
offset = FTL POH − SMART POH
allowed offset change = 2 hours
  + (current absolute acquisition-time gap + previous absolute gap) / 3600
```

The previous comparison uses the nearest same-device SMART record within 24 hours, earlier than the current SMART record. A POH reversal on either side fails. A stable fixed offset is not an error. Time gaps are bounds, not assumed powered-on time during sleep.

A failed consistency check prevents saving and stops automatic collection. Missing/old/wrong-device SMART needed for Host comparison defers saving but does not by itself stop scheduling. A Host write mismatch against SMART older than two minutes is deferred the same way, because the writes in between can explain it. These checks alone do not validate every private key. Protection of the forecast current value and rate learning by boundaries D1–D7 and continuity lanes remains in place. Missing POH or a missing previous comparison defers only that auxiliary check; a valid Host comparison can still permit saving.

## Auxiliary observations

Research shows key 431 Controller Percent Used against SMART Percentage Used, and key 430 pSLC Percent Used against `100 × pSLC average P/E / pSLC EOL`. Differences are in percentage points. Definitions and rounding are not established as identical, so these differences are shown without any threshold that stops saving, raises confidence or changes TBW multipliers. Missing values remain missing, and input timestamps are shown.

SMART Data Units Written measures Host writes, not physical NAND writes. SMART Host Reads and Media Errors cannot be directly equated to internal read or UECC counters with different definitions.

## Boundaries and residuals

Raw Data and Residual share the comparison evidence. Background analysis, not view rendering, computes:

- Lifetime residual: `measured NAND − Σ(capacity × average P/E)`. A circular check that inverts capacity from `N/u` is not used.
- D7 boundary evidence, including the ±0.5 P/E quantization range.
- The latest validated lane interval's best residual and range. If it cannot be compared, an older interval is not presented as current.
- Age/BG/error-refresh raw increments over the same interval. Correlation alone does not establish units or causality.

The newest raw snapshot and the validated forecast snapshot/interval have separate timestamps. Data beyond pending or failed boundaries must not become the main budget's current input. Unknown residuals are not added to the budget, the forecast multiplier is not changed, and original history is not rewritten.
