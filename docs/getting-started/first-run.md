# First Run

## Startup

`src/main.zig` handles CLI parsing, config selection, logging setup, signal handlers, terminal cleanup, and launching `editor.start_editor`.

Supported non-interactive CLI forms:

```bash
flamingo --help
flamingo -h
flamingo help
flamingo --version
flamingo version
```

Editor startup accepts only the config option:

```bash
flamingo --config <path>
```

Other CLI arguments are rejected before the editor enters raw terminal mode.

## Config Discovery

Flamingo selects a config path in this order:

1. `--config <path>`
2. `FLAMINGO_CONFIG`
3. `~/.flamingo/config.toml`

When using the default user config path, Flamingo creates `~/.flamingo/` and writes the embedded default config if the file does not already exist. Existing config files are preserved.

Source files:

- `src/main.zig`
- `src/config.zig`
- `src/config/default_config.toml`

## Initial Screen

The editor state starts in `Dashboard` mode. The dashboard renders an ASCII Flamingo logo and these actions:

| Action | Default Key |
| --- | --- |
| New File | `ctrl+n` |
| Open File | `ctrl+o` |
| Open Folder | `ctrl+f` |
| Create Workspace | `ctrl+w` |
| Settings | `ctrl+p` |
| Quit | `ctrl+q` |
| Command prompt | `:` |
| Move selection | `up`, `down` |
| Activate selection | `enter` |

Source files:

- `src/editor/dashboard.zig`
- `src/editor/input_router/dispatch.zig`
- `src/editor/keybindings.zig`

## Opening Files And Folders

From the dashboard, `Open File`, `Open Folder`, and `New File` use the filesystem picker. Opening a folder clears open tabs, sets the project root, builds an explorer tree for that folder, shows the explorer, and enters normal editing mode.

Opening a folder does not automatically create a `.flamingo` workspace marker. `Create Workspace`, the TODO panel, and comments workflows can create that marker when needed.

## Terminal Behavior

Flamingo enters raw terminal mode for the editor loop and restores the terminal on normal exit and on registered process signals. The integrated terminal panel is separate from the main editor terminal and is toggled with `ctrl+t`.

See [../features/terminal.md](../features/terminal.md).

