# Flamingo

Flamingo is a terminal-based modal editor written in Zig. It is a personal editor-engine project focused on fast terminal rendering, configurable workflows, file and folder operations, syntax highlighting, LSP-backed editing features, and integrated project panels.

![mascotte](./docs/images/mascotte.png)

## Status

Flamingo is under active development. It is useful for experimentation, hacking on editor internals, and trying the current feature set, but it should be treated as an early-stage project rather than a stable daily-driver editor.

The repository currently has a compact docs set and a growing implementation. Some workflows are implemented but still evolving, especially project tooling, LSP integration, configuration validation, and long-running background work.

## Features

Implemented:

- Modal editing with Dashboard, Normal, Insert, Command, Search, Global Search, Help, Terminal, Git Graph, and prompt/picker modes.
- Configurable context-specific keybindings via TOML.
- Command prompt and command popup backed by command metadata.
- File tabs, file open/save/write-all/quit-all flows, and save confirmation for unsaved buffers.
- File explorer, filesystem picker, new-file, rename-file, delete-file, open-file, open-folder, and workspace creation flows.
- Normal-mode navigation, jump history, line jumps, matching-bracket jumps, horizontal scrolling, folding, selections, clipboard operations, and multi-cursor editing support.
- Project search/global search with a preview-oriented UI.
- Tree-sitter syntax highlighting for Zig, Go, TOML, YAML, JSON, and Markdown.
- Virtual-screen renderer with diffed terminal output.
- Integrated terminal panel on supported platforms.
- TODO panel for code TODO/FIXME-style items and manual workspace TODOs.
- Comments workflow for supported prose file types, stored under the workspace `.flamingo` directory.
- Git status integration and a read-only Git commit graph panel.
- LSP client plumbing for diagnostics, completions, and go-to-definition where the relevant language server is available.
- Help popup generated from the resolved command/keybinding registry.
- Rendering performance benchmark target.

Partial or still evolving:

- LSP server management expects external language servers; automatic server installation is not implemented.
- Global search exists, but regex search, background indexing, and a persistent search index are still roadmap items.
- Theme/plugin customization is limited; default language plugins are registered in source.
- Documentation is intentionally lightweight and does not yet cover every internal subsystem.

## Screenshots / Demo

Screenshots and recordings have not been added yet.

## Requirements

- Zig 0.16.0 or newer, as declared in `build.zig.zon`.
- A terminal environment capable of running a raw-mode terminal editor.
- `git` for Git status and Git Graph features.
- Optional language servers for LSP features:
  - `zls` for Zig
  - `gopls` for Go
  - `vscode-json-languageserver` for JSON
  - `yaml-language-server` for YAML
  - `taplo lsp stdio` for TOML

Zig dependencies are declared in `build.zig.zon`; vendored tree-sitter grammars live under `vendor/`.

## Quick Start

Build and run the editor:

```bash
zig build run
```

Run with arguments passed to Flamingo:

```bash
zig build run -- <args>
```

Build the binary without running it:

```bash
zig build
./zig-out/bin/flamingo
```

On startup, Flamingo uses the selected config path in this order:

- `--config <path>`
- `FLAMINGO_CONFIG`
- `~/.flamingo/config.toml`, created from the embedded default config if needed

## Development

Common validation commands:

```bash
zig build
zig build test
zig build perf
```

Format changed Zig files with:

```bash
zig fmt <files>
```

The build defines the main editor executable, a test step rooted at `test_root.zig`, and a rendering performance benchmark executable.

## Configuration

Flamingo configuration is TOML. The default config includes:

- `debug`
- `[explorer]`
- `[author]`
- context-specific `[keybindings.<context>]` tables

Keybindings map key sequences to canonical command names from `src/editor/commands.zig`. Supported contexts include editor modes and panels such as `normal`, `insert`, `command_line`, `dashboard`, `explorer`, `global_search`, `git_graph`, `todo_panel`, `comments_panel`, `terminal`, `completion`, and related picker/prompt contexts.

See the repository default config at [src/config/default_config.toml](src/config/default_config.toml) and the root sample config at [config.toml](config.toml).

## Keybindings And Commands

Flamingo is driven by command metadata and a resolved keybinding registry. The `:help` popup reflects defaults, overrides, and unbound keys, while `:` opens command mode for commands such as `:w`, `:q`, `:search`, `:todos`, `:comments`, and `:git-graph`.

For the current keybinding and command reference, see [docs/keybindings.md](docs/keybindings.md).

## Documentation

The docs set is currently small:

| Area                     | Link                                       |
| ------------------------ | ------------------------------------------ |
| Keybindings and commands | [docs/keybindings.md](docs/keybindings.md) |
| Roadmap                  | [docs/roadmap.md](docs/roadmap.md)         |

There is not yet a `docs/index.md` or separate user-guide/reference tree.

## Architecture

The codebase is organized around a small number of editor subsystems:

- `src/main.zig` handles startup, config selection, logging, terminal cleanup, and editor launch.
- `src/config.zig` parses TOML config and builds the keybinding registry.
- `src/editor/` contains editor state, command dispatch, buffer/tab models, filesystem workflows, panels, search, comments, TODOs, Git Graph, syntax integration, and rendering.
- `src/editor/renderer/` contains the virtual-screen renderer and UI views.
- `src/editor/runtime/` contains event queue, background workers, key profiling, and runtime loop pieces.
- `src/lsp/` contains LSP client, manager, protocol, and RPC code.
- `src/plugin/manager.zig` registers built-in language plugin metadata.
- `src/perf/` and `src/perf_bench.zig` contain rendering benchmark support.

## Roadmap / Project Direction

Current project direction, based on the code and roadmap, includes:

- improving editing performance, including future buffer data-structure work
- expanding documentation and eventually adding a docs website
- improving global search with regex, background indexing, and persistent indexing
- tightening configuration validation and user-facing settings flows
- improving LSP behavior while keeping language-server installation explicit for now
- evolving theme/plugin customization over time

See [docs/roadmap.md](docs/roadmap.md) for the current loose roadmap.

## Contributing

This is a personal editor project, but the repository is structured for local hacking:

- keep changes small and reviewable
- use existing command, keybinding, state, renderer, and runtime patterns
- avoid allocations in render hot paths
- keep parsing, LSP, filesystem scanning, and other long-running work out of the event loop where practical
- update [docs/keybindings.md](docs/keybindings.md) when adding commands or keybindings
- run `zig build test` before submitting changes when practical

## License

Flamingo is licensed under the [MIT License](LICENSE).
