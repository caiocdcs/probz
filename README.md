# Probz

Zig library for probabilistic data structures.

Data Structures

- [x] Bloom Filter
- [ ] Scalable Bloom Filter
- [ ] Counting Bloom Filter
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

    const has_apple = try bloom.has("apple"); // true
    const has_banana = try bloom.has("banana"); // true
    const has_grape = try bloom.has("grape"); // false

    std.debug.print("Has apple: {}\n", .{has_apple});
    std.debug.print("Has banana: {}\n", .{has_banana});
    std.debug.print("Has grape: {}\n", .{has_grape});

    const estimated_size = bloom.estimatedSize();
    std.debug.print("Estimated items in filter: {}\n", .{estimated_size});
}
```

## Contributing

Feel free to open an issue or make a PR.
