# Roadmap

A set of todos without order or priority. Simply grouped by category

## General TODO

- [ ] write a proper README.md with contributions, runnign the project, etc
- [ ] CI pipeline for running tests and binary creation (GitHub actions as a start)
- [ ] `homebrew` formula for installation
- [ ] find a way to place the configuration file in a specific path like `~/.flamingo/config.toml` or similar at startup time
- [ ] write ton of documentation and create a website for it using mkdocs or similar

## Performance TODO

- [x] implement tree-sitter incremental edits
- [x] introduce async/background parsing yet for syntax highlight
- [ ] implement piece-table like vim to improve editing performance
- [ ] find a way to bring FPS to at least 100
- [ ] increase scrolling speed

## Initial Page TODO

- [ ] implement "New File" by using a popup to show the filesystem (and navigate it) and create the file
- [ ] implement "Open Folder" by selecting a specific folder (and not just `.`) using a popup to show the filesystem (and navigate it)
- [ ] implement "Open File" by selecting a specific file using a popup to show the filesystem (and navigate it)
- [ ] implement the "Settings" page enabling the editing of the `~/.flamingo/config.toml` file. This step cannot happen until I find a way to automatically put the file in a specific folder at startup time

## Editing TODO

- [ ] jump to line (potentially with `:n` where `n` is the gutter value - not sure though)
- [ ] jump to top/bottom of file
- [ ] implement file rename in explorer (and status bar with `:renameFile <path/to/file> <path/to/new_file_name`)
- [ ] implement file deletion in explorer (and status bar with `:deleteFile <path/to/file>`)
- [ ] implement file creation in explorer (and status bar with `:newFile <path/to/file>`)
- [ ] syntax highlight for Markdown files
- [ ] Tabs with folder name in a different color
- [ ] replace occurrences (all in one go or one by one)
- [ ] implement jump between matching `() { } [ ]`

## Plugins System TODO

- [ ] implement the ability to create and load Themes
- [ ] automatic download of LSP servers for language implementation

## New Features

- [ ] implement a "Help" popup like LazyVim by doing `:help` showing what the editor can do
- [ ] implement the ability to create a new Pane and store the layout in the `~/.flamingo/config.toml`. Something like tmux
- [ ] enable the terminal in the editor or the ability to submit commands via `:shell <comand> <...args>`. It can be a toggle to show/hide the terminal or a fixed panel
