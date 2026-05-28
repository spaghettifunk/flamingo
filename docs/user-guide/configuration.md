# Configuration

Flamingo configuration is TOML.

## Config Path Priority

Startup selects a config path in this order:

1. `--config <path>`
2. `FLAMINGO_CONFIG`
3. `~/.flamingo/config.toml`

When the default user config is selected and missing, Flamingo creates `~/.flamingo/config.toml` from `src/config/default_config.toml`. Existing files are not overwritten.

## Main Sections

| Section | Keys | Status |
| --- | --- | --- |
| root | `debug` | Implemented. |
| `[ui]` | `icon_mode` | Implemented. |
| `[explorer]` | `width_percentage` | Implemented. |
| `[agent]` | `provider` | Implemented. |
| `[agent.openai]` | `api_key_env`, `model` | Implemented. |
| `[agent.limits]` | tool/session limits | Parsed. |
| `[author]` | `name`, `email` | Implemented as comments author fallback. |
| `[keybindings.<context>]` | key sequence to canonical command name | Implemented. |
| `[keybindings.<context>.unbind]` | `keys` array | Implemented. |

## Example

The repository default config is embedded from [../../src/config/default_config.toml](../../src/config/default_config.toml). The root [../../config.toml](../../config.toml) is tested to match it.

```toml
debug = false

[ui]
icon_mode = "auto" # auto | nerd_font | unicode | ascii

[explorer]
width_percentage = 20

[agent]
provider = "mock" # mock | openai

[agent.openai]
api_key_env = "OPENAI_API_KEY"
model = "gpt-5-codex"

[author]
name = "Your Name"
email = "you@example.com"

[keybindings.normal]
"ctrl+s" = "file.write"
```

## Keybinding Contexts

Supported config contexts are:

```text
global
normal
insert
command_line
dashboard
explorer
explorer_search
search
global_search
agent
git_diff
task_panel
git_graph
todo_panel
comments_panel
help
terminal
picker
picker_new_file
picker_open_folder
prompt
open_file_prompt
completion
save_confirmation
```

Unknown contexts are rejected. Legacy flat `[keybindings]` fields are rejected.

## Validation

Config parsing and keybinding registry construction happen before entering raw terminal mode. Invalid TOML, unknown keybinding contexts, unknown command names, invalid key spellings, invalid command/context combinations, duplicate user bindings, and prefix conflicts reject startup or settings-config save.

`[ui].icon_mode` controls symbols used in panels and status UI. `FLAMINGO_ICON_MODE=nerd_font|unicode|ascii|auto` overrides config when valid. `auto` is conservative: it uses Unicode when a UTF-8 locale is detected and ASCII otherwise. Flamingo cannot apply a bundled or embedded font from a terminal UI; configure your terminal emulator to use a Nerd Font before forcing `nerd_font`.

Settings-config saves use `config.validateConfigBytesForSave` and keep the editor open if validation fails.

## Project `.flamingo`

Project-local `.flamingo/` is not the user config directory. It is workspace metadata used by features such as manual TODOs and comments:

- `.flamingo/todos.json`
- `.flamingo/comments.json`

See [../features/todos.md](../features/todos.md) and [../features/comments.md](../features/comments.md).
