# Changelog

## 0.1.0 (unreleased)

First versioned release. Every structure was reviewed against its paper.
The API changed throughout, so expect to update call sites.

### Build and packaging
- Requires Zig 0.16.0.
- The package now exports a `probz` module (`dep.module("probz")`).
  Previously no module was exported, so dependents could not import it.
- New steps: `examples`, `run-example -Dexample=<name>`, `bench`, `docs`,
  and `gen-vectors`. Examples are no longer installed by default.

### Cross-language support
- [SPEC.md](SPEC.md): hash contract (XxHash64, double hashing, SplitMix64),
  per-structure algorithms, and a versioned binary wire format.
- Golden vectors in `testdata/vectors/`. `zig build test` fails if they are
  stale.
- `serialize` / `deserialize` for every structure.

### Bug fixes
- **Bit array:** word indexes were truncated to 8 bits, so any Bloom filter
  over 16,384 bits aliased into its first 256 words. A filter sized for
  100k items at 1% measured a 100% false-positive rate.
- **Cuckoo filter:** a failed insert dropped a stored fingerprint, causing
  false negatives. Now there is a victim cache and `error.Full`.
- **Quotient filter:** rewritten. The old version had no runs, clusters, or
  wraparound: inserts were silently dropped and removes hid other items.
- **Scalable Bloom filter:** the compound false-positive rate could reach
  2× the target. Now P₀ = P·(1 − r).
- **t-digest:** rewritten as the merging t-digest with the k₁ scale
  function. Accuracy no longer depends on the scale of the data, and tail
  accuracy improved about 30×.
- **q-digest:** rewritten as the paper's tree digest, with linear-time
  compress, a structural merge, and an out-of-range error.
- **LSH:** bands no longer collide with each other, seeds are explicit, and
  threshold-based parameter selection was fixed. The generic `LSH(T)`
  (which didn't compile for anything but `u32`) is now `MinHashLSH`.
- **HyperLogLog:** 64-bit hashing and the full rank range.
- **Count-Min sketch:** overflow can no longer partially update counters.
- **TopKTracker:** no longer leaks on allocation failure; candidates are
  deduplicated.

### Added
- `SpaceSaving`: streaming top-k with per-item error bounds.
- `merge` for Bloom, Counting Bloom, Quotient filter, HyperLogLog,
  Count-Min, t-digest, and q-digest. `clear` and `memoryBytes` where
  meaningful.
- `addHash` / `containsHash` / `countHash` on every hashed structure, plus
  `probz.hash.hashKey` for integer, float, and bool keys.
