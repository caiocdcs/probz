# probz

Probabilistic data structures for Zig. Each structure follows its published
algorithm, links to the paper it implements, serializes to a portable binary
format, and is pinned by golden test vectors, so implementations in other
languages can produce identical results ([SPEC.md](SPEC.md)).

Requires Zig 0.17.1 or newer.

## Structures

| Structure | Answers | Add | Remove | Merge | Paper |
|---|---|:-:|:-:|:-:|---|
| `BloomFilter` | membership | ✓ | | ✓ | [Bloom 1970](https://doi.org/10.1145/362686.362692) |
| `BlockedBloomFilter` | membership, cache-friendly | ✓ | | ✓ | [Putze et al. 2007](https://doi.org/10.1007/978-3-540-72845-0_9) |
| `CountingBloomFilter(Counter)` | membership, multiplicity | ✓ | ✓ | ✓ | [Fan et al. 2000](https://doi.org/10.1109/90.851975) |
| `ScalableBloomFilter` | membership, growing sets | ✓ | | | [Almeida et al. 2007](https://doi.org/10.1016/j.ipl.2006.10.007) |
| `CuckooFilter(Fingerprint, b)` | membership | ✓ | ✓ | | [Fan et al. 2014](https://doi.org/10.1145/2674005.2674994) |
| `QuotientFilter(r)` | membership, ordered iteration | ✓ | ✓ | ✓ | [Bender et al. 2012](https://doi.org/10.14778/2350229.2350275) |
| `HyperLogLog` | distinct count | ✓ | | ✓ | [Flajolet et al. 2007](https://doi.org/10.46298/dmtcs.3545), [Heule et al. 2013](https://doi.org/10.1145/2452376.2452456) |
| `CountMinSketch(Counter)` | frequency | ✓ | | ✓ | [Cormode & Muthukrishnan 2005](https://doi.org/10.1016/j.jalgor.2003.12.001) |
| `SpaceSaving` | top-k / heavy hitters | ✓ | | | [Metwally et al. 2005](https://doi.org/10.1007/978-3-540-30570-5_27) |
| `TDigest` | quantiles, CDF (floats) | ✓ | | ✓ | [Dunning & Ertl 2019](https://arxiv.org/abs/1902.04023) |
| `QDigest` | quantiles, rank (integers) | ✓ | | ✓ | [Shrivastava et al. 2004](https://doi.org/10.1145/1031495.1031524) |
| `MinHashLSH` | Jaccard similarity search | ✓ | | | [Broder 1997](https://doi.org/10.1109/SEQUEN.1997.666900), [MMDS ch. 3](http://www.mmds.org/) |

`TopKTracker(Estimator)` ranks a known list of candidates using any
structure that has `count(item)`, such as a Count-Min sketch.

Every module's doc comment cites the sections, equations, and algorithms it
follows, and notes any deliberate deviation.

### Choosing a structure

- **Is x in the set?** Use `BloomFilter` when you know the size up front, or
  `ScalableBloomFilter` when you don't. `BlockedBloomFilter` reads one
  cache line per operation: use it when the filter outgrows the CPU cache
  or most lookups miss (about 3% more memory at 1%). If you need deletes, use
  `CuckooFilter` (most compact at low false-positive rates) or
  `QuotientFilter` (supports merge and ordered iteration).
  `CountingBloomFilter` also tracks multiplicity.
- **How many distinct items?** `HyperLogLog`: 16 KiB gives about 0.8% error.
- **How often does x occur?** `CountMinSketch`. It never undercounts, and
  overcounts by at most ε·N with probability 1 − δ.
- **What are the most frequent items?** `SpaceSaving` on a stream, or
  `TopKTracker` over known candidates.
- **What is the p99?** `TDigest` for real values, `QDigest` for integers
  with a hard rank-error bound. `TDigest` defaults to the k₁ scale
  function, which is accurate across all quantiles. If you mostly query
  extreme tails (p99.9, p99.99), `.scale = .k2` is 5–20× more accurate
  there, at the cost of the middle. With k₁ a digest holds about 0.6·δ
  centroids.
- **What is similar to this document?** `MinHashLSH` over shingles or tokens.

## Install

```sh
zig fetch --save git+https://github.com/caiocdcs/probz#v0.1.0
```

```zig
// build.zig
const probz = b.dependency("probz", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("probz", probz.module("probz"));
```

## Usage

```zig
const std = @import("std");
const probz = @import("probz");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var bloom = try probz.BloomFilter.init(allocator, .{ .expected_items = 10_000, .fp_rate = 0.01 });
    defer bloom.deinit(allocator);
    bloom.add("apple");
    std.debug.print("{}\n", .{bloom.contains("apple")}); // true

    // Hash once, use the hash with several structures.
    const h = probz.hash.hashBytes("apple");
    var hll = try probz.HyperLogLog.init(allocator, .{});
    defer hll.deinit(allocator);
    hll.addHash(h);

    // Every structure serializes to the same portable format.
    const bytes = try probz.serde.toOwnedBytes(allocator, bloom);
    defer allocator.free(bytes);
    var reader: std.Io.Reader = .fixed(bytes);
    var copy = try probz.BloomFilter.deserialize(allocator, &reader);
    defer copy.deinit(allocator);
}
```

Conventions shared by all structures:

- `init(allocator, .{ ...options })` and `deinit(allocator)`. Structures don't
  store an allocator, and operations that may allocate take one.
- `add` / `addHash`, `contains` / `containsHash`, `remove`, `count`, `merge`,
  `clear`, `serialize`, `deserialize`. Keys are byte strings, or a
  precomputed XxHash64 from `probz.hash` (`hashBytes`, or `hashKey` for
  integers, floats, and bools).
- Explicit error sets. Operations that cannot fail don't return errors.
- Anything random (cuckoo evictions, MinHash coefficients) uses a seeded
  SplitMix64, so results are reproducible.

See [`examples/`](examples/) for a complete program per structure.

## Build steps

```sh
zig build test                               # unit, statistical and model tests + golden vectors
zig build run-examples                       # run every example
zig build run-example -Dexample=tdigest      # run one example
zig build bench                              # throughput and memory (ReleaseFast)
zig build docs                               # API docs into zig-out/docs
zig build gen-vectors                        # regenerate testdata/vectors after a deliberate change
```

## Benchmarks

Output of `zig build bench` on an Apple M4: 1M pre-hashed keys,
single-threaded, on one machine, so treat the numbers as indicative only.

| Structure | add | query | memory |
|---|--:|--:|--:|
| BloomFilter (p = 1%) | 5 ns | 3 ns | 1.2 MB |
| BlockedBloomFilter (p = 1%) | 2.5 ns | 2.4 ns | 1.24 MB |
| CountingBloomFilter (u4) | 8 ns | 5 ns | 4.8 MB |
| ScalableBloomFilter (n₀ = 10k) | 74 ns | 20 ns | 2.5 MB |
| CuckooFilter (u16, b = 4) | 15 ns | 7 ns | 2.1 MB |
| QuotientFilter (r = 8, 2²¹ slots) | 7 ns | 6 ns | 2.9 MB |
| HyperLogLog (p = 14) | 0.8 ns | 32 ns | 16 KB |
| CountMinSketch (ε = 0.001, δ = 0.01) | 3 ns | 3 ns | 54 KB |
| SpaceSaving (m = 1000) | 16 ns | 9 ns | 47 KB |
| TDigest (δ = 100) | 40 ns | 5 ns | 12 KB |
| QDigest (σ = 2³², k = 256) | 96 ns | 28 µs | 24 KB |

`CountingBloomFilter` packs its counters: 16 `u4` counters per 64-bit word.

The second part of the output hashes 16-byte keys on every operation and
varies the size, following the benchmark setup of
[nalgeon/unsure](https://github.com/nalgeon/unsure) and the
[article](https://antonz.org/probabilistic-data-structures/) that accompanies
it. Selected rows, in ns/op:

| | add | hit / query | miss |
|---|--:|--:|--:|
| BloomFilter 1%, 1M | 7.4 | 7.8 | 20.7 |
| BlockedBloomFilter 1%, 1M | 5.0 | 5.0 | 5.0 |
| BloomFilter 1%, 50M | 31.8 | 30.3 | 36.0 |
| BlockedBloomFilter 1%, 50M | 16.5 | 17.2 | 17.1 |
| CountMinSketch ε = 1e-3 (standard / conservative) | 6.3 / 6.9 | 5.6 | |
| HyperLogLog p = 14 (count, merge) | 1.4 | 29, 667 | |
| TDigest δ = 100 (quantile, merge) | 40 | 6.5, 765 | |

## Other languages

[SPEC.md](SPEC.md) defines the hash contract, every algorithm in enough
detail to reimplement it, and the wire format. `testdata/vectors/*.json`
holds the expected outputs and serialized bytes for fixed inputs. A port
conforms if it reproduces them.

## License

MIT. See [LICENSE](LICENSE).
