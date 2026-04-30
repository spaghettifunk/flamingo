# Flaming Text Editor

Thinking of something that I want to use everyday.

## General TODO

- [ ] `homebrew` formula
- [ ] CI pipeline for running tests and binary creation
- [ ] find a way to place the configuration file in a specific path like `~/.flamingo/config.toml` or similar

## Performance TODO

- [ ] implement tree-sitter incremental edits
- [ ] introduce async/background parsing yet for syntax highlight
- [ ] implement pierce-table like vim to improve editing performance
- [ ] find a way to bring FPS to at least 100

## Initial Page TODO

- [ ] implement "New File" by using a popup to show the filesystem (and navigate it) and create the file
- [ ] implement "Open Folder" by selecting a specific folder (and not just `.`) using a popup to show the filesystem (and navigate it)
- [ ] implement "Open File" by selecting a specific file using a popup to show the filesystem (and navigate it)
- [ ] implement the "Settings" page enabling the editing of the `~/.flamingo/config.toml` file. This step cannot happen until I find a way to automatically put the file in a specific folder at startup time

## Editing TODO

- [ ] increase scrolling speed
- [ ] jump to line (based on the gutter value)
- [ ] jump to top/bottom of file
- [ ] implement file rename in explorer (and status bar with `:renameFile <path/to/file> <path/to/new_file_name`)
- [ ] implement file deletion in explorer (and status bar with `:deleteFile <path/to/file>`)
- [ ] implement file creation in explorer (and status bar with `:newFile <path/to/file>`)
- [ ] syntax highlight for Markdown files
- [ ] Tabs with folder name in a different color

## Plugins System TODO

- [ ] implement the ability to create and load Themes
- [ ] Automatic download of LSP servers for language implementation
