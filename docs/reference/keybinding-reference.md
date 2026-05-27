# Keybinding Reference

Default bindings are defined in `src/editor/keybindings.zig`.

## Global

| Key | Command | Description |
| --- | --- | --- |
| `ctrl+q` | `app.quit_flamingo` | Quit Flamingo. |
| `ctrl+b` | `explorer.toggle` | Toggle explorer. |
| `ctrl+t` | `terminal.toggle` | Toggle integrated terminal. |
| `ctrl+e` | `app.cycle_panel_focus` | Cycle panel focus. |
| `ctrl+w` | `app.close_tab` | Close current tab. |
| `alt+]` | `app.next_tab` | Next tab. |
| `alt+[` | `app.previous_tab` | Previous tab. |

## Normal

| Key | Command | Description |
| --- | --- | --- |
| `i` | `mode.insert` | Enter Insert mode. |
| `:` | `mode.command` | Open command prompt. |
| `/` | `mode.search` | Open current-buffer search. |
| `esc` | `mode.normal` | Clear selection / return to Normal. |
| `alt+o` | `navigation.jump_back` | Jump back. |
| `alt+p` | `navigation.jump_forward` | Jump forward. |
| `gg` | `navigation.goto_file_start` | Go to file start. |
| `G` | `navigation.goto_file_end` | Go to file end. |
| `%` | `navigation.matching_bracket` | Jump to matching bracket. |
| `f` | `lsp.goto_definition` | Request go-to-definition. |
| `zh`, `zl` | `navigation.scroll_left`, `navigation.scroll_right` | Horizontal scroll. |
| `zH`, `zL` | `navigation.scroll_left_half_page`, `navigation.scroll_right_half_page` | Horizontal half-page scroll. |
| `zs`, `ze` | `navigation.scroll_cursor_start`, `navigation.scroll_cursor_end` | Align cursor horizontally. |
| `zc`, `zo`, `za` | `fold.close`, `fold.open`, `fold.toggle` | Current brace-block folding. |
| `zM`, `zR`, `zA` | `fold.close_all`, `fold.open_all`, `fold.toggle_all` | All brace-block folding. |
| `]c`, `[c` | `comments.next_anchor`, `comments.previous_anchor` | Jump comment anchors. |
| Arrows | `navigation.move_*` | Move cursor. |
| `pageup`, `pagedown` | `navigation.page_up`, `navigation.page_down` | Page movement. |
| `alt+down`, `alt+up` | `navigation.line_start`, `navigation.line_end` | Line start/end. |
| `alt+left`, `alt+right` | `navigation.word_left`, `navigation.word_right` | Word movement. |
| Shift movement variants | movement commands | Extend selection while moving. |
| `ctrl+s` | `file.write` | Save current buffer. |
| `ctrl+z`, `ctrl+y` | `editing.undo`, `editing.redo` | Undo/redo. |
| `ctrl+a` | `editing.select_all` | Select all. |
| `ctrl+c`, `ctrl+x`, `ctrl+v` | copy/cut/paste | Clipboard operations. |
| `alt+delete`, `alt+backspace` | `editing.delete_word_back` | Delete word backward. |
| `ctrl+d` | `editing.duplicate_line` | Duplicate line. |
| `ctrl+shift+k`, `ctrl+k` | `editing.delete_line` | Delete line. |
| `ctrl+alt+up`, `ctrl+alt+down` | `editing.add_cursor_above`, `editing.add_cursor_below` | Add cursor. |
| `alt+d` | `editing.select_next_occurrence` | Add next occurrence. |
| `.` | `completion.auto_trigger` | Request completion. |
| `ctrl+space` | `completion.trigger` | Request completion. |

## Insert

| Key | Command | Description |
| --- | --- | --- |
| `esc` | `mode.normal` | Return to Normal. |
| `enter` | `editing.insert_newline` | Insert newline. |
| `backspace` | `editing.delete_back` | Delete backward. |
| `tab` | `editing.indent` | Insert 4 spaces. |
| Arrows, pages, alt movement | navigation commands | Move cursor. |
| Shift movement variants | movement commands | Extend selection while moving. |
| `ctrl+s` | `file.write` | Save current buffer. |
| `ctrl+z`, `ctrl+y` | `editing.undo`, `editing.redo` | Undo/redo. |
| `ctrl+a` | `editing.select_all` | Select all. |
| `ctrl+c`, `ctrl+x`, `ctrl+v` | copy/cut/paste | Clipboard operations. |
| `alt+delete`, `alt+backspace` | `editing.delete_word_back` | Delete word backward. |
| `ctrl+d` | `editing.duplicate_line` | Duplicate line. |
| `ctrl+shift+k`, `ctrl+k` | `editing.delete_line` | Delete line. |
| `ctrl+alt+up`, `ctrl+alt+down` | `editing.add_cursor_above`, `editing.add_cursor_below` | Add cursor. |
| `.` | `completion.auto_trigger` | Request completion. |
| `ctrl+space` | `completion.trigger` | Request completion. |

## Command Prompt

| Key | Command | Description |
| --- | --- | --- |
| `esc` | `command.cancel` | Close command prompt. |
| `backspace` | `command.backspace` | Delete previous character. |
| `tab`, `down` | `command.suggestion_next` | Next suggestion. |
| `up` | `command.suggestion_previous` | Previous suggestion. |
| `enter` | `command.execute` | Execute command. |

## Dashboard

| Key | Command | Description |
| --- | --- | --- |
| `ctrl+n` | `dashboard.new_file` | New file. |
| `ctrl+o` | `dashboard.open_file` | Open file. |
| `ctrl+f` | `dashboard.open_folder` | Open folder. |
| `ctrl+w` | `dashboard.create_workspace` | Create workspace. |
| `ctrl+p` | `dashboard.settings` | Open active config. |
| `ctrl+q` | `app.quit_flamingo` | Quit Flamingo. |
| `:` | `mode.command` | Command prompt. |
| `up`, `down` | dashboard movement | Move selection. |
| `enter` | `dashboard.select` | Activate selection. |

## Explorer

| Key | Command | Description |
| --- | --- | --- |
| `up`, `down` | explorer movement | Move selection. |
| `enter` | `explorer.open_selected` | Open file or toggle directory. |
| `/` | `explorer.search_open` | Start explorer search. |
| `alt+n` | `explorer.new_file` | New file. |
| `alt+r` | `explorer.rename` | Rename selected file. |
| `alt+delete`, `alt+backspace` | `explorer.delete` | Delete selected file. |

## Explorer Search

| Key | Command | Description |
| --- | --- | --- |
| `esc` | `explorer.search_cancel` | Cancel search. |
| `backspace` | `explorer.search_backspace` | Delete query character. |
| `up`, `down` | explorer movement | Move selected result. |
| `enter` | `explorer.open_selected` | Open selected result. |

## Search

| Key | Command | Description |
| --- | --- | --- |
| `esc` | `search.cancel` | Cancel search. |
| `backspace` | `search.backspace` | Delete query character. |
| `enter` | `search.accept` | Accept search. |
| `down` | `search.next_match` | Next match. |
| `up` | `search.previous_match` | Previous match. |

## Global Search

| Key | Command | Description |
| --- | --- | --- |
| `esc` | `global_search.cancel` | Close project search. |
| `backspace` | `global_search.backspace` | Delete query character. |
| `tab`, `down` | `global_search.select_next` | Next result. |
| `up` | `global_search.select_previous` | Previous result. |
| `enter` | `global_search.accept` | Open selected result. |

## TODO Panel

| Key | Command | Description |
| --- | --- | --- |
| `esc`, `q` | `todo_panel.close` | Close panel. |
| `up`, `down` | TODO movement | Move selection. |
| `r` | `todo_panel.refresh` | Refresh code TODOs. |
| `n` | `todo_panel.new` | New manual TODO. |
| `e` | `todo_panel.edit` | Edit manual TODO. |
| `d` | `todo_panel.delete` | Delete manual TODO. |
| `x` | `todo_panel.toggle` | Toggle manual TODO status. |
| `o`, `enter` | `todo_panel.open_selected` | Open selected item. |

## Comments Panel

| Key | Command | Description |
| --- | --- | --- |
| `esc`, `q` | `comments_panel.close` | Close panel. |
| `up`, `down` | comments movement | Move selection. |
| `R` | `comments_panel.refresh` | Reload comments. |
| `r` | `comments_panel.reply` | Reply. |
| `e` | `comments_panel.edit` | Edit. |
| `d` | `comments_panel.delete` | Delete. |
| `n` | `comments_panel.new` | Create from selection. |
| `enter` | `comments_panel.open_selected` | Jump to anchor. |

## Git Diff

| Key | Command | Description |
| --- | --- | --- |
| `esc`, `q` | `git_diff.close` | Close panel. |
| `up`, `k` | `git_diff.move_up` | Move selection up. |
| `down`, `j` | `git_diff.move_down` | Move selection down. |
| `pageup`, `ctrl+u` | `git_diff.page_up` | Page selection up. |
| `pagedown`, `ctrl+d` | `git_diff.page_down` | Page selection down. |
| `r` | `git_diff.refresh_panel` | Refresh diff. |
| `enter` | `git_diff.open_selected` | Open selected file. |

## Git Graph

| Key | Command | Description |
| --- | --- | --- |
| `esc`, `q` | `git_graph.close` | Close panel. |
| `up`, `k` | `git_graph.move_up` | Move to previous commit. |
| `down`, `j` | `git_graph.move_down` | Move to next commit. |
| `pageup`, `pagedown` | page commands | Page selection. |
| `gg` | `git_graph.first` | First commit. |
| `G` | `git_graph.last` | Last loaded commit. |
| `r` | `git_graph.refresh` | Refresh graph. |
| `enter` | `git_graph.toggle_details` | Toggle details. |

## Help

| Key | Command | Description |
| --- | --- | --- |
| `esc`, `q` | `help.close` | Close help. |
| `up`, `down` | `help.scroll_up`, `help.scroll_down` | Scroll. |
| `pageup`, `pagedown` | `help.page_up`, `help.page_down` | Page. |

## Terminal

| Key | Command | Description |
| --- | --- | --- |
| `esc` | `terminal.unfocus` | Return focus to editor. |
| `pageup`, `pagedown` | terminal scroll commands | Scroll output. |
| `shift+end` | `terminal.scroll_bottom` | Scroll to bottom. |

## Filesystem Picker

| Context | Key | Command | Description |
| --- | --- | --- | --- |
| `picker` | `esc` | `picker.cancel` | Close picker. |
| `picker` | `backspace` | `picker.back` | Parent directory or delete name char. |
| `picker` | `up`, `down` | picker movement | Move selection. |
| `picker` | `enter` | `picker.accept` | Accept selection. |
| `picker_new_file` | `space` | `picker.begin_name_input` | Start name entry. |
| `picker_open_folder` | `space` | `picker.select_folder` | Select highlighted folder. |
| `picker_open_folder` | `.` | `picker.select_current_folder` | Select current folder. |

## Prompt

| Key | Command | Description |
| --- | --- | --- |
| `esc`, `n`, `N` | `prompt.cancel` | Cancel prompt. |
| `y`, `Y` | `prompt.confirm` | Confirm delete-style prompt. |
| `enter` | `prompt.submit` | Submit prompt. |
| `backspace` | `prompt.backspace` | Delete input character. |

## Open File Prompt

| Key | Command | Description |
| --- | --- | --- |
| `esc` | `open_file_prompt.cancel` | Cancel. |
| `backspace` | `open_file_prompt.backspace` | Delete input character. |
| `enter` | `open_file_prompt.submit` | Submit. |

## Completion

| Key | Command | Description |
| --- | --- | --- |
| `down` | `completion.next` | Next completion. |
| `up` | `completion.previous` | Previous completion. |
| `enter` | `completion.accept` | Accept completion. |
| `esc` | `completion.cancel` | Cancel completion. |

## Save Confirmation

| Key | Command | Description |
| --- | --- | --- |
| `s`, `S` | `save_confirmation.save` | Save then close. |
| `d`, `D`, `enter` | `save_confirmation.discard` | Discard then close. |
| `esc`, `n`, `N` | `save_confirmation.cancel` | Keep editing. |
