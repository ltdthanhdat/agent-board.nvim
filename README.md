# AgentBoard

A task board for Neovim with persistent Claude conversations and floating Herdr agent terminals.

## Requirements

- Neovim 0.10 or later
- Git
- Herdr 0.9.3 or later with a running server for agent features

Task management works without Herdr. Agent providers are configured in Herdr (Claude Code, Codex, or Pi).

## Install

Add AgentBoard to your Lazy.nvim plugins:

```lua
{
  "ltdthanhdat/agent-board.nvim",
  cmd = "AgentBoard",
}
```

No setup call is required.

## Use

Run `:AgentBoard` inside a Git repository. Run `:AgentBoard global` to browse registered repositories, grouped by project.

| Key | Action |
| --- | --- |
| `n` | Create a task |
| `r` | Rename the selected task |
| `m` | Move the selected task to a lane |
| `d` | Move the selected task to the built-in Done lane |
| `+` | Add a lane to the focused project |
| `R` | Rename the focused lane |
| `h` / `l` | Move between lanes |
| `[` / `]` | Move between projects on the global board |
| `j` / `k` | Move between tasks |
| `g` | Switch between repository and global board |
| `a` | Start an agent or resume its linked Claude conversation |
| `b` | Link a running agent or saved Claude session |
| `<CR>` | Attach to or resume an agent in a floating terminal |
| `p` | Send a prompt |
| `s` | Stop an agent |
| `x` | Delete a task and its agent link |
| `?` | Show shortcuts |
| `q` | Close the board |

Each repository has its own ordered lanes, stored in its `.agent-board.json`. On the global board, lane controls apply to the focused project; lanes with the same name in different projects remain separate. At widths below 64 columns, the board shows one lane at a time. Starting, linking, or resuming an agent does not move its task to another lane.

Inside an agent terminal, press `Ctrl-\\ Ctrl-n`, then `q` to hide it while the agent keeps running. Reopening the task reuses the terminal. Stopping an agent preserves Claude history; deleting a task does not delete its history or stop its agent.

Board files use schema v3. Existing v1 and v2 files are read without modification and migrate to v3 on their next successful edit. Older plugin versions cannot edit v3 boards. Claude history uses `CLAUDE_CONFIG_DIR` or `~/.claude`. An unverified start remains pending to prevent duplicate processes across Neovim restarts.

Marking a task done does not stop its agent. Stop and delete actions ask for confirmation.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for attribution.
