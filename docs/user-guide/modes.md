# Modes

Flamingo stores its top-level mode in `EditorMode` in `src/editor/state/state.zig`.

| Mode | Purpose | Enter | Leave | Notes |
| --- | --- | --- | --- | --- |
| `Dashboard` | Initial screen and dashboard actions. | Startup or closing the final tab. | Open a file/folder, create a file, `:`, or quit. | Shows `New File`, `Open File`, `Open Folder`, `Create Workspace`, `Settings`, and `Quit`. |
| `Normal` | Navigation, commands, panels, selections, and non-text editing. | Open a buffer or press `esc` from Insert. | `i`, `:`, `/`, panel focus, or overlays. | Normal mode supports multi-key sequences such as `gg`, `zc`, and `]c`. |
| `Insert` | Text insertion and editing. | `i` from Normal. | `esc`. | Printable characters insert into the buffer. Many editing and movement commands remain available. |
| `Command` | Colon command prompt with suggestions. | `:` from Normal or Dashboard. | `enter` executes, `esc` cancels. | Backed by `src/editor/command_popup.zig` and `src/editor/command.zig`. |
| `Search` | Current-buffer literal search. | `/` from Normal. | `enter` accepts, `esc` cancels. | Search is case-insensitive literal matching. |
| `GlobalSearch` | Project-wide path/content search popup. | `:search`. | `enter` opens selection, `esc` cancels. | Content search starts at query length 2. |
| `FilesystemPicker` | File/folder picker for dashboard flows. | Dashboard actions. | `esc` cancels; accepting a result closes it. | Modes include open file, open folder, and new-file location. |
| `Prompt` | Generic text/confirmation prompt. | Explorer, TODO, comments workflows. | `enter`, `y`, `n`, or `esc` depending on prompt kind. | Used for rename, delete confirmations, TODO entry, and comment entry. |
| `OpenFilePrompt` | Legacy direct open-file prompt. | TODO: verify current user entry path. | `enter` or `esc`. | The mode exists in code, but dashboard file opening now uses `FilesystemPicker`. |
| `GitDiff` | Read-only workspace diff panel. | `:gitdiff`. | `q` or `esc`. | Shows changed files and unified hunks for unstaged changes. |
| `TaskPanel` | Non-interactive task output panel. | `:run <command>` or `:tasks`. | `q` or `esc`. | Streams stdout/stderr from workspace-root commands and supports cancellation. |
| `Agent` | Mock agent session panel. | `:agent`. | `esc` when no session is running. | Captures a prompt, toggles Plan/Implementation mode, and streams deterministic mock events. |
| `GitGraph` | Read-only Git commit graph panel. | `:git-graph` or `:ggraph`. | `q` or `esc`. | Blocks other mode handling while active. |
| `Help` | Help popup generated from commands and keybindings. | `:help`. | `q` or `esc`. | Shows resolved defaults, overrides, and unbound keys. |
| `Terminal` | Focused integrated terminal panel. | `ctrl+t`. | `esc`. | Printable input is sent to the PTY where supported. |
| `SaveConfirmation` | Unsaved-buffer close confirmation. | Close dirty tab with `:q`, `ctrl+w`, or `:qall`. | `s`, `d`, `enter`, `esc`, or `n`. | `enter` discards by default. |

## Panel Focus

Explorer, TODO, comments, and terminal focus are tracked separately from top-level modes. `ctrl+e` cycles focus between the editor, explorer, right-side TODO/comments panel, and terminal when those panels are visible.

## Known Limitations

- There is no timeout-based multi-key resolver. Prefix conflicts are rejected during keybinding registry validation.
- `OpenFilePrompt` exists in the state model, but the current dashboard file picker path uses `FilesystemPicker`.
- Some workflows are overlays or focused panels rather than distinct `EditorMode` enum values.
