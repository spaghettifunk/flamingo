# Config Reference

Config parsing lives in `src/config.zig`. The embedded default config is [../../src/config/default_config.toml](../../src/config/default_config.toml).

## Root Keys

| Key | Type | Default | Description | Status |
| --- | --- | --- | --- | --- |
| `debug` | bool | `false` | Enables debug logging through `src/logger.zig`. When enabled, logs are written to `flamingo.log`. | Implemented |

## `[ui]`

| Key | Type | Default | Description | Status |
| --- | --- | --- | --- | --- |
| `icon_mode` | `auto`, `nerd_font`, `unicode`, or `ascii` | `auto` | Selects the icon set. `auto` honors `FLAMINGO_ICON_MODE` when valid, then uses Unicode in UTF-8 locales and ASCII otherwise. | Implemented |

Terminal applications cannot switch the terminal emulator font automatically. Configure your terminal to use a Nerd Font, then set `icon_mode = "nerd_font"` or `FLAMINGO_ICON_MODE=nerd_font`.

## `[explorer]`

| Key | Type | Default | Description | Status |
| --- | --- | --- | --- | --- |
| `width_percentage` | `u8` | `20` | Explorer width as a percentage of terminal width. Used by viewport and render layout code. | Implemented |

## `[agent]`

| Key | Type | Default | Description | Status |
| --- | --- | --- | --- | --- |
| `provider` | `mock` or `openai` | `mock` | Selects the active Agent backend. | Implemented |

## `[agent.openai]`

| Key | Type | Default | Description | Status |
| --- | --- | --- | --- | --- |
| `api_key_env` | string | `OPENAI_API_KEY` | Environment variable used to read the OpenAI API key. Secrets are never stored in config. | Implemented |
| `model` | string | `gpt-5-codex` | OpenAI model used by the Codex backend. | Implemented |

## `[agent.limits]`

| Key | Type | Default | Description | Status |
| --- | --- | --- | --- | --- |
| `max_file_reads` | `usize` | `50` | Maximum file-read tool calls allowed during one session. | Parsed |
| `max_search_results` | `usize` | `100` | Maximum search results allowed during one session. | Parsed |
| `max_tool_calls` | `usize` | `100` | Maximum total tool calls allowed during one session. | Parsed |

## `[author]`

| Key | Type | Default | Description | Status |
| --- | --- | --- | --- | --- |
| `name` | optional string | `null` | Fallback comment author name when Git identity is unavailable. | Implemented |
| `email` | optional string | `null` | Fallback comment author email when Git identity is unavailable. | Implemented |

## `[languages.protobuf.lsp]`

Overrides the default protobuf LSP command. By default Flamingo uses `buf lsp serve` with LSP language ID `proto`.

`[languages.protobuf].extensions` may also override protobuf LSP file extensions. Values can be written with or without a leading dot.

| Key | Type | Default | Description | Status |
| --- | --- | --- | --- | --- |
| `[languages.protobuf].extensions` | array of strings | `["proto"]` | Extensions mapped to the protobuf LSP plugin. | Implemented |
| `command` | optional string | `buf` | Executable to start for protobuf LSP. | Implemented |
| `args` | array of strings | `["lsp", "serve"]` | Arguments passed after `command`. | Implemented |
| `language_id` | optional string | `proto` | LSP language ID sent in `textDocument/didOpen`. | Implemented |

Example:

```toml
[languages.protobuf.lsp]
command = "protols"
args = []
language_id = "protobuf"
```

## `[keybindings]`

Keybindings use context-specific subtables. The flat legacy `[keybindings]` model is rejected.

Supported contexts:

| Context | Description | Status |
| --- | --- | --- |
| `global` | Global commands such as quit, explorer, terminal, tabs, and focus cycling. | Implemented |
| `normal` | Normal-mode navigation, actions, sequences, search, command mode, completion. | Implemented |
| `insert` | Insert-mode editing, movement, save, completion, and return to Normal. | Implemented |
| `command_line` | Command prompt controls. | Implemented |
| `dashboard` | Dashboard actions. | Implemented |
| `explorer` | Explorer navigation and file actions. | Implemented |
| `explorer_search` | Explorer search prompt controls. | Implemented |
| `search` | Current-buffer search controls. | Implemented |
| `global_search` | Project search controls. | Implemented |
| `agent` | Agent panel controls. | Implemented |
| `git_diff` | Git Diff panel controls. | Implemented |
| `task_panel` | Task output panel controls. | Implemented |
| `git_graph` | Git Graph panel controls. | Implemented |
| `todo_panel` | TODO panel controls. | Implemented |
| `comments_panel` | Comments panel controls. | Implemented |
| `help` | Help popup controls. | Implemented |
| `terminal` | Terminal focus and scroll controls. | Implemented |
| `picker` | Filesystem picker common controls. | Implemented |
| `picker_new_file` | New-file picker extra controls. | Implemented |
| `picker_open_folder` | Open-folder picker extra controls. | Implemented |
| `prompt` | Generic prompt controls. | Implemented |
| `open_file_prompt` | Legacy open-file prompt controls. | Implemented in state/dispatch; TODO: verify user entry path. |
| `completion` | LSP completion popup controls. | Implemented |
| `save_confirmation` | Dirty-buffer close confirmation controls. | Implemented |

## Keybinding Tables

| Key | Type | Default | Description | Status |
| --- | --- | --- | --- | --- |
| `[keybindings.<context>]` entries | string to string | none | Maps key sequence text to a canonical command name from `src/editor/commands.zig`. | Implemented |
| `[keybindings.<context>.unbind].keys` | array of strings | none | Removes matching default bindings from the resolved registry. | Implemented |

Example:

```toml
[keybindings.normal]
"ctrl+s" = "file.write"
"gg" = "navigation.goto_file_start"

[keybindings.normal.unbind]
keys = ["ctrl+w"]
```

## Validation Behavior

| Condition | Result |
| --- | --- |
| Invalid TOML | Rejected by TOML parser. |
| Invalid `[ui].icon_mode` | Error. |
| Unknown keybinding context | Error. |
| Legacy flat keybinding field | Error. |
| Invalid key spelling | Error. |
| Unknown canonical command name | Error. |
| Command used in a context where it is not allowed | Error. |
| Duplicate user binding in one context | Error. |
| Prefix conflict in resolved bindings | Error. |
| Unbind that matches no default binding | Warning. |
| Inline command args in config | Error; not supported yet. |
