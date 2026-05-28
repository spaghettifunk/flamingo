# Agent

Status: Partial

## Overview

The Agent panel is the local session framework for a future Codex-like workflow. It tracks prompts, Plan/Implementation mode, session status, structured events, and patch proposals. Plan mode uses deterministic local read-only tools to inspect the workspace and produce a structured plan.

No network calls are made, and the agent does not edit files directly or execute tasks.

## Usage

| Command | Description |
| --- | --- |
| `:agent` | Open the Agent panel. |
| `:proposals` | Open the proposal review panel. |

## Panel Controls

| Key | Action |
| --- | --- |
| `enter` | Start a session with the current prompt. |
| `tab` | Toggle Plan/Implementation mode. |
| `backspace` | Delete one prompt character. |
| `up`, `down` | Scroll events. |
| `pageup`, `pagedown` | Page through events. |
| `ctrl+u`, `ctrl+d` | Page through events. |
| `ctrl+c` | Cancel the running session. |
| `esc` | Close the panel when no session is running. |

## Implementation Notes

Agent sessions are owned by `AgentManager` in editor state. The backend runs on a worker thread and sends event and finish messages through the shared runtime event queue. Plan mode executes a host-controlled read-only tool protocol with `list_files`, `read_file`, `search_text`, `get_git_status`, and `get_git_diff_summary`.

Tool calls are validated by the host before execution. Paths must stay inside the workspace root, `.git` internals are rejected, binary and large file reads are summarized, and search/read outputs are capped before they are shown in the panel.

Implementation mode creates deterministic patch proposals instead of writing files. Proposals are reviewed in `:proposals`; pressing `a` approves and applies the selected proposal, while `r` rejects it. Applied proposals write through the local proposal apply service and then appear naturally in `:gitdiff`.

The session event log is capped at 10,000 events.

## Limitations

- Only one agent session can run at a time.
- Prompt input is single-line.
- Plan mode is deterministic and read-only.
- Implementation mode creates deterministic mock proposals only.
- There is no OpenAI, Codex CLI, MCP, or LLM integration yet.
- Real task execution, validation pipelines, and autonomous patch generation are intentionally out of scope.
