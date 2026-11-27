# Internal SSD hardware in Apple Silicon Macs

[日本語](APPLE_SSD_HARDWARE.md) · [Documentation](README.en.md)

This inventory summarizes public evidence available to the project as of October 2026. NenRing uses it to identify hardware. Confidence is **high** for a value visible in an IORegistry example, **medium** for a teardown or secondary report, and **low** for a summary of a forum post that could not be inspected directly. The final section lists gaps that require [diagnostic reports](DIAGNOSTIC_REPORTS.en.md) from other machines.

## Reading IORegistry

| Field | Interpretation |
|---|---|
| Controller class | Depends on macOS. The same reference M1 reported `AppleANS3NVMeController` on 25G83 and `AppleANS3CGv2Controller` on macOS 27 (26A434). M5 and A18 Pro examples on macOS 26.4 already reported the latter. Both match the superclass `AppleANS2NVMeController`. Asahi Linux uses a different naming scheme, `apple,nvme-ans2`, for all of them. |
| `chip-id` | Identifies the MSP NAND controller die inside the NAND package. S5E appears on M1, M1 Pro/Max and A18 Pro MacBook Neo, S6E on M5. |
| `msp-version` | MSP firmware. Early M1 examples have 2.8.x, the reference machine and Neo have 4.12.2, and S6E has 62.10.4. |
| `firmware-version` | Tracks macOS. Both S5E and S6E examples on macOS 26.4 report `2973.100`. |
| `vendor-name` | NAND vendor, consistent with the first byte of `manufacturer-id` (JEDEC ID): 0x98 Toshiba/Kioxia, 0x45 SanDisk, 0xEC Samsung, 0xAD SK hynix. |
| `nand-marketing-name` | Format: `<type>_3d_<generation>_<planes>p_<die capacity in Gb>`. Kioxia/SanDisk use `g<BiCS generation>`, SK hynix uses `v<generation>`. Some BiCS4 examples start with `itlc_`. |
| `bus-to-msp`, `dies-per-bus`, `num-dip` | Package configuration. `num-dip = die count × cau-per-die`. |
| `package_blocks_at_EOL` | Approximately 94–95% of the total block count in the examples reviewed. |
| SSD model | M1: AP…Q. M1 Pro/Max/Ultra: AP…R. M2 and later, and Neo: AP…Z. |

Open the NVMe SMART plug-in (`kIONVMeSMARTUserClientTypeID`) on a node with `"NVMe SMART Capable" = Yes`. On M5, Anode reports that the namespace node `IOEmbeddedNVMeBlockDevice` has the property and opening the controller node returns `kIOReturnUnsupported`. NenRing's FTL probe searches by property, then requires an `AppleANS2NVMeController` provider or subclass, so it accommodates this difference.

For IORegistry values NenRing searches, in order, for `AppleANS3NVMeController`, `AppleANS3CGv2Controller`, `AppleANS2NVMeController` and `AppleANSNVMeController`. The research tool `asp-snapshot-probe` also matches the superclass. On 2026-10-02 it detected `AppleANS3CGv2Controller` on the reference machine running macOS 27 (26A434) and read header 0x91 with ordinary user privileges. The tunnel probe has been removed.

## Hardware by model

### M1 family

| Model and capacity | chip-id / MSP / firmware | NAND | Configuration | Source and confidence |
|---|---|---|---|---|
| M1 MacBook Air 256 GB | S5E / 4.12.2 / 561.100 → 591 → 591.40.3 | SK hynix `tlc_3d_v6_4p_512` (128 layers) | 2 packages, 4 dies, num-dip 16 | Reference Mac, high. Class ANS3NVMe on 25G83, ANS3CGv2 on macOS 27. |
| Other M1 256 GB units | S5E | Kioxia KICM232 + KICM225 or SanDisk SDRGJHI4 × 2 | 2 packages | [danielgontan](https://danielgontan.es/en/macbook-nand-list/), [iFixit](https://www.ifixit.com/News/46884/m1-macbook-teardowns-something-old-something-new), medium |
| M1 MacBook Air 512 GB | S5E / 2.8.7 / 1161.40 | Toshiba `itlc_3d_g4_2p_256` (BiCS4, 96 layers) | 17 dies, dies-per-bus (5,4,4,4) | [ThomasKaiser/Knowledge](https://github.com/ThomasKaiser/Knowledge/blob/master/articles/Exploring_Apple_Silicon_on_MacBookAir10.md), high |
| M1 13-inch MacBook Pro 1 TB | S5E / 2.8.8 / 2.100.34 | SK hynix `tlc_3d_v5_4p_512` (96 layers) | 2 packages | [DarwinDumped](https://github.com/khronokernel/DarwinDumped), high |
| M1 1 TB and 2 TB | — | Kioxia, SK hynix or SanDisk (1 TB: KICM229 / H23B4T84 / SDREGJHIH) | 2 packages | danielgontan, medium |
| M1 Pro/Max 512 GB, also Mac Studio 512 GB | S5E / 2.8.10.2 / 387.100 | Toshiba `itlc_3d_g4_2p_256` | 8 buses, 17 dies, bus-to-msp (0,0,1,1,2,2,3,3) | [repoman27, AnandTech](https://forums.anandtech.com/threads/apple-silicon-soc-thread.2587205/page-124), high |
| M1 Pro/Max 1 TB (AP1024R) | S5E / 2.8.10.2 / 499.0.9 | SanDisk `itlc_3d_g4_2p_256` | — | [Apple developer forum attachment](https://developer.apple.com/forums/content/attachment/223df876-aa95-43eb-a3f1-c2a2fa1dab41), medium, model inferred |
| M1 Pro/Max/Ultra 2–8 TB | — | Kioxia, SK hynix or SanDisk | 4–8 packages | danielgontan, low to medium |

M1 and M1 Pro/Max/Ultra share the controller class and chip-id. Bus width differs: M1 has four buses and two MSP paths, Pro/Max eight buses and four paths.

### M2 through M4

| Model and capacity | NAND | Configuration | Source and confidence |
|---|---|---|---|
| M2 MacBook Air 256 GB | SK hynix HN3T1BA4GAX170, generation unknown | 1 package | [MacRumors teardown](https://macrumors.com/2022/07/18/macbook-air-m2-chip-teardown), medium |
| M2 Mac mini and M2 Pro MacBook Pro, 256–512 GB | Unconfirmed | Fewer packages than preceding generation | [MacRumors](https://macrumors.com/2023/01/24/m2-mac-mini-256gb-slower-ssd), low |
| M3 MacBook Air 256 GB | Unconfirmed | 2 × 128 GB | [Gigazine](https://gigazine.net/gsc_news/en/20240313-m3-macbook-air), medium |
| 14-inch M3/M4 MacBook Pro, 512 GB–2 TB | Kioxia K5A4/K5A5/K6B2/K5A8 or SK hynix. SanDisk also reported. | 2 packages | MacRumors replacement thread (summary only), low to medium |
| M4 Mac mini removable module | 256 GB uses 2 × 128 GB. One replacement used Kioxia K6B2. Factory vendor unconfirmed. | 2 packages, front and back | [Tom's Hardware](https://tomshardware.com/desktops/mini-pcs/m4-mac-mini-ssd-modded-from-256gb-to-1tb-modder-solders-higher-capacity-nand-to-the-removable-ssd-module), [iFixit teardown coverage](https://macrumors.com/2024/11/12/ifixit-m4-mac-mini-teardown), medium |

The survey found no public M2, M3 or M4 IORegistry examples containing `chip-id` or `nand-marketing-name`.

### M5 and A18 Pro MacBook Neo

The first four entries use a [mirror of public IORegistry dumps](https://github.com/timb-machine-mirrors/dmaynor-apple-vuln-research), a secondary source. The original repository location was unconfirmed.

| Model and capacity | Class / chip-id / MSP / firmware | NAND | Configuration | Confidence |
|---|---|---|---|---|
| MacBook Neo (A18 Pro) 256 GB | ANS3CGv2 / S5E / 4.12.2 / 2973.100 | Toshiba `tlc_3d_g5_2p_512` (BiCS5) | 4 dies, 12560 EOL blocks | High |
| MacBook Neo 512 GB | Same | SanDisk `tlc_3d_g5_2p_512` | 8 dies, 25120 EOL blocks | High |
| M5 MacBook Air 1 TB | ANS3CGv2 / S6E / 62.10.4 / 2914.80 | Toshiba `tlc_3d_g8_4p_1024` (inferred BiCS8, 1 Tb) | 8 dies, 20672 EOL blocks, 2 packages | High |
| Another M5 MacBook Air 1 TB | ANS3CGv2 / S6E / 62.10.4 / 2973.100 | Samsung `tlc_3d_g7_4p_1024` | 16720 EOL blocks | High for the values, generation unconfirmed |
| M5 Pro MacBook Pro 1 TB | ANS3CGv2 | 8 dies, cau-per-die 4, 7704 pages/block | — | [Anode](https://github.com/noahahoward/Anode), medium |

Kioxia and Samsung NAND occurred in the same M5 MacBook Air model. The model identifier alone cannot identify the NAND.

Release chronology recorded in the survey:

- October 2025: M5 MacBook Pro, SSD throughput approximately 6.3 GB/s.
- March 2026: M5 Pro/Max MacBook Pro and M5 Air.
- August 2026: M5 Max/Ultra Mac Studio.
- September 2026: M6 / M5 Pro Mac mini returned to NAND soldered to the logic board.

## SMART behavior

- smartctl exposes integer Percentage Used, Available Spare (threshold **99%** on the Apple Silicon examples), Data Units Read/Written, Power Cycles, Power On Hours and Unsafe Shutdowns. Error log retrieval fails with `GetLogPage failed`.
- The survey found a 10% threshold only on Intel/T2-era Apple SSDs.
- Anode reported Percentage Used still at 0% on a 1 TB M5 Pro after 7.31 TB of writes.
- Reports of excessive M1 writes in 2021 subsided after a kernel fix in macOS 11.4. A subsequent survey found most M1 units at 0–6%. [Hector Martin, HN 2022](https://news.ycombinator.com/item?id=33024863)
- The survey found no public Apple Silicon examples publishing WAF or both NAND and Host writes. The project's only measurements were from the reference Mac: WAF about 1.6, TLC writes about 0.66–0.67 times Host writes.
- It found no public evidence of asptool or sysdiagnose ASP statistics working on M2–M5.

## Gaps for diagnostic reports

1. Controller class, `chip-id`, `msp-version` and complete `Controller Characteristics` for all M2/M3/M4 variants.
2. Observed `nand-marketing-name` and vendor for each model/capacity, including vendor variation within a model.
3. Factory M4 Mac mini modules, Apple part numbers 661-43668 through 661-43671.
4. M5 Pro/Max/Ultra and M6 chip-id and NAND.
5. Availability of the NVMe SMART plug-in and Direct FTL on M2 and later. If available, TLC/pSLC EOL cycles and virtual block counts.
6. WAF, TLC writes/Host and pSLC writes/Host across vendors and capacities.
7. Registry strings for Samsung g7 and 176-/238-layer SK hynix NAND, and the relationship between `package_blocks_at_EOL` and rated P/E.
8. Any Apple Silicon Mac reporting an Available Spare threshold other than 99%.
