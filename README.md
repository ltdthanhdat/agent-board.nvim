# AgentBoard

A Kanban board for Neovim tasks, with persistent Claude conversations and Herdr agent terminals.

- Track tasks in `Todo`, `Doing`, and `Done` columns for one repository or across repositories.
- Start or link Herdr agents, send prompts, and attach to their terminal in a floating window.
- Keep task data in `.agent-board.json` at each repository root.

## Requirements

- Neovim 0.10 or later
- Git
- Herdr 0.9.3 or later with a running server for agent features

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
| `a` | Start an agent, or resume linked Claude conversation |
| `b` | Link a running agent or saved Claude session |
| `<CR>` | Attach or resume in a floating terminal |
| `p` | Send a prompt |
| `s` | Stop agent |
| `x` | Delete task and agent link |
| `q` | Close board |
| `?` | Show shortcuts |

Claude sessions are listed by repository, including its Git worktrees. Exit Claude and press Enter to resume the same conversation. Herdr must report its native session UUID; missing identity is shown as unavailable. Codex and Pi support live sessions only.

Inside a terminal, press `Ctrl-\\ Ctrl-n`, then `q` to hide it while the agent keeps running. Stopping preserves Claude history; deleting a task does not delete history or stop its agent.

Boards migrate to schema v2 on the next edit; older plugin versions cannot edit them. Claude history uses `CLAUDE_CONFIG_DIR` or `~/.claude`. An unverified start is kept pending to prevent duplicate processes across Neovim restarts.

Marking a task done does not stop its agent. Stop and delete actions ask for confirmation.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for attribution.
