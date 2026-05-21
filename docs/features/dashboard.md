# Dashboard

## Status

Implemented.

## Overview

The dashboard is Flamingo's initial mode. It renders an ASCII logo and a selectable action list:

- `New File`
- `Open File`
- `Open Folder`
- `Create Workspace`
- `Settings`
- `Quit`

## How To Use It

| Action | Key |
| --- | --- |
| Move selection | `up`, `down` |
| Activate selection | `enter` |
| New File | `ctrl+n` |
| Open File | `ctrl+o` |
| Open Folder | `ctrl+f` |
| Create Workspace | `ctrl+w` |
| Settings | `ctrl+p` |
| Quit Flamingo | `ctrl+q` |
| Open command prompt | `:` |

The dashboard also accepts command mode for confirmed colon commands such as `:help`, `:search`, and `:q`.

## Data And Configuration

No dashboard-specific config keys are implemented.

Dashboard actions use the active config path for Settings and the current/project root for picker start paths.

## Implementation Notes

- Dashboard state and rendering: `src/editor/dashboard.zig`
- Dashboard input dispatch: `src/editor/input_router/dispatch.zig`
- Default dashboard keybindings: `src/editor/keybindings.zig`
- Dashboard command metadata: `src/editor/commands.zig`

Closing the final tab returns the editor to `Dashboard` mode.

## Limitations

- No recent files list is implemented.
- No theme or dashboard customization config is implemented.

