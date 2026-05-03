# Roadmap

A set of todos without order or priority. Simply grouped by category

## General TODO

- [ ] write a proper README.md with contributions, runnign the project, etc
- [ ] CI pipeline for running tests and binary creation (GitHub actions as a start)
- [ ] `homebrew` formula for installation
- [ ] find a way to place the configuration file in a specific path like `~/.flamingo/config.toml` or similar at startup time
- [ ] write ton of documentation and create a website for it using mkdocs or similar
- [ ] UI overhaul using nerdfonts

## Performance TODO

- [x] implement tree-sitter incremental edits
- [x] introduce async/background parsing yet for syntax highlight
- [ ] implement piece-table like vim to improve editing performance
- [x] find a way to bring FPS to at least 100
- [x] increase scrolling speed

## Initial Page TODO

- [ ] implement "New File" by using a popup to show the filesystem (and navigate it) and create the file
- [ ] implement "Open Folder" by selecting a specific folder (and not just `.`) using a popup to show the filesystem (and navigate it)
- [ ] implement "Open File" by selecting a specific file using a popup to show the filesystem (and navigate it)
- [ ] implement the "Settings" page enabling the editing of the `~/.flamingo/config.toml` file. This step cannot happen until I find a way to automatically put the file in a specific folder at startup time

## Editing TODO

- [ ] implement file rename in explorer (and status bar with `:renameFile <path/to/file> <path/to/new_file_name` -- also `:rf <path/to/file> <path/to/new_file_name`)
- [ ] implement file deletion in explorer (and status bar with `:deleteFile <path/to/file>` -- also `:df <path/to/file>`)
- [ ] implement file creation in explorer (and status bar with `:newFile <path/to/file>` -- also `:nf <path/to/file>`)
- [ ] replace occurrences (all in one go or one by one)
- [x] jump to line
- [x] jump to top/bottom of file
- [x] implement jump between matching `() { } [ ]`
- [ ] implement jump to function definition
- [x] implement going backwards/forwards like a browser
- [ ] syntax highlight for Markdown files
- [ ] Tabs with folder name in a different color

## Plugins System TODO

- [ ] implement the ability to create and load Themes
- [ ] automatic download of LSP servers for language implementation

## New Features

- [ ] implement a "Help" popup like LazyVim by doing `:help` showing what the editor can do
- [ ] implement the ability to create a new Pane and store the layout in the `~/.flamingo/config.toml`. Something like tmux
- [ ] enable the terminal in the editor or the ability to submit commands via `:shell <comand> <...args>`. It can be a toggle to show/hide the terminal or a fixed panel
- [x] implement a multi-key sequences
- [x] implement global search
  - [ ] Regex
  - [ ] Async/background indexing
  - [ ] Persistent search index
  - [x] Preview pane
