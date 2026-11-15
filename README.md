# Probz

Zig library for probabilistic data structures. Requires Zig 0.16.0 or newer.

Data Structures

- [x] Bloom Filter
- [x] Scalable Bloom Filter
- [x] Counting Bloom Filter
- [x] Quotient filter
- [x] Cuckoo Filter
- [x] HyperLogLog
- [x] q-digest
- [x] t-digest
- [x] Top-K
- [x] Count-min sketch
- [x] Locality–Sensitive Hashing

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
- **Top-K** - Find the most frequent items from any frequency estimator
- **T-digest** - High-accuracy quantile estimation, especially for extreme percentiles
- **Q-digest** - Approximate quantile estimation for streaming data
- **Locality-Sensitive Hashing** - Fast approximate similarity search for high-dimensional data

### Running Examples

```bash
# Run specific example
zig build run-example -Dexample=bloom_filter
zig build run-example -Dexample=lsh

# Run all examples
zig build run-examples

# Build all examples into zig-out/bin
zig build examples

# Generate API docs into zig-out/docs
zig build docs
```


## Contributing

Feel free to open an issue or make a PR.
