# LSP

## Status

Partial.

## Overview

Flamingo has LSP client plumbing for diagnostics, completions, document open/change notifications, and go-to-definition. Language servers are external commands; Flamingo does not install them.

## How To Use It

Open a file with a supported extension and ensure the relevant language server is available on `PATH`.

Supported default language plugins:

| Language | Extensions | Command |
| --- | --- | --- |
| Zig | `.zig`, `.zon` | `zls` |
| Go | `.go` | `gopls` |
| JSON | `.json` | `vscode-json-languageserver --stdio` |
| YAML | `.yaml`, `.yml` | `yaml-language-server --stdio` |
| TOML | `.toml` | `taplo lsp stdio` |

Default completion controls:

| Action | Key |
| --- | --- |
| Auto-trigger completion | `.` in Normal or Insert |
| Trigger completion | `ctrl+space` in Normal or Insert |
| Next item | `down` |
| Previous item | `up` |
| Accept | `enter` |
| Cancel | `esc` |

Default go-to-definition key:

| Action | Key |
| --- | --- |
| Go to definition | `f` in Normal mode |

## Data And Configuration

No user-facing LSP config table is implemented. Built-in plugin metadata is registered in source.

## Implementation Notes

- Plugin defaults: `src/plugin/manager.zig`
- LSP manager: `src/lsp/manager.zig`
- LSP client process/RPC: `src/lsp/client.zig`, `src/lsp/rpc.zig`, `src/lsp/protocol.zig`
- Editor integration: `src/editor/lsp/editor_lsp.zig`
- LSP UI state: `src/editor/state/lsp_ui.zig`
- Completion rendering: `src/editor/renderer/completion_menu.zig`

Open files notify LSP once the client is ready. Buffer changes are batched and flushed after a short delay, and before forced definition requests.

## Limitations

- No automatic language server installation.
- LSP position handling currently uses Flamingo cursor columns as byte offsets; UTF-16 conversion is noted as a TODO in source.
- Completion insertion is simple text insertion; snippet and overwrite handling are TODO.
- LSP setup has built-in language plugins, not user-configurable plugin loading.

