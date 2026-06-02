# Dogfood Prompt: Improve Agent Context Debug Panel

## Context

You are running inside Flamingo-Codex.

Flamingo has recently implemented:

- Agent sessions
- Agent panel
- Plan mode
- Read-only agent tools
- Patch proposal system
- Proposal review UI
- Agent execution pipeline
- Task runner
- Workspace Git diff panel
- Agent policy/approval/audit layer
- Agent context builder + prompt packaging

This is the first dogfooding task for Flamingo-Codex itself.

Be conservative. Prefer small, reviewable changes. Do not make broad architectural changes.

## Goal

Improve the `:agentcontext` debug view so it is useful for inspecting what context Flamingo-Codex is sending to an agent backend.

The panel should make it easy to debug:

- system prompt
- user prompt
- agent mode
- workspace summary
- git status summary
- git diff summary
- selected relevant files
- skipped files and skip reasons
- available tools
- policy summary
- validation commands
- context budget usage
- truncation warnings

## Required Behavior

When the user runs:

```text
:agentcontext
```

Flamingo should open a read-only context inspection panel.

The panel should show a clear sectioned layout:

```text
Agent Context

Mode:
Plan

Budget:
81 KiB / 256 KiB
Truncated: no

Workspace:
Root: /path/to/flamingo
Git: yes
Project: Zig

Git Status:
M src/editor/agent/context_panel.zig
M src/editor/agent/context_builder.zig

Relevant Files:
1. src/editor/agent/context_builder.zig
   Reason: matched prompt keyword "context"
   Size: 18 KiB
   Truncated: no

2. src/editor/agent/policy.zig
   Reason: policy summary source
   Size: 11 KiB
   Truncated: no

Skipped Files:
.env
Reason: possible secret file

zig-out/bin/flamingo
Reason: generated/binary output

Tools:
- list_files
- read_file
- search_text
- get_git_status
- get_git_diff_summary
- create_patch_proposal

Policy:
Plan mode is read-only.
Implementation mode requires patch proposals.
Patch application requires approval.
Validation commands must use Task Runner.

Validation:
- zig build test
- zig build

System Prompt:
...
```

The exact visual design should follow Flamingo’s existing panel style.

## Navigation

Support basic read-only navigation:

```text
j / Down       scroll down
k / Up         scroll up
Ctrl+d/PageDn  page down
Ctrl+u/PageUp  page up
gg             jump to top if multi-key support exists
G              jump to bottom if already supported
q / Esc        close panel
```

If `gg` or `G` are not easy to wire into this panel, skip them.

## Section Folding

If simple, allow toggling sections open/closed.

Suggested keys:

```text
Enter   toggle current section
za      toggle current section if folding infrastructure exists
```

This is nice-to-have. Do not make the task large just to implement folding.

## Search

If the editor already has panel-local search support, wire it into this panel.

If not, do not implement a new search system in this task.

## Safety Constraints

Do not expose secrets.

The panel must not display:

```text
.env contents
API keys
tokens
private keys
*.pem contents
*.key contents
```

If such files are detected by the context builder, show only the path and skip reason.

Do not add any new agent permissions.

Do not modify the policy model unless necessary for displaying an existing policy summary.

Do not add OpenAI/Codex API calls.

Do not run network calls.

## Implementation Constraints

Reuse existing structures from the context builder.

Do not duplicate context-generation logic inside the panel.

The panel should consume an existing `AgentContextPackage` or request one from the context builder.

Prefer this flow:

```text
:agentcontext
  -> build or fetch latest AgentContextPackage
  -> render read-only panel
```

If there is no active agent session, show an empty state:

```text
No active agent context.

Start an agent session with :agent, or generate a context package for the current workspace.
```

If it is easy and safe, allow the panel to generate a context package from the current workspace without a running session.

## Agent Context Summary

Also improve the compact context summary inside the Agent panel.

It should show something like:

```text
Context:
Files: 5 selected, 3 skipped
Git changes: 2 files
Tools: 6
Budget: 81 KiB / 256 KiB
Truncated: no
```

## Tests

Add or update tests for:

```text
context panel renders basic package
context panel renders skipped files without contents
context panel shows budget usage
context panel shows truncation warning
context panel handles no active session
context panel handles empty git status
compact context summary formatting
```

If UI rendering tests are difficult, test the formatter that converts `AgentContextPackage` into renderable lines/sections.

Prefer a pure formatter function that is easy to unit test.

## Validation

Run:

```text
zig build test
zig build
```

If available and cheap:

```text
zig build perf
```

## Non-Goals

Do not implement:

- real OpenAI backend
- Codex CLI integration
- MCP
- new agent tools
- patch generation changes
- task runner changes
- git diff parser changes
- persistent context history
- embeddings/vector search
- secret scanning beyond existing skip rules

## Acceptance Criteria

The task is complete when:

1. `:agentcontext` opens a readable context inspection panel.
2. The panel shows system prompt, mode, workspace, git, files, tools, policy, validation, and budget sections.
3. Skipped files are shown with reasons but never contents.
4. Budget/truncation state is visible.
5. Navigation works.
6. The Agent panel shows a compact context summary.
7. No new network calls are introduced.
8. No file writes happen unless the user approves a proposal.
9. Tests pass.
10. `zig build test` passes.
11. `zig build` passes.

## Final Response Expected

Summarize:

- Files changed
- Context panel behavior
- Formatting/rendering approach
- Agent panel summary changes
- Secret/skipped-file handling
- Tests added
- Validation commands run and results
- Known limitations
