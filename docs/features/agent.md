# Agent

Status: Partial

## Overview

The Agent panel is the local session framework for a future Codex-like workflow. It tracks prompts, Plan/Implementation mode, session status, and structured events, but the backend is currently deterministic and mock-only.

No network calls are made, and the mock agent does not edit files, run real tools, or execute tasks.

## Usage

| Command | Description |
| --- | --- |
| `:agent` | Open the Agent panel. |

## Panel Controls

| Key | Action |
| --- | --- |
| `enter` | Start a mock session with the current prompt. |
| `tab` | Toggle Plan/Implementation mode. |
| `backspace` | Delete one prompt character. |
| `up`, `down` | Scroll events. |
| `pageup`, `pagedown` | Page through events. |
| `ctrl+u`, `ctrl+d` | Page through events. |
| `ctrl+c` | Cancel the running session. |
| `esc` | Close the panel when no session is running. |

## Implementation Notes

Agent sessions are owned by `AgentManager` in editor state. The mock backend runs on a worker thread and sends event and finish messages through the shared runtime event queue. The panel renders from structured session state using the virtual screen renderer.

The session event log is capped at 10,000 events.

## Limitations

- Only one agent session can run at a time.
- Prompt input is single-line.
- Plan and Implementation mode both use mock scripts.
- Tool calls and tool results are simulated.
- There is no OpenAI, Codex CLI, MCP, or LLM integration yet.
- File edits, patch application, real task execution, and approval flows are intentionally out of scope.
