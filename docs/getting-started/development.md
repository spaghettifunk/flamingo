# Development

## Canonical Commands

Use the Zig build steps defined in `build.zig`:

```bash
zig build
zig build run
zig build run -- <args>
zig build test
zig build perf
```

Format changed Zig files with:

```bash
zig fmt <files>
```

The repository also has a `Makefile` with wrappers such as `make build`, `make test`, `make run`, `make run-dev`, and `make perf`, but the canonical commands documented by the build are the Zig commands above.

## Run Modes

`zig build run` builds and runs the editor through Zig's build system.

```bash
zig build run
```

Arguments after `--` are passed to Flamingo:

```bash
zig build run -- --config ./config.toml
```

`zig build` builds the installed artifact without launching the editor:

```bash
zig build
./zig-out/bin/flamingo
```

## Validation Loop

For normal code changes:

```bash
zig build
zig build test
```

For rendering or input-loop performance-sensitive changes:

```bash
zig build perf
```

See [../contributing/build-and-test.md](../contributing/build-and-test.md) and [../contributing/performance.md](../contributing/performance.md).

