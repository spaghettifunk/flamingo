# Roadmap

A set of todos without order or priority. Simply grouped by category

## General TODO

- [ ] write a proper README.md with contributions, running the project, etc
- [ ] CI pipeline for running tests and binary creation (GitHub actions as a start)
- [ ] `homebrew` formula for installation
- [ ] write ton of documentation and create a website for it using mkdocs or similar
- [x] UI overhaul using nerdfonts
- [x] git Graphs and commit history panel

## Performance TODO

- [x] implement tree-sitter incremental edits
- [x] introduce async/background parsing yet for syntax highlight
- [ ] implement piece-table to improve editing performance
- [x] find a way to bring FPS to at least 100
- [x] increase scrolling speed
- [x] remove legacy renderer

## Initial Page TODO

- [x] implement "New File" by using a popup to show the filesystem (and navigate it) and create the file
- [x] implement "Open Folder" by selecting a specific folder (and not just `.`) using a popup to show the filesystem (and navigate it)
- [x] implement "Open File" by selecting a specific file using a popup to show the filesystem (and navigate it)
- [x] when starting the editor for the first time, put the configuration file in a specific path like `~/.flamingo/config.toml`
- [x] implement the "Settings" page enabling the editing of the `~/.flamingo/config.toml` file.
- [x] implement opening the current folder with `.` button when the Filesystem pane is open
- [x] UI rehaul for the Filesystem pane
- [x] implement `create project`(or workspace) feature

## Editing TODO

- [x] implement file rename in explorer (and status bar with `:renameFile <path/to/file> <path/to/new_file_name` -- also `:rf <path/to/file> <path/to/new_file_name`)
- [x] implement file deletion in explorer (and status bar with `:deleteFile <path/to/file>` -- also `:df <path/to/file>`)
- [x] implement file creation in explorer (and status bar with `:newFile <path/to/file>` -- also `:nf <path/to/file>`)
- [ ] replace occurrences (all in one go or one by one)
- [x] jump to line
- [x] jump to top/bottom of file
- [x] implement jump between matching `() { } [ ]`
- [x] implement jump to function definition with keybinding `f`
- [x] implement going backwards/forwards like a browser
- [x] syntax highlight for Markdown files
- [x] Tabs with folder name in a different color
- [x] implement `:qall` close all buffers/tabs and exit the editor if no unsaved changes, otherwise ask
- [x] implement `:wall` save all buffers/tabs
- [x] implement folding/unfolding feature for when `{}` are found (add also keybinding)
- [x] BUG: editor doesn't have word-wrapping nor I can scroll right beyond the current size of the terminal. Implement the ability of scrolling the text.
- [x] BUG: cannot scroll the tabs
- [x] implement Comments for non-programming files (like google docs)
- [x] implement TODO list based on both `//TODO` or `//FIXME` etc and actual todo inputs from user

## Plugins System TODO

- [ ] implement the ability to create and load Themes
- [ ] automatic download of LSP servers for language implementation

## New Features

- [x] implement a "Help" popup like LazyVim by doing `:help` showing what the editor can do
- [x] enable the terminal in the editor. It can be a toggle to show/hide the terminal
- [x] implement a multi-key sequences
- [x] implement global search
  - [ ] Regex
  - [ ] Async/background indexing
  - [ ] Persistent search index
  - [x] Preview pane
