# Flamingo

Flamingo is a terminal-based modal editor written in Zig. It is a personal editor-engine project focused on fast terminal rendering, configurable workflows, file and folder operations, syntax highlighting, LSP-backed editing features, and integrated project panels.

![mascotte](./docs/images/mascotte.png)

## Status

Flamingo is under active development. It is useful for experimentation, hacking on editor internals, and trying the current feature set, but it should be treated as an early-stage project rather than a stable daily-driver editor.

The repository currently has a compact docs set and a growing implementation. Some workflows are implemented but still evolving, especially project tooling, LSP integration, configuration validation, and long-running background work.

## Installation

The recommended installation path on macOS and Linux is Homebrew:

```bash
brew install spaghettifunk/tap/flamingo
```

Or tap the repository first:

```bash
brew tap spaghettifunk/tap
brew install flamingo
```

After installation, start the editor with:

```bash
flamingo
```

Check the installed binary with:

```bash
flamingo --version
flamingo --help
```

## Requirements

- A terminal environment capable of running a raw-mode terminal editor.
- `git` for Git status and Git Graph features.
- Optional language servers for LSP features:
  - `zls` for Zig
  - `gopls` for Go
  - `vscode-json-languageserver` for JSON
  - `yaml-language-server` for YAML
  - `taplo lsp stdio` for TOML
  - `buf lsp serve` for Protocol Buffers

## Usage

Open Flamingo in the current working directory:

```bash
flamingo
```

Pass paths or other arguments to Flamingo as supported by the current CLI:

```bash
flamingo <args>
```

On startup, Flamingo uses the selected config path in this order:

- `--config <path>`
- `FLAMINGO_CONFIG`
- `~/.flamingo/config.toml`, created from the embedded default config if needed

## Configuration

Flamingo configuration is TOML. The default config includes:

- `debug`
- `[explorer]`
- `[author]`
- context-specific `[keybindings.<context>]` tables

Keybindings map key sequences to canonical command names from `src/editor/commands.zig`. Supported contexts include editor modes and panels such as `normal`, `insert`, `command_line`, `dashboard`, `explorer`, `global_search`, `git_graph`, `todo_panel`, `comments_panel`, `terminal`, `completion`, and related picker/prompt contexts.

See the repository default config at [src/config/default_config.toml](src/config/default_config.toml) and the root sample config at [config.toml](config.toml).

For the current keybinding and command reference, see [docs/keybindings.md](docs/keybindings.md).

## Development

Development requires Zig 0.16.0 or newer, as declared in `build.zig.zon`.

Build and run from source:

```bash
zig build run
```

Pass arguments through the Zig build runner:

```bash
zig build run -- <args>
```

Build the binary without running it:

```bash
zig build
./zig-out/bin/flamingo
```

Run validation:

```bash
zig build
zig build test
zig build perf
```

Format changed Zig files with:

```bash
zig fmt <files>
```

Zig dependencies are declared in `build.zig.zon`; vendored tree-sitter grammars live under `vendor/`.

The build defines the main editor executable, a test step rooted at `test_root.zig`, and a rendering performance benchmark executable.

## Release Process

Flamingo uses a manual, tag-driven GitHub Actions release workflow for v1. This avoids publishing a release on every merge to `main`.

1. Merge release-ready changes to `main`.
2. Run the `release` workflow manually with the desired version, such as `0.1.0`.
3. The workflow validates the version, builds and tests Flamingo, creates tag `v<version>` from `main`, generates a changelog from commits since the previous `v*` tag, packages the macOS binary, uploads `SHA256SUMS.txt`, and creates the GitHub Release.
4. Update the Formula in the [homebrew-tap](https://github.com/spaghettifunk/homebrew-tap)

## Project Docs

Project documentation lives in [`docs/`](docs/index.md). See [docs/roadmap.md](docs/roadmap.md) for the current loose roadmap.

## Contributing

This is a personal editor project, but the repository is structured for local hacking:

- keep changes small and reviewable
- use existing command, keybinding, state, renderer, and runtime patterns
- avoid allocations in render hot paths
- keep parsing, LSP, filesystem scanning, and other long-running work out of the event loop where practical
- update [docs/keybindings.md](docs/keybindings.md) when adding commands or keybindings
- run `zig build test` before submitting changes when practical

## License

Flamingo is licensed under the [MIT License](LICENSE)
