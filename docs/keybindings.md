# Flamingo Keybindings & Commands Reference

Flamingo is a modal text editor. This document provides a comprehensive reference of all available keybindings and commands.

## Modes

- `i`: **Insert Mode** - Direct text entry.
- `Esc`: **Normal Mode** - Navigation and command execution.
- `:`: **Command Mode** - Execute colon commands (available in Normal and Dashboard modes).
- `/`: **Search Mode** - Incremental search within the current buffer.

---

## Navigation & Movement (Normal Mode)

| Action                       | Keybinding       |
| :--------------------------- | :--------------- |
| **Move Cursor**              | `Arrows`         |
| **Word Jump Left**           | `Option + Left`  |
| **Word Jump Right**          | `Option + Right` |
| **Start of Line**            | `Option + Down`  |
| **End of Line**              | `Option + Up`    |
| **Jump to Top of File**      | `gg`             |
| **Jump to Bottom of File**   | `G`              |
| **Jump to Matching Bracket** | `%`              |
| **Jump to Definition (LSP)** | `f`              |
| **Next Comment Anchor**      | `]c`             |
| **Previous Comment Anchor**  | `[c`             |
| **Next Tab**                 | `Option + ]`     |
| **Previous Tab**             | `Option + [`     |
| **Jump Back (History)**      | `Option + O`     |
| **Jump Forward (History)**   | `Option + P`     |

---

## Editing & General Operations

| Action               | Keybinding                              |
| :------------------- | :-------------------------------------- |
| **Save File**        | `CTRL + S`                              |
| **Quit**             | `CTRL + Q`                              |
| **Undo**             | `CTRL + Z`                              |
| **Redo**             | `CTRL + Y`                              |
| **Select All**       | `CTRL + A`                              |
| **Copy**             | `CTRL + C`                              |
| **Cut**              | `CTRL + X`                              |
| **Paste**            | `CTRL + V`                              |
| **Duplicate Line**   | `CTRL + D`                              |
| **Delete Line**      | `CTRL + Shift + K`                      |
| **Delete Word Back** | `Option + Backspace`                    |
| **Indent**           | `Tab` (Inserts 4 spaces in Insert mode) |

---

## Multi-Cursor & Selection

| Action               | Keybinding                                   |
| :------------------- | :------------------------------------------- |
| **Add Cursor Above** | `CTRL + Option + Up`                         |
| **Add Cursor Below** | `CTRL + Option + Down`                       |
| **Extend Selection** | `Shift + Arrows` (works with word jumps too) |
| **Clear Selections** | `Esc`                                        |

---

## Scrolling (Normal Mode)

| Action                          | Keybinding |
| :------------------------------ | :--------- |
| **Scroll Page Up**              | `PageUp`   |
| **Scroll Page Down**            | `PageDown` |
| **Scroll Left (Small)**         | `zh`       |
| **Scroll Left (Half Page)**     | `zH`       |
| **Scroll Right (Small)**        | `zl`       |
| **Scroll Right (Half Page)**    | `zL`       |
| **Scroll View to Cursor Start** | `zs`       |
| **Scroll View to Cursor End**   | `ze`       |

---

## Folding (Normal Mode)

| Action                         | Keybinding |
| :----------------------------- | :--------- |
| **Fold Current Brace Block**   | `zc`       |
| **Unfold Current Brace Block** | `zo`       |
| **Toggle Current Brace Block** | `za`       |
| **Fold All Brace Blocks**      | `zM`       |
| **Unfold All Brace Blocks**    | `zR`       |
| **Toggle All Brace Blocks**    | `zA`       |

---

## Command Mode Commands (`:`)

Execute these by pressing `:` and typing the command followed by `Enter`.

| Command                   | Alias     | Description                                                |
| :------------------------ | :-------- | :--------------------------------------------------------- |
| `:q`                      |           | Quit current tab / Dashboard                               |
| `:qall`                   | `:qa`     | Quit all open tabs                                         |
| `:q!`                     |           | Force quit (discard unsaved changes)                       |
| `:w [path]`               |           | Write (Save) current buffer to [path] or its original file |
| `:wall`                   | `:wa`     | Write (Save) all modified buffers                          |
| `:wq [path]`              |           | Save and Quit                                              |
| `:newFile <path>`         | `:nf`     | Create a new file at `<path>` and open it                  |
| `:renameFile <old> <new>` | `:rf`     | Rename file from `<old>` to `<new>`                        |
| `:deleteFile <path>`      | `:df`     | Delete file at `<path>`                                    |
| `:search`                 |           | Open project-wide Global Search                            |
| `:help`                   |           | Open the Help popup                                        |
| `:git-graph`              | `:ggraph` | Open the read-only Git commit graph panel                  |
| `:todos`                  |           | Open/focus the workspace TODO panel                        |
| `:comment`                |           | Create a comment from the active text selection            |
| `:comments`               |           | Open/focus the workspace comments panel                    |
| `:comments refresh`       |           | Reload `.flamingo/comments.json`                           |
| `:<number>`               |           | Jump to line `<number>`                                    |
| `:goto <number>`          |           | Jump to line `<number>`                                    |
| `:line <number>`          |           | Jump to line `<number>`                                    |

---

## Panels & Tools

### File Explorer

| Action                     | Keybinding                                                       |
| :------------------------- | :--------------------------------------------------------------- |
| **Toggle Explorer**        | `CTRL + B`                                                       |
| **Switch Focus**           | `CTRL + E` (between Editor, Explorer, right panel, and Terminal) |
| **Move Selection**         | `Up / Down`                                                      |
| **Open File / Toggle Dir** | `Enter`                                                          |
| **New File in Dir**        | `Option + N`                                                     |
| **Rename Node**            | `Option + R`                                                     |
| **Delete Node**            | `Option + Delete`                                                |
| **Search (Fuzzy)**         | `/`                                                              |

### Integrated Terminal

| Action               | Keybinding          |
| :------------------- | :------------------ |
| **Toggle Terminal**  | `CTRL + T`          |
| **Scroll Output**    | `PageUp / PageDown` |
| **Scroll to Bottom** | `Shift + End`       |
| **Return to Editor** | `Esc`               |

### TODO Panel

| Action                 | Keybinding           |
| :--------------------- | :------------------- |
| **Open TODO Panel**    | `:todos`             |
| **Move Selection**     | `Up / Down` or `j/k` |
| **Open Selected TODO** | `Enter` or `o`       |
| **Refresh Code TODOs** | `r`                  |
| **New Manual TODO**    | `n`                  |
| **Edit Manual TODO**   | `e`                  |
| **Delete Manual TODO** | `d`                  |
| **Toggle Done/Open**   | `x`                  |
| **Close TODO Panel**   | `q` or `Esc`         |

### Comments Panel

Comments are available for `.txt`, `.md`, `.markdown`, `.rst`, `.adoc`, and `.org` files in a Flamingo workspace. Creating the first comment lazily creates `.flamingo/comments.json`.

| Action                      | Keybinding   |
| :-------------------------- | :----------- |
| **Create Comment**          | `:comment`   |
| **Open Comments Panel**     | `:comments`  |
| **Move Selection**          | `Up / Down`  |
| **Jump to Anchor**          | `Enter`      |
| **Reply to Thread**         | `r`          |
| **Edit Comment/Reply**      | `e`          |
| **Delete Comment/Reply**    | `d`          |
| **New From Selection**      | `n`          |
| **Reload From Disk**        | `R`          |
| **Close Comments Panel**    | `q` or `Esc` |
| **Next Comment Anchor**     | `]c`         |
| **Previous Comment Anchor** | `[c`         |

### Git Graph Panel

| Action              | Keybinding                |
| :------------------ | :------------------------ |
| **Open Git Graph**  | `:git-graph` or `:ggraph` |
| **Move Selection**  | `Up / Down` or `j/k`      |
| **Page Selection**  | `PageUp / PageDown`       |
| **First Commit**    | `gg`                      |
| **Last Commit**     | `G`                       |
| **Toggle Details**  | `Enter`                   |
| **Refresh Graph**   | `r`                       |
| **Close Git Graph** | `q` or `Esc`              |

### LSP Completion

| Action                 | Keybinding            |
| :--------------------- | :-------------------- |
| **Trigger Completion** | `CTRL + Space` or `.` |
| **Next Item**          | `Down`                |
| **Previous Item**      | `Up`                  |
| **Accept Selection**   | `Enter`               |
| **Cancel Completion**  | `Esc`                 |

### Global Search

| Action              | Keybinding      |
| :------------------ | :-------------- |
| **Next Result**     | `Down` or `Tab` |
| **Previous Result** | `Up`            |
| **Accept Result**   | `Enter`         |
| **Cancel Search**   | `Esc`           |

### Help Popup

| Action          | Keybinding          |
| :-------------- | :------------------ |
| **Open Help**   | `:help`             |
| **Close Help**  | `q` or `Esc`        |
| **Scroll Help** | `Up / Down`         |
| **Page Help**   | `PageUp / PageDown` |

---

## Dashboard (Landing Page)

| Action               | Keybinding  |
| :------------------- | :---------- |
| **New File**         | `CTRL + N`  |
| **Open File**        | `CTRL + O`  |
| **Open Folder**      | `CTRL + F`  |
| **Create Workspace** | `CTRL + W`  |
| **Settings**         | `CTRL + P`  |
| **Quit Flamingo**    | `CTRL + Q`  |
| **Command Prompt**   | `:`         |
| **Navigate Options** | `Up / Down` |
| **Select Option**    | `Enter`     |

---

## Configuring Keybindings

Flamingo supports context-specific keybinding tables in `config.toml`. Bind keys to canonical command names from `src/editor/commands.zig`:

```toml
[keybindings.normal]
"gg" = "navigation.goto_file_start"
"G" = "navigation.goto_file_end"
"ctrl+s" = "file.write"

[keybindings.insert]
"esc" = "mode.normal"
"ctrl+s" = "file.write"

[keybindings.command_line]
"enter" = "command.execute"
"tab" = "command.suggestion_next"
"esc" = "command.cancel"

[keybindings.comments_panel]
"r" = "comments_panel.reply"
"R" = "comments_panel.refresh"

[keybindings.normal.unbind]
keys = ["ctrl+w"]
```

Comment authors can be configured as a fallback when Git identity is unavailable:

```toml
[author]
name = "Davide"
email = "davide@example.com"
```

Supported key spellings include plain sequences like `gg` and `zM`, modifiers like `ctrl+s`, `C-S-k`, `alt+delete`, `shift+tab`, and special keys like `enter`, `esc`, `tab`, `backspace`, arrows, `pageup`, `pagedown`, `home`, `end`, and `space`.

Old flat `[keybindings]` fields have been removed. Use context-specific tables such as `[keybindings.normal]`, `[keybindings.insert]`, and `[keybindings.command_line]`. Printable editor text, prompt text, and terminal PTY input are raw input rather than command keybindings.

The `:help` popup is generated from the same command metadata and resolved keybinding registry, so overrides and unbinds are reflected there automatically. The command popup also uses command metadata for names, aliases, and descriptions.
