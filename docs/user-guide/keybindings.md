# Keybindings

Flamingo resolves keybindings from a central registry in `src/editor/keybindings.zig`.

## Model

Keybindings are context-specific. A key can do different things in `normal`, `insert`, `command_line`, `dashboard`, `explorer`, `terminal`, and other contexts.

Default bindings are compiled into `src/editor/keybindings.zig`. User config can override or unbind defaults through `[keybindings.<context>]` tables in TOML.

## Normal Mode Sequences

Normal mode supports multi-key sequences up to 4 chords. Confirmed defaults include:

| Key | Action |
| --- | --- |
| `gg` | Go to file start. |
| `G` | Go to file end. |
| `%` | Jump to matching bracket. |
| `zh`, `zl` | Horizontal scroll left/right. |
| `zH`, `zL` | Horizontal scroll half-page left/right. |
| `zs`, `ze` | Align cursor to view start/end. |
| `zc`, `zo`, `za` | Fold, unfold, or toggle current brace block. |
| `zM`, `zR`, `zA` | Fold, unfold, or toggle all brace blocks. |
| `]c`, `[c` | Jump to next/previous comment anchor. |

The resolver has no timeout. Resolved bindings are validated so one keybinding is not a prefix of another in the same context.

## Insert And Prompt Text

Printable text in Insert mode inserts directly into the buffer unless it is bound to a command such as `tab`.

Printable text in command, search, picker, and prompt contexts updates the active text input when it is not a command key.

Printable terminal input is passed to the integrated terminal PTY when the terminal is focused. The terminal pass-through itself is intentionally not modeled as command keybindings.

## Unbinding

User config can remove defaults with an `unbind` subtable:

```toml
[keybindings.normal.unbind]
keys = ["ctrl+w"]
```

Unbinding a key that does not match a default binding emits a warning. Duplicate or conflicting user bindings are rejected.

## Key Spellings

Confirmed key spellings include:

- Plain sequences: `gg`, `G`, `zM`
- Modifiers: `ctrl+s`, `C-S-k`, `alt+delete`, `option+backspace`, `ctrl+alt+up`
- Special keys: `enter`, `return`, `esc`, `escape`, `tab`, `backspace`, `delete`, arrows, `pageup`, `pagedown`, `home`, `end`, `space`
- Multi-chord sequences separated by whitespace, such as `ctrl+x ctrl+s`

See [../reference/keybinding-reference.md](../reference/keybinding-reference.md) for defaults by context.

