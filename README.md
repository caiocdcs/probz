# Probz

Zig library for probabilistic data structures.

Data Structures

- [x] Bloom Filter
- [ ] Scalable Bloom Filter
- [x] Counting Bloom Filter
- [ ] Quotient filter
- [ ] Cuckoo Filter
- [ ] HyperLogLog
- [ ] q-digest
- [ ] t-digest
- [ ] Top-K
- [ ] Count-min sketch
- [ ] Locality–Sensitive Hashing

## Adding to a project
Run the following command to add the package to your project.

```sh
zig fetch --save git+https://github.com/caiocdcs/probz#main
```

Then add it as an import in your `build.zig` file.

```zig
const probz = b.dependency("probz", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("probz", probz.module("probz"));
```

## How to use it

### Bloom filter

```zig
const std = @import("std");
const BloomFilter = @import("probz").BloomFilter;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a bloom filter expecting 1000 items with 1% false positive rate
    var bloom = try BloomFilter.init(allocator, 1000, 0.01);
    defer bloom.deinit();

    // Add some items to the filter
    try bloom.set("apple");
    try bloom.set("banana");

    _ = try bloom.has("apple"); // true
    _ = try bloom.has("banana"); // true
    _ = try bloom.has("grape"); // false

    const estimated_size = bloom.estimatedSize();
    std.debug.print("Estimated items in filter: {}\n", .{estimated_size});
}
```

### Counting Bloom Filter

```zig
const std = @import("std");
const CountingBloomFilter = @import("probz").CountingBloomFilter;

// Default counting bloom filter with u4 counters, up to 16 items
const DefaultCountingBloomFilter = @import("probz").DefaultCountingBloomFilter;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create with custom counter size (u8 allows up to 255 occurrences)
    var cbf = try CountingBloomFilter(u8).init(allocator, 100, 0.01);
    defer cbf.deinit();

    try cbf.add("apple");
    try cbf.add("apple");
    try cbf.add("banana");

    _ = cbf.has("apple"); // true
    _ = cbf.has("banana"); // true
    _ = cbf.has("grape"); // false

    // Fast removal - caller ensures item exists
    cbf.remove("apple");
    const still_has_apple = cbf.has("apple"); // true

    cbf.remove("apple");
    const no_apple = cbf.has("apple"); // false

    try cbf.removeSafe("banana");
    try cbf.removeSafe("banana");
}
```

**Important**: `remove()` is fast but requires the caller to ensure the item exists via `has()`. For automatic safety checking, use `removeSafe()` instead.


## Contributing

Feel free to open an issue or make a PR.
