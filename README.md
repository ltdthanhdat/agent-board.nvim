# AgentBoard

A Kanban board for Neovim tasks, with optional Herdr agent sessions.

- Track tasks in `Todo`, `Doing`, and `Done` columns for one repository or across repositories.
- Start or link Herdr agents, send prompts, and attach to their terminal in a floating window.
- Keep task data in `.agent-board.json` at each repository root.

## Requirements

- Neovim 0.10 or later
- Git
- Herdr 0.7.5 or later with a running server for agent features

Task management works without Herdr. Agent providers are configured in Herdr (Claude Code, Codex, or Pi).

## Install

Add this plugin to your Lazy.nvim plugins:

```lua
{
  "ltdthanhdat/agent-board.nvim",
  cmd = "AgentBoard",
}
```

No setup call is required.

## Use

Run `:AgentBoard` inside a Git repository, or `:AgentBoard global` to browse repositories previously opened with AgentBoard.

| Key | Action |
| --- | --- |
| `n` | Create a task |
| `r` | Rename task |
| `m` | Move task |
| `d` | Mark task done |
| `h` / `l` | Move between columns |
| `j` / `k` | Move between tasks |
| `a` | Start an agent |
| `b` | Link a running agent |
| `<CR>` | Open or focus agent terminal |
| `p` | Send a prompt |
| `s` | Stop agent |
| `x` | Delete task and agent link |
| `q` | Close board |

Marking a task done does not stop its agent. Stop and delete actions ask for confirmation.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for attribution.
