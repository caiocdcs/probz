# probz specification

This document is the language-neutral contract for probz. The Zig code is
the reference implementation. A port in another language (Gleam, etc.)
conforms if it:

1. derives every index from the hash rules in §2,
2. reads and writes the wire format in §3, and
3. reproduces every golden vector in `testdata/vectors/` (§4).

Every structure section cites the paper it implements, so each algorithm
can be checked against its source.

Status: format version **1**, pre-1.0. Breaking changes bump the format
version.

---

## 1. API conventions

Names are given in Zig style; ports should use their language's idioms
but keep the same operations and semantics.

| Operation | Meaning |
|---|---|
| `init(allocator, options)` | Create from an options record with defaulted fields. |
| `deinit(allocator)` | Free memory. Structures do not store their allocator. |
| `add(item)` / `addHash(h)` | Insert a byte-string item, or a precomputed 64-bit hash (§2). |
| `contains(item)` / `containsHash(h)` | Membership query (filters). May give false positives, never false negatives. |
| `remove(item)` / `removeHash(h)` | Delete, for filters that support it. |
| `count(item)` | Frequency estimate (sketches). |
| `cardinality()` | Distinct-count estimate (HyperLogLog). |
| `merge(other)` | Combine two structures built with identical parameters. Errors otherwise. |
| `clear()` | Reset to empty, keeping the parameters. |
| `serialize(writer)` / `deserialize(allocator, reader)` | Wire format, §3. |

Every structure that hashes keys accepts either bytes or a precomputed
64-bit hash. Passing the hash lets callers hash once and query several
structures, and lets ports use their own key encoding.

---

## 2. Hashing

### 2.1 Key hash

```
H(item) = XXH64(item, seed = 0)
```

where `item` is a byte string. XXH64 is defined by the
[xxHash specification](https://github.com/Cyan4973/xxHash/blob/dev/doc/xxhash_spec.md).
Check values: `H("") = 0xef46db3751d8e999`, `H("a") = 0xd24ec4f1a98c6e5b`,
`H("abc") = 0x44bc2cf5ad770999`.

The Zig helper `hashKey(value)` hashes typed keys with this byte encoding:

| Type | Bytes hashed |
|---|---|
| byte string | the bytes |
| integer of N bits | N/8 bytes, little-endian two's complement |
| float | the little-endian bytes of its IEEE-754 bit pattern |
| bool | one byte, 0 or 1 |

### 2.2 Double hashing

Structures that need k indexes in `[0, m)` derive them from one hash
`h = H(item)`, following Kirsch & Mitzenmacher:

```
h1 = h & 0xffffffff                 (low 32 bits)
h2 = (h >> 32) | 1                  (high 32 bits, forced odd)
g_i = (h1 + i * h2) mod m           for i = 0, 1, ..., k-1
```

Compute `h1 + i * h2` with exact (≥ 64-bit) integer arithmetic. For
`i < 2^32` it cannot overflow 64 bits.

Reference: Adam Kirsch, Michael Mitzenmacher, "Less Hashing, Same
Performance: Building a Better Bloom Filter", Random Structures &
Algorithms 33(2):187–218, 2008 (ESA 2006).
<https://doi.org/10.1002/rsa.20208> (author PDF:
<https://www.eecs.harvard.edu/~michaelm/postscripts/rsa2008.pdf>).
Theorem 5.2 shows that this scheme keeps the asymptotic false-positive
rate of k independent hashes.

Vector: `testdata/vectors/hash.json`.

### 2.3 PRNG

Structures that make random choices (cuckoo evictions, MinHash
coefficients) use SplitMix64 with an explicit 64-bit seed, so results are
reproducible across languages:

```
next():
  state = state + 0x9e3779b97f4a7c15          (mod 2^64)
  z = state
  z = (z XOR (z >> 30)) * 0xbf58476d1ce4e5b9  (mod 2^64)
  z = (z XOR (z >> 27)) * 0x94d049bb133111eb  (mod 2^64)
  return z XOR (z >> 31)

below(n) = next() mod n
```

Check values for seed 0: `0xe220a8397b1dcdaf`, `0x6e789e6aa1b965f4`,
`0x06c45d188009454f`.

Reference: Guy L. Steele, Doug Lea, Christine H. Flood, "Fast Splittable
Pseudorandom Number Generators", OOPSLA 2014 (ACM SIGPLAN Notices
49(10):453–472). <https://doi.org/10.1145/2714064.2660195>. The constants
match Vigna's reference code, <https://prng.di.unimi.it/splitmix64.c>.

Vector: `testdata/vectors/splitmix64.json`.

---

## 3. Wire format

All integers are **little-endian**. Floats are the little-endian bytes of
their IEEE-754 binary64 bit pattern. A "bytes" field is a `u32` length
followed by that many bytes.

### 3.0 Header

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | magic `"PRBZ"` (`50 52 42 5a`) |
| 4 | 1 | format version, currently `1` |
| 5 | 1 | structure tag |

| Tag | Structure |
|---|---|
| 1 | Bloom filter |
| 2 | Counting Bloom filter |
| 3 | Scalable Bloom filter |
| 4 | Cuckoo filter |
| 5 | Quotient filter |
| 6 | HyperLogLog |
| 7 | Count-Min sketch |
| 8 | Space-Saving (top-k) |
| 9 | t-digest |
| 10 | q-digest |
| 11 | MinHash LSH |

Readers must reject a wrong magic, an unknown version, a tag that differs
from the expected structure, and any body whose lengths contradict its
parameters.

### 3.1 Bit array

Used inside several bodies.

| Field | Type |
|---|---|
| `len` | u64, the number of bits |
| `words` | `ceil(len / 64)` × u64 |

Bit `i` is bit `i mod 64` (LSB = 0) of word `floor(i / 64)`. Bits at
positions ≥ `len` in the last word must be zero.

---

## 4. Golden vectors

`testdata/vectors/<name>.json`, generated by `zig build gen-vectors`.
`zig build test` fails if the files are stale.

- Inputs are the ASCII strings `item-0`, `item-1`, … (`"item-" + decimal i`).
- 64-bit values are written as hex strings (`"0x"` + 16 lowercase digits),
  because JSON numbers lose precision above 2^53.
- Serialized structures are lowercase hex strings of the full wire bytes,
  header included.

---

## 5. Structures

Each structure section gives its parameters, update/query rules, merge
rule, wire body, and references. Sections are added as each structure is
brought to spec.

### 5.1 Bloom filter (tag 1)

**Parameters.** `expected_items` n > 0 and `fp_rate` p in (0, 1), or an
explicit bit count m and hash count k.

```
m = ceil(-n · ln(p) / (ln 2)^2)
k = clamp(round((m / n) · ln 2), 1, 65536)
```

`round` rounds halves away from zero. Example: n = 1000, p = 0.01 gives
m = 9586, k = 7.

**Add / contains.** With `h = H(item)`, the positions are `g_0 … g_{k-1}`
from §2.2 with modulus m. `add` sets all k bits. `contains` returns true
iff all k bits are set.

**Estimated items.** With X set bits: `n* = -(m / k) · ln(1 - X / m)`,
or +∞ if X = m.

**Merge.** Requires equal m and k: bitwise OR (set union).

**Body.**

| Field | Type |
|---|---|
| k | u32 |
| bits | bit array (§3.1), `len` = m |

**References.**
- Burton H. Bloom, "Space/Time Trade-offs in Hash Coding with Allowable
  Errors", CACM 13(7):422–426, 1970. <https://doi.org/10.1145/362686.362692>
- Andrei Broder, Michael Mitzenmacher, "Network Applications of Bloom
  Filters: A Survey", Internet Mathematics 1(4):485–509, 2004, §2.1.
  <https://doi.org/10.1080/15427951.2004.10129096>
- S. Joshua Swamidass, Pierre Baldi, "Mathematical Correction for
  Fingerprint Similarity Measures to Improve Chemical Retrieval",
  J. Chem. Inf. Model. 47(3):952–964, 2007 (item-count estimate).
  <https://doi.org/10.1021/ci600526a>

Vector: `testdata/vectors/bloom_filter.json`.

### 5.2 Counting Bloom filter (tag 2)

**Parameters.** Same as the Bloom filter (§5.1): m cells and k hashes,
plus a counter width w of 2–32 bits (default 4).

**Add.** Increment the k counters `g_0 … g_{k-1}` (§2.2). A counter at
`2^w - 1` stays there (saturates).

**Contains / count.** `count(item)` is the minimum of its k counters, and
`contains` is `count > 0`.

**Remove.** If `count(item) == 0`, return false and change nothing.
Otherwise decrement every one of the k counters that is not saturated,
and return true. Never decrementing a saturated counter rules out the
false negatives that Fan et al. warn about.

**Estimated items.** As §5.1, with X = the number of non-zero counters.

**Merge.** Requires equal m, k, and w: per-cell saturating addition.

**Body.**

| Field | Type |
|---|---|
| w | u8 |
| k | u32 |
| m | u64 |
| counters | m × (ceil(w / 8)-byte little-endian unsigned) |

**References.**
- Li Fan, Pei Cao, Jussara Almeida, Andrei Z. Broder, "Summary Cache: A
  Scalable Wide-Area Web Cache Sharing Protocol", IEEE/ACM Transactions on
  Networking 8(3):281–293, 2000, section "Bloom Filters—the Math".
  <https://doi.org/10.1109/90.851975> (online version:
  <https://pages.cs.wisc.edu/~cao/papers/summary-cache/node8.html>)

Vector: `testdata/vectors/counting_bloom_filter.json`.

### 5.3 Scalable Bloom filter (tag 3)

**Parameters.** Initial capacity n₀ > 0, target rate P in (0, 1), growth
s ≥ 2 (default 2), and tightening r in (0, 1) (default 0.9).

**Stages.** Stage i (from 0) is a Bloom filter (§5.1) built with
`init(expected_items = n_i, fp_rate = P_i)`, where

```
P_0 = P · (1 - r)
P_i = P_0 · r^i            (computed as P_0 · pow(r, i))
n_i = n_0 · s^i
```

The compound rate is bounded by Σ P_i ≤ P₀ / (1 − r) = P.

**Add.** If `contains(item)`, return false and change nothing. Otherwise,
if the newest stage's count has reached n_i, append stage i + 1. Then add
the item to the newest stage, increment that stage's count, and return
true.

**Contains.** True iff any stage contains the item.

**Merge.** Not supported.

**Body.**

| Field | Type |
|---|---|
| n₀ | u64 |
| P | f64 |
| s | u32 |
| r | f64 |
| stage count L | u32 (≥ 1) |
| L × stage | u64 count, u32 k, bit array (§3.1) |

Readers recompute each stage's m and k from the parameters and reject
mismatches.

**Deviation.** The paper uses partitioned ("sliced") filters and a
fill-ratio limit. probz uses standard Bloom filters sized for (n_i, P_i),
which meet the same per-stage rate at capacity.

**References.**
- Paulo Sérgio Almeida, Carlos Baquero, Nuno Preguiça, David Hutchison,
  "Scalable Bloom Filters", Information Processing Letters 101(6):255–261,
  2007: §3 (error bound), §4.1 (s = 2 or 4), §4.2 (r ≈ 0.8–0.9).
  <https://doi.org/10.1016/j.ipl.2006.10.007> (author PDF:
  <https://gsd.di.uminho.pt/members/cbm/ps/dbloom.pdf>)

Vector: `testdata/vectors/scalable_bloom_filter.json`.

### 5.4 Cuckoo filter (tag 4)

**Parameters.** Fingerprint width f of 4–32 bits (default 16), bucket size
b of 1–8 (default 4), bucket count B (a power of two), and a PRNG seed
(default 0). Sizing from a capacity C:
`B = nextPow2(max(1, floor(C / b)))`, doubled once if `C / (B · b) > 0.96`.

**Location.** With `h = H(item)`:

```
fp = (h >> 32) mod 2^f;  if fp == 0 then fp = 1    (0 marks an empty slot)
i1 = (h mod 2^32) mod B
alt(i, fp) = (i XOR ((fp * 0x5bd1e995) mod 2^32)) mod B
i2 = alt(i1, fp)
```

**State.** B·b slots, a count, an optional victim (bucket, fp), and the
PRNG (§2.3).

**Insert(i1, i2, fp).** If the victim is occupied, fail with Full (before
any change). Otherwise increment the count. Put fp in the first empty slot
of bucket i1, or failing that of i2 (scanning slots from 0). If both are
full:

```
bucket = (below(2) == 0) ? i1 : i2
repeat 500 times:
  s = below(b); swap fp with slot s of bucket
  bucket = alt(bucket, fp)
  if bucket has an empty slot: store fp there (first empty), return
victim = (bucket, fp)
```

**Contains.** fp is in bucket i1 or i2, or the victim is (i1 or i2, fp).

**Remove.** Clear the first slot equal to fp in bucket i1, else in i2.
If that succeeded, decrement the count, and if a victim exists, take it
out (count − 1) and run Insert(v.bucket, alt(v.bucket, v.fp), v.fp).
Otherwise, if the victim matches, clear it and decrement the count.
Otherwise return false.

**False-positive bound.** 2b / 2^f (paper Eq. 5).

**Merge.** Not supported.

**Body.** Each fingerprint is written as a ceil(f / 8)-byte little-endian
unsigned value.

| Field | Type |
|---|---|
| f | u8 |
| b | u8 |
| B | u64 |
| count | u64 (must equal the number of non-empty slots plus the victim) |
| PRNG state | u64 |
| victim flag | u8 (0 or 1) |
| victim bucket | u64 |
| victim fp | fingerprint |
| slots | B·b × fingerprint |

**References.**
- Bin Fan, David G. Andersen, Michael Kaminsky, Michael D. Mitzenmacher,
  "Cuckoo Filter: Practically Better Than Bloom", CoNEXT 2014, pp. 75–88:
  §3.1–3.3, Eq. (1), Algorithms 1–2, Eq. (5).
  <https://doi.org/10.1145/2674005.2674994> (author PDF:
  <https://www.cs.cmu.edu/~dga/papers/cuckoo-conext2014.pdf>)
- Reference implementation (victim cache, AltIndex, sizing rule):
  <https://github.com/efficient/cuckoofilter/blob/master/src/cuckoofilter.h>

Vector: `testdata/vectors/cuckoo_filter.json`.

### 5.5 Quotient filter (tag 5)

**Parameters.** q (1–63) and remainder width r (1–32), with q + r ≤ 64.
There are `S = 2^q` slots. Default r = 8.

**Fingerprint.** With `h = H(item)`: `f_r = h mod 2^r` and
`f_q = (h >> r) mod 2^q`.

**State.** Per slot i: remainder `R[i]` and bits `occ[i]`
(is_occupied), `cont[i]` (is_continuation), `shf[i]` (is_shifted). Slot i
is *empty* iff all three bits are 0. Indexes wrap modulo S. The filter
stores a set of (f_q, f_r) pairs, and runs are sorted by remainder in
ascending order.

```
nextOcc(i): j = i+1; while !occ[j]: j = j+1; return j
runStart(fq):                  # requires occ[fq]
  b = fq; while shf[b]: b = b-1
  s = b
  while b != fq:
    s = s+1; while cont[s]: s = s+1
    b = nextOcc(b)
  return s
```

**Contains** (paper Figure 3). If `!occ[fq]`, return false. `s = runStart(fq)`.
Loop: if `R[s] == fr`, return true. If `R[s] > fr`, return false.
`s = s+1`. If `!cont[s]`, return false.

**Add.**
1. If slot fq is empty, set `R[fq] = fr`, `occ[fq] = 1`, count + 1, and
   return true.
2. `existed = occ[fq]`. Set `occ[fq] = 1`. `start = runStart(fq)`, and
   `s = start`.
3. If existed, scan the run. If `R[s] == fr`, return false (already
   present). If `R[s] > fr`, stop. Otherwise `s = s+1`, and stop if
   `!cont[s]`.
4. If count == S: restore `occ[fq] = existed` and fail with Full.
5. `head = (s == start)`. If head and existed, set `cont[s] = 1` (the
   old head becomes a continuation).
6. Shift right: let e be the first empty slot at or after s. For
   j = e, e−1, …, s+1: `R[j] = R[j−1]`, `cont[j] = cont[j−1]`, `shf[j] = 1`.
   `occ` bits do not move.
7. `R[s] = fr`, `cont[s] = !head`, `shf[s] = (s != fq)`, count + 1, and
   return true.

**Remove.**
1. If `!occ[fq]`, return false. `start = runStart(fq)`, and find s with
   `R[s] == fr` as in Contains. If it is not found, return false.
2. `wasHead = (s == start)`. If wasHead and `!cont[s+1]`, set `occ[fq] = 0`.
3. Shift left. Set `cursor = fq`, `hole = s`, `p = s+1`, `first = true`.
   While `shf[p]`:
   - `c = cont[p]`.
   - If first and wasHead and c: `c = 0`, `quot = fq`.
   - Else if !c: `cursor = nextOcc(cursor)`, `quot = cursor`.
   - Write `R[hole] = R[p]`, `cont[hole] = c`, `shf[hole] = c OR (quot != hole)`.
   - `hole = p`, `p = p+1`, `first = false`.
4. Set `R[hole] = 0`, `cont[hole] = shf[hole] = 0`. Count − 1. Return true.

**Iteration.** Start at the first slot b (from 0) with `!shf[b]`, and set
`quot = b`. Visit S slots circularly, skipping empty ones. At a slot p
with `!cont[p]`, set `quot = p` if `!shf[p]`, else `quot = nextOcc(quot)`.
Yield `(quot, R[p])`.

**Merge.** Requires equal q and r: Add every entry of the other filter.

**False-positive bound.** `1 − (1 − 2^−(q+r))^n ≤ n / 2^(q+r) ≤ 2^−r`.

**Body.**

| Field | Type |
|---|---|
| q | u8 |
| r | u8 |
| count | u64 (must equal the number of non-empty slots) |
| remainders | S × (ceil(r / 8)-byte little-endian) |
| occ, cont, shf | 3 × bit array (§3.1), each of length S |

**References.**
- Michael A. Bender, Martin Farach-Colton, Rob Johnson, Russell Kraner,
  Bradley C. Kuszmaul, Dzejla Medjedovic, Pablo Montes, Pradeep Shetty,
  Richard P. Spillane, Erez Zadok, "Don't Thrash: How to Cache Your Hash
  on Flash", PVLDB 5(11):1627–1637, 2012, §3 and Figure 3.
  <https://doi.org/10.14778/2350229.2350275> (PDF:
  <https://vldb.org/pvldb/vol5/p1627_michaelabender_vldb2012.pdf>)

Vector: `testdata/vectors/quotient_filter.json`.

### 5.6 HyperLogLog (tag 6)

**Parameters.** Precision p in [4, 18] (default 14). There are m = 2^p
registers, each a u8, initially 0.

**Add.** With `h = H(item)`:

```
j   = h >> (64 - p)
w   = ((h << p) mod 2^64) OR 2^(p-1)
rho = clz64(w) + 1                  # 1 .. 64 - p + 1
M[j] = max(M[j], rho)
```

**Cardinality** (Flajolet et al., Figure 3, without the 32-bit
large-range correction):

```
alpha = 0.673 (m=16), 0.697 (m=32), 0.709 (m=64), else 0.7213 / (1 + 1.079 / m)
E = alpha · m^2 / Σ_j 2^(-M[j])
V = number of j with M[j] = 0
if E <= 2.5·m and V > 0: return m · ln(m / V)
return E
```

Standard error: 1.04 / √m.

**Merge.** Requires equal p: register-wise max.

**Body.**

| Field | Type |
|---|---|
| p | u8 |
| registers | m × u8 (each ≤ 64 − p + 1) |

**References.**
- Philippe Flajolet, Éric Fusy, Olivier Gandouet, Frédéric Meunier,
  "HyperLogLog: the analysis of a near-optimal cardinality estimation
  algorithm", AofA 2007, DMTCS Proceedings AH:137–156, Figure 3.
  <https://doi.org/10.46298/dmtcs.3545> (PDF:
  <https://algo.inria.fr/flajolet/Publications/FlFuGaMe07.pdf>)
- Stefan Heule, Marc Nunkesser, Alexander Hall, "HyperLogLog in
  Practice", EDBT 2013, pp. 683–692, §5.1.
  <https://doi.org/10.1145/2452376.2452456>

Vector: `testdata/vectors/hyperloglog.json`.

### 5.7 Count-Min sketch (tag 7)

**Parameters.** Width w > 0, depth d > 0, and a counter width (8–64 bits,
default 32). From error bounds: `w = ceil(e / ε)` and
`d = max(1, ceil(ln(1 / δ)))`, for 0 < ε, δ < 1.

**Row indexes.** With `h = H(item)`, let g be SplitMix64 (§2.3) seeded
with h. The column for row j (j = 0 … d−1) is the j-th output
`g.below(w)`. The counter is `C[j · w + column]`.

**Add(item, c).** If any of the d counters, or the total N, would exceed
its maximum, fail without changing anything. Otherwise add c to each of
the d counters and to N.

**Count.** The minimum of the d counters. It is never below the true
count, and with probability ≥ 1 − δ it is at most the true count + ε·N.

**Merge.** Requires equal w, d, and counter width: element-wise addition
plus the totals, failing without changes on overflow.

**Body.**

| Field | Type |
|---|---|
| counter bits | u8 |
| d | u32 |
| w | u64 |
| N | u64 |
| counters | d·w, row-major, each ceil(bits / 8)-byte little-endian |

**Deviation.** The analysis assumes d independent pairwise-independent
hash functions. probz uses SplitMix64 outputs seeded with H(item) so
every row depends only on the 64-bit item hash.

**References.**
- Graham Cormode, S. Muthukrishnan, "An Improved Data Stream Summary: The
  Count-Min Sketch and its Applications", Journal of Algorithms
  55(1):58–75, 2005. <https://doi.org/10.1016/j.jalgor.2003.12.001>
- Parameters and guarantee as restated in Kirsch & Mitzenmacher, Random
  Structures & Algorithms 33(2), 2008, §9.1.
  <https://doi.org/10.1002/rsa.20208>

Vector: `testdata/vectors/count_min_sketch.json`.
