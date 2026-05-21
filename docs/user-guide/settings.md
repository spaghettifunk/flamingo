# Settings

## Status

Partial.

## Overview

The dashboard `Settings` action opens the active Flamingo config file in a normal editor buffer. The buffer kind is marked as `settings_config`, so saves use config validation before writing.

Source files:

- `src/editor/input_router/dispatch.zig`
- `src/editor/filesystem_ops.zig`
- `src/editor/editor.zig`
- `src/config.zig`

## How To Open

From the dashboard:

- Press `ctrl+p`
- Or select `Settings` and press `enter`

## Edited File

The opened file is the active config path selected at startup:

1. `--config <path>`
2. `FLAMINGO_CONFIG`
3. `~/.flamingo/config.toml`

If the active source is the default user config and the file is missing, Flamingo creates the default config before opening it.

## Save Behavior

Saving a settings config buffer validates the entire file. On success, Flamingo writes the file and shows:

```text
Config saved. Restart Flamingo for all settings to take effect.
```

On failure, the save is rejected and the status message starts with:

```text
Config save rejected:
```

## Limitations

- There is no separate interactive settings UI yet.
- Most settings require restarting Flamingo after save.
- TODO: document once live keybinding/config reload behavior is expanded beyond the existing registry refresh helper.

