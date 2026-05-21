# Architecture

This page describes the current source layout and the major runtime paths in Flamingo.

## Source Map

| Area | Source |
| --- | --- |
| Startup and CLI handling | `../../src/main.zig` |
| Config parsing and validation | `../../src/config.zig`, `../../src/config/default_config.toml` |
| Editor state and mode enum | `../../src/editor/state/state.zig` |
| Main editor object | `../../src/editor/editor.zig` |
| Buffers and tabs | `../../src/editor/model/buffer.zig`, `../../src/editor/model/tab.zig` |
| Commands and metadata | `../../src/editor/command.zig`, `../../src/editor/commands.zig` |
| Keybindings | `../../src/editor/keybindings.zig` |
| Input routing | `../../src/editor/input_router/router.zig`, `../../src/editor/input_router/dispatch.zig`, `../../src/editor/input_router/normal_sequence.zig` |
| Rendering | `../../src/editor/renderer/renderer.zig`, `../../src/editor/renderer/editor_render.zig`, `../../src/editor/renderer/virtual_screen.zig` |
| Runtime loop and background work | `../../src/editor/runtime/loop.zig`, `../../src/editor/runtime/event_queue.zig`, `../../src/editor/runtime/background.zig` |
| Syntax highlighting | `../../src/editor/syntax.zig`, `../../src/editor/syntax_editor.zig`, `../../src/editor/runtime/syntax_worker.zig`, `../../src/editor/queries/` |
| LSP | `../../src/lsp/`, `../../src/editor/lsp/editor_lsp.zig`, `../../src/plugin/manager.zig` |
| Panels and project features | `../../src/editor/explorer.zig`, `../../src/editor/filesystem_picker.zig`, `../../src/editor/global_search.zig`, `../../src/editor/todos.zig`, `../../src/editor/comments.zig`, `../../src/editor/git_graph.zig`, `../../src/editor/terminal_panel.zig` |
| Performance benchmark | `../../src/perf_bench.zig`, `../../src/perf/` |

## Startup Path

`src/main.zig` handles command-line flags, config path selection, logger setup, terminal setup and cleanup, and editor launch.

The config path is selected in this order:

1. `--config <path>`
2. `FLAMINGO_CONFIG`
3. `~/.flamingo/config.toml`

If the home config does not exist, Flamingo creates it from the embedded default config.

After setup, main initializes terminal state, loads configuration, constructs the editor runtime, and enters the editor loop.

## Editor State And Model

The central mode enum lives in `src/editor/state/state.zig`. Confirmed modes include Dashboard, Normal, Insert, Command, Search, GlobalSearch, GitGraph, Help, Terminal, FilesystemPicker, Prompt, OpenFilePrompt, and SaveConfirmation.

The editor model is split between:

- `src/editor/editor.zig` for the primary editor object and high-level operations.
- `src/editor/model/buffer.zig` for text buffer state and editing operations.
- `src/editor/model/tab.zig` for tab state.
- `src/editor/state/` for editor state helpers such as jump history and LSP UI state.

Allocator ownership matters in this area. When adding fields that own memory, make the deinit path clear and keep borrowed slices distinct from owned allocations.

## Input Routing

Input flows through `src/editor/input_router/router.zig` and `src/editor/input_router/dispatch.zig`.

The router resolves the active context from editor state, consults the keybinding registry, and dispatches canonical command identifiers. Normal-mode multi-key sequences are handled by `src/editor/input_router/normal_sequence.zig`.

Raw text entry remains context-specific. Insert mode inserts text, prompt-like contexts edit prompt buffers, search contexts edit search queries, and completion/picker/panel modes intercept only their relevant controls.

## Commands

Command metadata lives in `src/editor/commands.zig`. This is the canonical registry for command identifiers, labels, descriptions, supported contexts, and default keybindings.

Colon command parsing and execution live in `src/editor/command.zig`. Colon commands cover save/quit flows, line jumps, file operations, help, search, TODOs, comments, and Git Graph.

When adding a command, keep the metadata, dispatch path, help output, docs, and default keybindings aligned.

## Config And Keybindings

`src/config.zig` parses TOML config, validates keybinding contexts, validates command names against command metadata, rejects legacy flat keybinding config, handles unbind tables, and builds the runtime keybinding registry.

The embedded default config is `src/config/default_config.toml`. The root `config.toml` is a sample/dev config and is tested against the embedded default by `tests/config_test.zig`.

## Rendering Pipeline

Rendering is centered on `src/editor/renderer/renderer.zig` and `src/editor/renderer/editor_render.zig`.

The virtual screen implementation in `src/editor/renderer/virtual_screen.zig` builds terminal output through a screen buffer and writes only changed cells where possible. Panel-specific views live in separate renderer modules, including terminal, TODOs, comments, Git Graph, statusline, tabbar, popups, and completion menu.

Avoid adding avoidable allocation or expensive string work to frame rendering paths. Prefer precomputed state, reusable buffers, and moving work into input handling or background workers.

## Panels And Features

Feature state is mostly organized as editor modules:

- Dashboard: `src/editor/dashboard.zig`
- Explorer: `src/editor/explorer.zig`
- Filesystem picker: `src/editor/filesystem_picker.zig`
- Search: `src/editor/search.zig`
- Global search: `src/editor/global_search.zig`
- TODO panel: `src/editor/todos.zig`
- Comments: `src/editor/comments.zig`
- Git Graph: `src/editor/git_graph.zig`
- Terminal panel: `src/editor/terminal_panel.zig`
- Workspace metadata: `src/editor/workspace.zig`

Renderer code for those features usually lives under `src/editor/renderer/`.

## Syntax And LSP

Tree-sitter syntax support is implemented in `src/editor/syntax.zig`, `src/editor/syntax_editor.zig`, `src/editor/runtime/syntax_worker.zig`, and query files under `src/editor/queries/`.

Built-in language plugin metadata is registered in `src/plugin/manager.zig`. Current language server commands are external dependencies; Flamingo does not install them.

LSP protocol, RPC, client, and manager code live under `src/lsp/`, with editor-facing integration in `src/editor/lsp/editor_lsp.zig`.

## Runtime And Background Work

The runtime loop is under `src/editor/runtime/`. Important files include:

- `loop.zig` for the main loop pieces.
- `event_queue.zig` for editor runtime events.
- `syntax_worker.zig` for background syntax parsing.
- `git_status_worker.zig` for periodic Git status refreshes.
- `movement_coalesce.zig` and `key_profile.zig` for responsiveness and instrumentation helpers.

Keep long-running work out of direct input handling and rendering. Prefer event queue handoff, worker state, and coalesced updates when the operation can take noticeable time.

