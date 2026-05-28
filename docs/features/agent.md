# Agent

Status: Partial

## Overview

The Agent panel is the local session framework for a future Codex-like workflow. It tracks prompts, Plan/Implementation mode, session status, structured events, patch proposals, and proposal execution. Plan mode uses deterministic local read-only tools to inspect the workspace and produce a structured plan.

The default backend is local and deterministic. The optional OpenAI Codex backend can be selected with `[agent].provider = "openai"` and reads its API key from the configured environment variable only. The agent never edits files directly. Implementation mode creates proposals first; approved proposals can then be applied and validated locally.

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
| `ctrl+c` | Cancel the running session or active execution. |
| `esc` | Close the panel when no session is running. |

## Implementation Notes

Agent sessions are owned by `AgentManager` in editor state. Backends are selected through the `AgentBackend` abstraction and run on worker threads that send event and finish messages through the shared runtime event queue. Plan mode executes a host-controlled read-only tool protocol with `list_files`, `read_file`, `search_text`, `get_git_status`, and `get_git_diff_summary`.

Tool calls are validated by the host before execution. Paths must stay inside the workspace root, `.git` internals are rejected, binary and large file reads are summarized, and search/read outputs are capped before they are shown in the panel.

Implementation mode creates deterministic patch proposals instead of writing files. Proposals are reviewed in `:proposals`; pressing `a` approves the selected proposal, applies it through the local proposal apply service, and runs validation through the Task Runner. Pressing `r` rejects the selected proposal.

The V1 execution pipeline runs `zig build test` and then `zig build` sequentially after a proposal applies. If validation fails, applied file changes remain in the workspace, task output is available in `:tasks`, and the resulting file changes appear naturally in `:gitdiff`.

The session event log is capped at 10,000 events.

## Limitations

- Only one agent session can run at a time.
- Prompt input is single-line.
- Plan mode is deterministic and read-only.
- Implementation mode creates deterministic mock proposals only.
- OpenAI Codex provider support is behind the Agent backend abstraction; live API behavior requires `OPENAI_API_KEY` or the configured env var.
- There is no Codex CLI, MCP, or local-model integration yet.
- Validation commands are hardcoded for now.
- Autonomous patch generation and auto-fix loops are intentionally out of scope.
