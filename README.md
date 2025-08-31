# Probz

Zig library for probabilistic data structures. Compatible with Zig 0.15.1.

Data Structures

- [x] Bloom Filter
- [x] Scalable Bloom Filter
- [x] Counting Bloom Filter
- [x] Quotient filter
- [x] Cuckoo Filter
- [x] HyperLogLog
- [x] q-digest
- [ ] t-digest
- [ ] Top-K
- [x] Count-min sketch
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

## Examples

See the [`examples/`](examples/) directory for complete working examples of all data structures:

- **Bloom Filter** - Basic probabilistic membership testing
- **Counting Bloom Filter** - Bloom filter with removal support
- **Scalable Bloom Filter** - Auto-scaling for growing datasets
- **Quotient Filter** - Space-efficient alternative with deletion
- **Cuckoo Filter** - High-performance filter with excellent deletion support
- **HyperLogLog** - Probabilistic cardinality estimation with merge support
- **Count-Min Sketch** - Approximate frequency estimation with sublinear space
- **Q-digest** - Approximate quantile estimation for streaming data

### Running Examples

```bash
# Run specific example
zig build run-example -- bloom_filter

# Run all examples
zig build run-examples

# See available examples
zig build --help
```


## Contributing

Feel free to open an issue or make a PR.
