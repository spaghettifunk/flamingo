# Installation

## Prerequisites

Confirmed from the repository:

| Requirement | Notes |
| --- | --- |
| Zig 0.16.0 or newer | `build.zig.zon` sets `.minimum_zig_version = "0.16.0"`. |
| Git | Used by normal repository workflows and by Git status / Git Graph features at runtime. |
| A terminal | Flamingo runs as a raw-mode terminal editor. |

Optional runtime tools:

| Tool | Used For |
| --- | --- |
| `zls` | Zig LSP support. |
| `gopls` | Go LSP support. |
| `vscode-json-languageserver --stdio` | JSON LSP support. |
| `yaml-language-server --stdio` | YAML LSP support. |
| `taplo lsp stdio` | TOML LSP support. |

Tree-sitter grammars for Zig, Go, TOML, YAML, JSON, Markdown, and Markdown inline syntax are vendored under `vendor/`.

## Clone And Build

```bash
git clone <flamingo-repo-url>
cd flamingo
zig build
```

The build installs the editor executable at:

```bash
./zig-out/bin/flamingo
```

Run the built binary directly with:

```bash
./zig-out/bin/flamingo
```

Non-interactive checks are implemented:

```bash
./zig-out/bin/flamingo --version
./zig-out/bin/flamingo --help
```

## Notes

- Zig dependencies are declared in `build.zig.zon`.
- The integrated terminal backend is implemented for Linux and macOS in `src/editor/terminal_panel.zig`.
- Homebrew instructions exist in the README, but this documentation focuses on repository-local build and development workflows.

