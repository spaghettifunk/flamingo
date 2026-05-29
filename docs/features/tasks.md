# Tasks

Status: Partial

## Overview

The task runner starts non-interactive workspace commands and streams stdout and stderr into a dedicated panel. It is intended for build, test, format, and validation commands such as `zig build` and `zig build test`.

## Usage

| Command | Description |
| --- | --- |
| `:run <command>` | Start a task from the workspace root. |
| `:tasks` | Open the task output panel. |
| `:taskstop` | Cancel the running task. |

The command is tokenized into argv directly. Flamingo supports whitespace, single quotes, double quotes, and backslash escaping, but does not execute through a shell.

## Panel Controls

| Key | Action |
| --- | --- |
| `down` | Scroll output down. |
| `up` | Scroll output up. |
| `pagedown`, `ctrl+d` | Page output down. |
| `pageup`, `ctrl+u` | Page output up. |
| `[`, `]` | Select previous or next task. |
| `r` | Rerun the selected finished task. |
| `c`, `ctrl+c` | Cancel the running task. |
| `q`, `esc` | Close the panel. |

## Implementation Notes

Task state is owned by `TaskManager` in editor state. Process execution runs on a worker thread, captures stdout and stderr through pipes, and forwards task lifecycle/output events through the shared runtime event queue. Output is capped at 10,000 lines per task.

Agent proposal execution reuses this same task path for validation. The agent execution pipeline queues `zig build test` and `zig build` sequentially after an approved proposal applies; output remains inspectable in `:tasks`.

## Limitations

- Only one task can run at a time.
- Commands are non-interactive and are not PTY-backed.
- Shell syntax such as pipes, redirects, and environment assignment is not interpreted.
- There is no problem matcher or staging integration yet.
