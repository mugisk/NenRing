# Reference TBW and workload assumptions

[日本語](REFERENCE_TBW.md) · [Documentation](README.en.md)

NenRing uses these planning estimates for the dashboard's Reference row and for provisional forecasts before wear can be measured. **Apple does not rate or warrant its SSDs at these values.** The implementation is in `ReferenceTBW.swift`.

## Choosing a forecast basis

| Available evidence | Basis | Display |
|---|---|---|
| Validated Direct FTL | Measured NAND domain budgets | Actual use |
| No FTL, Percentage Used ≥ 2% | SMART cumulative Host writes divided by the fraction used | Actual use, provisional, SMART only |
| No FTL, Percentage Used 0–1% | Reference TBW by NAND generation and capacity | Actual use, provisional, from reference TBW |

For an internal Apple SSD, the provisional total spans the retail comparison and the extrapolation from one reference Mac described below. Dates, time remaining and the menu bar estimate use the conservative retail comparison. This range is neither a verified lower bound nor a statistical confidence interval.

For other SSDs, the lower estimate is two-thirds of the reference (e.g. 400 for 600). The central and upper estimates equal the reference. Retail ratings within a NAND generation vary by manufacturer, approximately 400–1000 TBW/TB.

## Reference by NAND generation

Identify the NAND from IORegistry's `vendor-name` and `nand-marketing-name`. Unlisted NAND uses **600 TBW/TB**, a common client rating (600 TBW for a 1 TB drive). Choose the nearest retail capacity on a logarithmic scale.

| NAND | IORegistry match | Comparable retail product | TBW/TB by capacity | Confidence |
|---|---|---|---|---|
| SK hynix 128-layer TLC (V6) | `hynix` / `tlc_3d_v6*` | Gold P31: 500 GB = 500 TBW, 1 TB = 750, 2 TB = 1200 | 1000 / 750 / 600 | High |
| SK hynix 176-layer TLC (V7) | `hynix` / `tlc_3d_v7*` | Platinum P41, same ratings | 1000 / 750 / 600 | Medium (reported figures) |
| Kioxia/SanDisk BiCS4 (96 layers) | `toshiba`, `kioxia` or `sandisk` / `tlc_3d_g4*` or `itlc_3d_g4*` | WD Blue SN550 1 TB = 600 TBW | 600 | Medium |
| Kioxia/SanDisk BiCS5 (112 layers) | Same vendors / `tlc_3d_g5*` or `itlc_3d_g5*` | WD Black SN770 1 TB = 600 TBW | 600 | Medium |
| Kioxia BiCS8 (218 layers) | Same vendors / `tlc_3d_g8*` | Kioxia EXCERIA PRO G2 = 600 TBW/TB | 600 | Medium (observed on M5 MacBook Air) |
| Samsung V-NAND TLC (`g7`) | `samsung` / `tlc_3d_g7*` | Samsung 990 PRO = 600 TBW/TB | 600 | Low (string observed on M5 MacBook Air, generation mapping unverified) |

The reference Mac (256 GB, Hynix V6) matches the 500 GB bracket: 1000 TBW/TB × 0.256 TB = **256 TB**. Since 2026-10-12 the dashboard has used this resolver in place of the fixed 250 TB comparison. Historical specifications are preserved. The resolver uses the individual machine's NAND and logical capacity, independently of its M-series generation. Unknown NAND is labeled as a default.

Remaining writes are `max(0, reference TBW − cumulative Host writes accepted for the forecast)`. Dates use the existing current or long-term Host write rate. Even when forecast input stops before a continuity boundary, the row uses that accepted Host counter. Retention adjustments, test WAF and the Apple extrapolation do not enter this row.

An unverified generation mapping carries the flag `generationMappingUnverified`. Currently this applies to Samsung `g7`. The information button identifies a retail reference with an unverified generation match. Unknown NAND using the default is a separate state.

Sources:

- The [SK hynix Gold P31 product page](https://ssd.skhynix.com/gold_p31/) identifies SK hynix 128L 3D TLC and rates the 2 TB model at 1200 TBW. The 500 GB and 1 TB ratings come from StorageReview and TechPowerUp reviews.
- Public IORegistry examples identify NAND installed in Macs. See the [hardware table and sources](APPLE_SSD_HARDWARE.en.md).
- Retail ratings vary even within a generation. BiCS4 examples range from 400 TBW/TB (Kioxia EXCERIA PLUS) to 600 (WD Blue SN550). Diagnostic reports can help fill gaps.

## Extrapolation from the reference Mac

The measured TLC-write/Host ratio is about 0.66. Applying it and 3000 P/E to other Apple internal SSDs gives about 1.17 PB for 256 GB. Unlike a retail rating with validated retention conditions, this is an extrapolation. It cannot establish that retail TBW systematically underestimates Apple SSD endurance.

```text
Extrapolated Host writes = capacity × 3000 P/E ÷ 0.66
```

Use this value only for the upper end of the provisional range. Dates use the retail comparison. Further reports are needed to test both assumptions across machines.

## Client workload WAF

| Value | Use | Evidence |
|---|---|---|
| About 2 typical, 1.8–2.2 measured on sTLC | General client WAF | NI's discussion of write amplification under JESD219 Client gives about 2 (updated 2025-10-30). Advantech measured 1.8–2.2 on BiCS4 3D sTLC over seven days with the JEDEC 219 Client Workload. [NI](https://www.ni.com/ja/support/documentation/supplemental/12/understanding-life-expectancy-of-flash-storage.html), [SQFlash 640-C Rev 1.3, 2021-05-02, p. 7](https://mm.digikey.com/Volume0/opasdata/d220001/medias/docus/7188/SQF-SMSZ2-64.pdf) |
| 2.5–3.0 measured on TLC | Client WAF in TLC mode | The same Advantech table gives BiCS4 3D TLC WAFs of 2.98 (256 GB), 2.52 (512 GB) and 2.54 (1 TB). |
| 3.5 (range 3–4) | Conservative Client workload scenario | Micron describes 3–4 for typical client workloads in a blog post dated 2024-08-27. [Micron](https://www.micron.com/about/blog/storage/ssd/tackling-ssd-endurance-made-me-a-better-product-manager) |

WAF varies with capacity, spare area and free space. These values are inputs to scenarios for comparison.

### Rated TBW and P/E

Advantech gives `TBW = NAND P/E × capacity ÷ WAF`. Its 3D TLC table is consistent with 3000 P/E: 3000 × 0.256 TB ÷ 2.98 ≈ 258 TBW for the 256 GB part.

JEDEC defines TBW in terms of Host writes while meeting powered-off retention requirements (one year at 30°C for client drives). Taken together, the figures imply that this vendor rates its 3D TLC at 3000 P/E with one-year retention at 30°C. The roughly 258 TB estimate also agrees closely with the Gold P31 reference of 256 TB. [Alvin Cox, *JEDEC SSD Specifications Explained*, pp. 25–26](https://www.jedec.org/sites/default/files/Alvin_Cox%20%5BCompatibility%20Mode%5D_0.pdf)

The JEDEC explanation also gives a factor-of-two allowance for uneven wear: `TBW < capacity × rewrite capability ÷ (2 × WAF)`. This accounts for the most heavily worn block. Maximum P/E on the reference Mac is about 1.1 times its average.

## Percentage Used and Data Units Written (NVMe)

Both come from SMART / Health Information log page 02h. **Data Units Written** counts Host writes in units of 1000 × 512 bytes, rounded up. **Percentage Used** is the vendor's integer estimate of rated life consumed. It may exceed 100 without implying failure. A new Mac may report 0–1% for a long time.
