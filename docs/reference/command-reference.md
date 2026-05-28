# Command Reference

Command metadata lives in `src/editor/commands.zig`. Colon command execution lives in `src/editor/command.zig`.

## Executable Colon Commands

| Command            | Arguments          | Description                                                                              | Source                    |
| ------------------ | ------------------ | ---------------------------------------------------------------------------------------- | ------------------------- |
| `:q`               | none               | Quit current tab or dashboard. Dirty buffers open save confirmation.                     | `src/editor/command.zig`  |
| `:qall`            | none               | Quit all open tabs.                                                                      | `src/editor/command.zig`  |
| `:qa`              | none               | Alias for `:qall`.                                                                       | `src/editor/commands.zig` |
| `:q!`              | none               | Force quit current tab.                                                                  | `src/editor/command.zig`  |
| `:w`               | optional path      | Write current buffer to its filename or provided path.                                   | `src/editor/command.zig`  |
| `:wall`            | none               | Write all modified buffers.                                                              | `src/editor/command.zig`  |
| `:wa`              | none               | Alias for `:wall`.                                                                       | `src/editor/commands.zig` |
| `:wq`              | optional path      | Write current buffer, then close tab.                                                    | `src/editor/command.zig`  |
| `:search`          | none               | Open project-wide Global Search.                                                         | `src/editor/command.zig`  |
| `:help`            | none               | Open generated help popup.                                                               | `src/editor/command.zig`  |
| `:font-info`       | none               | Show active icon mode, UTF-8 detection, and Nerd Font setup guidance in the status line. | `src/editor/command.zig`  |
| `:todos`           | none               | Open workspace TODO panel.                                                               | `src/editor/command.zig`  |
| `:comment`         | none               | Create comment from active text selection.                                               | `src/editor/command.zig`  |
| `:comments`        | optional `refresh` | Open comments panel or reload `.flamingo/comments.json`.                                 | `src/editor/command.zig`  |
| `:gitdiff`         | none               | Open read-only workspace Git diff panel.                                                 | `src/editor/command.zig`  |
| `:gitdiff-refresh` | none               | Refresh Git diff gutter markers for the current file.                                    | `src/editor/command.zig`  |
| `:diff-refresh`    | none               | Alias for `:gitdiff-refresh`.                                                            | `src/editor/commands.zig` |
| `:git-refresh`     | none               | Alias for `:gitdiff-refresh`.                                                            | `src/editor/commands.zig` |
| `:agent`           | none               | Open the mock Agent session panel.                                                       | `src/editor/command.zig`  |
| `:run`             | command argv       | Run a non-interactive task from the workspace root.                                      | `src/editor/command.zig`  |
| `:tasks`           | none               | Open the task output panel.                                                              | `src/editor/command.zig`  |
| `:taskstop`        | none               | Cancel the currently running task.                                                       | `src/editor/command.zig`  |
| `:git-graph`       | none               | Open read-only Git commit graph.                                                         | `src/editor/command.zig`  |
| `:ggraph`          | none               | Alias for `:git-graph`.                                                                  | `src/editor/commands.zig` |
| `:renameFile`      | old path, new path | Rename a file and update open buffers.                                                   | `src/editor/command.zig`  |
| `:rf`              | old path, new path | Alias for `:renameFile`.                                                                 | `src/editor/commands.zig` |
| `:deleteFile`      | path               | Delete a regular file that is not open.                                                  | `src/editor/command.zig`  |
| `:df`              | path               | Alias for `:deleteFile`.                                                                 | `src/editor/commands.zig` |
| `:newFile`         | path               | Create a new file and open it.                                                           | `src/editor/command.zig`  |
| `:nf`              | path               | Alias for `:newFile`.                                                                    | `src/editor/commands.zig` |
| `:<number>`        | line number        | Jump to line.                                                                            | `src/editor/command.zig`  |
| `:goto`            | line number        | Jump to line.                                                                            | `src/editor/command.zig`  |
| `:line`            | line number        | Jump to line.                                                                            | `src/editor/command.zig`  |

## Canonical Keybinding Commands

Canonical command names are the strings used in config keybinding tables. They are not all executable as colon commands.

| Category           | Examples                                                                                           | Source                    |
| ------------------ | -------------------------------------------------------------------------------------------------- | ------------------------- |
| App and tabs       | `app.quit_flamingo`, `app.close_tab`, `app.next_tab`, `app.previous_tab`, `app.cycle_panel_focus`  | `src/editor/commands.zig` |
| File               | `file.write`, `file.write_all`, `file.write_quit`, `file.rename`, `file.delete`, `file.new`        | `src/editor/commands.zig` |
| Modes              | `mode.normal`, `mode.insert`, `mode.command`, `mode.search`                                        | `src/editor/commands.zig` |
| Navigation         | `navigation.move_up`, `navigation.goto_file_start`, `navigation.goto_line`, `navigation.jump_back` | `src/editor/commands.zig` |
| Search             | `search.open`, `search.next_match`, `search.accept`, `global_search.accept`                        | `src/editor/commands.zig` |
| Explorer           | `explorer.toggle`, `explorer.open_selected`, `explorer.rename`, `explorer.delete`                  | `src/editor/commands.zig` |
| Dashboard          | `dashboard.new_file`, `dashboard.open_file`, `dashboard.settings`                                  | `src/editor/commands.zig` |
| TODOs              | `todos.open`, `todo_panel.new`, `todo_panel.toggle`, `todo_panel.open_selected`                    | `src/editor/commands.zig` |
| Comments           | `comments.create`, `comments.open`, `comments_panel.reply`, `comments_panel.open_selected`         | `src/editor/commands.zig` |
| Git                | `git_diff.open`, `git_diff.refresh`, `git_diff.refresh_panel`, `git_graph.open`, `git_graph.refresh` | `src/editor/commands.zig` |
| Agent              | `agent.open`, `agent.submit`, `agent.toggle_mode`, `agent.cancel`, `agent.page_down`              | `src/editor/commands.zig` |
| Tasks              | `tasks.run`, `tasks.open`, `tasks.stop`, `task_panel.cancel`, `task_panel.rerun`                   | `src/editor/commands.zig` |
| Terminal           | `terminal.toggle`, `terminal.unfocus`, `terminal.scroll_bottom`                                    | `src/editor/commands.zig` |
| Completion and LSP | `completion.trigger`, `completion.accept`, `lsp.goto_definition`                                   | `src/editor/commands.zig` |
| Prompt and picker  | `prompt.submit`, `picker.accept`, `save_confirmation.save`                                         | `src/editor/commands.zig` |

For all canonical names, inspect the `command_metadata` table in `src/editor/commands.zig`.

## Argument Notes

- `:w [path]` and `:wq [path]` set the current buffer filename when a path is provided.
- `:newFile`, `:renameFile`, and `:deleteFile` split arguments on spaces.
- `:run <command>` tokenizes command argv with whitespace, quotes, and backslash escaping, and does not execute through a shell.
- File operation paths reject whitespace and quotes.
- Project-relative paths are resolved inside the active project root when one exists.
