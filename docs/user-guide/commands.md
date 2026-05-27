# Commands

## Command Prompt

Press `:` from Normal or Dashboard mode to open the command prompt. Press `enter` to execute the selected/input command and `esc` to cancel.

The prompt uses command metadata from `src/editor/commands.zig` and execution logic from `src/editor/command.zig`.

## Syntax

Commands are typed without the leading colon in the command buffer, but user documentation shows them with `:`.

Examples:

```text
:w
:w notes.md
:q
:search
:goto 20
```

Most command arguments are split on spaces. `:run` uses a small argv parser with whitespace, single quotes, double quotes, and backslash escaping, and it does not execute through a shell. File operation command paths reject empty paths, whitespace, and quotes. Project-relative paths are resolved inside the active project root when one is set.

## Confirmed Colon Commands

| Command                                             | Arguments          | Description                                                              |
| --------------------------------------------------- | ------------------ | ------------------------------------------------------------------------ |
| `:q`                                                | none               | Quit the current tab or dashboard. Dirty buffers open save confirmation. |
| `:qall`, `:qa`                                      | none               | Quit all tabs, prompting for dirty buffers.                              |
| `:q!`                                               | none               | Force close the current tab.                                             |
| `:w`                                                | optional path      | Write the current buffer to its filename or to the provided path.        |
| `:wall`, `:wa`                                      | none               | Write all modified buffers.                                              |
| `:wq`                                               | optional path      | Write the current buffer, then close the tab.                            |
| `:search`                                           | none               | Open project-wide Global Search.                                         |
| `:help`                                             | none               | Open the generated help popup.                                           |
| `:font-info`                                        | none               | Show the active icon mode, UTF-8 detection, and terminal font guidance.  |
| `:todos`                                            | none               | Open and focus the workspace TODO panel.                                 |
| `:comment`                                          | none               | Create a comment from the active selection in a supported prose file.    |
| `:comments`                                         | optional `refresh` | Open the comments panel, or reload comments from disk.                   |
| `:gitdiff`                                          | none               | Open the workspace Git Diff panel.                                       |
| `:gitdiff-refresh`, `:diff-refresh`, `:git-refresh` | none               | Refresh Git diff gutter markers for the current file.                    |
| `:run <command>`                                    | command argv       | Run a non-interactive task from the workspace root.                      |
| `:tasks`                                            | none               | Open the task output panel.                                              |
| `:taskstop`                                         | none               | Cancel the currently running task.                                       |
| `:git-graph`, `:ggraph`                             | none               | Open the read-only Git commit graph panel.                               |
| `:newFile`, `:nf`                                   | path               | Create a new file and open it.                                           |
| `:renameFile`, `:rf`                                | old path, new path | Rename a file and update open buffers.                                   |
| `:deleteFile`, `:df`                                | path               | Delete a regular file that is not open in the editor.                    |
| `:<number>`                                         | line number        | Jump to the line number.                                                 |
| `:goto`                                             | line number        | Jump to the line number.                                                 |
| `:line`                                             | line number        | Jump to the line number.                                                 |

See [../reference/command-reference.md](../reference/command-reference.md) for the reference table.

## Command Popup

The command popup shows a bounded set of command suggestions. `tab` and `down` select the next suggestion; `up` selects the previous suggestion. `enter` accepts the selected suggestion before execution.

## Limitations

- Inline command arguments in keybinding config are rejected.
- Only commands represented by `src/editor/command.zig` are executable as colon commands.
- Canonical command names such as `mode.insert` are keybinding targets, not colon commands.
