# Lossless measurement history

[日本語](LOSSLESS_HISTORY_STORAGE.md) · [Documentation](README.en.md)

Standard SMART, temperature and FTL storage does not thin accepted observations by age or count alone. Each observation's ID, timestamp, values, missing fields and acquisition conditions are retained, and statistics receive the original observation series.

## On-disk format

The existing `history.jsonl`, `temperature-history.jsonl` and `asptool-snapshots.jsonl` become append files for new observations. Once 256 observations have accumulated, they are sealed into a block before the next append. Sealed records are kept in each `<name>.lossless/` directory.

- `manifest.json`: format version, record type and the list of sealed blocks.
- `<SHA256>.json.lzfse`: an independent compressed block of up to 256 observations. The SHA256 covers the decompressed content.

`nenringHistoryBlock: 1` in a JSON block is the format version number that distinguishes it from the old one-observation-per-line layout. `shared` stores fields identical across all observations once, and `observations` stores the rest of each observation. Identical temperatures or counters can be shared, but observations are never reduced to a single point in place of a count or duration. IDs and acquisition times are always kept per observation.

Values are not rounded, timestamps are not resampled to even intervals, and counters are not stored as deltas only. UInt64 values stay integers, and new-format Dates keep subsecond precision. Subsecond precision already lost in old ISO 8601 records is not filled in.

## Writing and recovery

Normal appends do not rewrite the whole history. When the append file reaches 256 or more observations, sealing runs in this order before the next observation is added:

1. Restore the shared block to the original types and verify that it matches every observation.
2. Write the compressed file, then confirm the read-back, the decompressed match and synchronization.
3. Atomically update the manifest and synchronize it.
4. Atomically replace the append file with an empty one.

If the process is interrupted between steps 3 and 4, the same IDs remain in both the block and the append file. Loading accepts each ID once, preferring the append file's value. Old blocks are never periodically recompressed.

Unsupported versions and torn lines keep their original bytes through the existing rejection handling. A missing block, hash mismatch or invalid manifest is a load error; an incomplete history is not treated as complete and replaced by a new save. While the history cannot be read, new observations are still saved to the append file, the manifest and blocks are left unchanged, nothing is sealed, and forecast recalculation is held. Once the history can be read again, the appended observations are merged in and sealed by the next append.

When the whole history must be replaced, for example for a device-ID migration, all observations are first saved to the append file and then a new manifest is committed. Old blocks are not deleted automatically.

## Migrating from the old history

On the first load, the old JSONL is copied to `<name>.pre-lossless-v1.jsonl`. If legacy `archive/<name>-*.jsonl[.lzfse]` files exist, all their records are restored and merged with the current file by ID. The archive originals are not modified. Imported records are saved to the new manifest, and the archive is not scanned again.

A daily temperature summary is excluded from analysis input only when the original observations can be restored and match its count, final timestamp, minimum, maximum and mean. If original observations are missing, it remains as a legacy summary. No synthetic temperature series is generated from a summary.

A corrupt archive is a migration error, and the original is kept. Observations that were already discarded and are not in the archive cannot be recovered. An older app version may not read the new format, so before rolling back, quit the app, back up the entire storage directory (`~/Library/Application Support/NenRing/`), and then use the pre-migration history. The backup must include not only the JSONL files but also `.lossless/`, settings, evidence files and journals.

## Analysis and memory

WAF uses the summed Host/NAND deltas of the same original intervals. P/E steps, resets, firmware and build boundaries, research-session exclusions and reliability event time ranges are not changed by storage aggregation. Temperature medians, time-weighted means and cooldowns also use the original series. Thinning points for chart drawing is independent of storage.

Full analysis on a normal refresh and temperature refresh are separate. After building the summary table for past FTL intervals from the full temperature history, memory normally keeps the most recent 35 days. It also retains the range from 30 minutes before the last FTL boundary so the next FTL interval can be split, so a long gap in FTL can extend that window. When an older boundary is added, for example, the stored history is read back to rebuild the summary table. This does not delete stored observations.

SMART and FTL histories and derived analyses still have costs that grow with history. Lossless disk compression does not establish constant memory use or eliminate startup loading. Recent temperatures for charts and temperature summaries for past events are kept distinct.

The former sampling policy is used only when explicitly requested, such as in compatibility tests for the old format. Collection frequency and SSD access frequency are not changed by this storage format.
