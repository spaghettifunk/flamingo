# Build And Test

Flamingo uses the Zig build system. The canonical commands are defined in `../../build.zig`.

## Build

```bash
zig build
```

This builds and installs the `flamingo` executable into Zig's build output. The local binary is available at:

```bash
./zig-out/bin/flamingo
```

## Run

```bash
zig build run
```

Pass arguments to Flamingo after `--`:

```bash
zig build run -- <args>
```

Example using the repository sample config:

```bash
zig build run -- --config ./config.toml
```

## Test

```bash
zig build test
```

The build file roots tests at `../../test_root.zig`. Test files currently live under `../../tests/`.

## Performance Benchmark

```bash
zig build perf
```

This builds and runs the rendering performance benchmark from `../../src/perf_bench.zig` in ReleaseFast mode.

## Formatting

Format changed Zig files with:

```bash
zig fmt <files>
```

Do not run broad formatting over unrelated files during focused patches.

## Makefile Wrappers

`../../Makefile` exists and wraps the same Zig build commands:

| Target | Command |
| --- | --- |
| `make build` | `zig build` |
| `make test` | `zig build test` |
| `make run` | `zig build run` |
| `make run-dev` | `zig build run -- --config ./config.toml` |
| `make perf` | `zig build perf` |
| `make clean` | `rm -rf zig-out .zig-cache` |

The Zig build commands remain the primary commands to document and use in automation.

