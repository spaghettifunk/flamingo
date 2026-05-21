# Debugging

This page collects practical ways to investigate Flamingo locally.

## Local Reproduction

Run the editor from the repository with:

```bash
zig build run
```

Run with explicit arguments after `--`:

```bash
zig build run -- <args>
```

Use the repository sample config when investigating config or keybinding behavior:

```bash
zig build run -- --config ./config.toml
```

## Logs

Flamingo initializes logging from `src/main.zig` through `src/logger.zig`.

Confirmed behavior:

- With `debug = true`, logs are written to `flamingo.log`.
- With `debug = false`, logging is disabled.

The root `config.toml` and embedded `src/config/default_config.toml` currently set `debug = true`.

## Performance Instrumentation

Confirmed environment variables:

| Variable | Behavior |
| --- | --- |
| `FLAMINGO_PERF` | Enables perf sampler logging. |
| `FLAMINGO_PERF_KEYS` | Writes key timing data to `/tmp/flamingo-perf-keys.log`. |

The implementation lives in `../../src/perf/` and `../../src/editor/runtime/key_profile.zig`.

## Useful Searches

Use ripgrep to follow behavior through the codebase:

```bash
rg "EditorMode|mode" src
rg "Command|command" src/editor src
rg "keybinding|Keybinding|unbind" src config.toml docs README.md
rg "config.toml|flamingo" src README.md docs config.toml
rg "TODO|todos|comment|git graph|terminal|lsp|tree-sitter|syntax" src docs README.md
```

## Validation During Debugging

Run tests after behavior changes:

```bash
zig build test
```

Run the performance benchmark after rendering, cursor movement, syntax, or large-buffer changes:

```bash
zig build perf
```

Run a normal build before packaging or release-oriented work:

```bash
zig build
```

## Common Investigation Areas

| Problem Area | Starting Points |
| --- | --- |
| Startup/config issues | `../../src/main.zig`, `../../src/config.zig`, `../../tests/config_test.zig` |
| Keybinding or command dispatch | `../../src/editor/keybindings.zig`, `../../src/editor/commands.zig`, `../../src/editor/input_router/` |
| Rendering artifacts | `../../src/editor/renderer/renderer.zig`, `../../src/editor/renderer/virtual_screen.zig` |
| Buffer edits | `../../src/editor/model/buffer.zig`, `../../tests/buffer_test.zig` |
| Search issues | `../../src/editor/search.zig`, `../../src/editor/global_search.zig` |
| Syntax issues | `../../src/editor/syntax.zig`, `../../src/editor/runtime/syntax_worker.zig`, `../../src/editor/queries/` |
| LSP issues | `../../src/lsp/`, `../../src/editor/lsp/editor_lsp.zig`, `../../src/plugin/manager.zig` |
| Terminal issues | `../../src/editor/terminal_panel.zig`, `../../tests/terminal_test.zig` |

