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
| `a` / `n` | Create a task |
| `r` | Rename the selected task, or rename the focused lane when empty |
| `m` | Move the selected task to a lane |
| `d` | Move the selected task to the built-in Done lane |
| `+` | Add a lane to the focused project |
| `R` | Rename the focused lane |
| `Tab` / `Shift-Tab`, `h` / `l`, `←` / `→` | Move between lanes |
| `[` / `]` | Move between projects on the global board |
| `j` / `k`, `↓` / `↑` | Move between tasks |
| `g` | Switch between repository and global board |
| `Enter` | Open or resume a linked session; choose a provider to start one if unlinked; create a task in an empty lane |
| `Space` | Show available actions for the selected task or lane |
| `b` | Link a running agent or saved Claude session |
| `x` | Mark a task to cut; the task stays in its lane until pasted |
| `p` | Move the cut task into the focused lane of the same repository |
| `X` / `Esc` | Cancel a cut; `Esc` closes the board when nothing is cut |
| `Delete` | Delete a task after confirmation |
| `s` | Stop an agent |
| `?` | Show shortcuts |
| `Esc` / `q` | Close help, or close the board |

Each repository has its own ordered lanes, stored in its `.agent-board.json`. `Enter` on an empty lane creates a task in that lane; `a` and `n` create a task in the first lane. On the global board, lane controls apply to the focused project; lanes with the same name in different projects remain separate. At widths below 64 columns, the board shows one lane at a time. Starting, linking, or resuming an agent does not move its task to another lane.

Tasks use compact rows, with the focused lane border accented and only the selected task highlighted. Task details show the project, lane, session state and contextual Enter action beside the board on wide screens, or below it on smaller screens.

Inside an agent terminal, press `Ctrl-\\ Ctrl-n`, then `q` to hide it while the agent keeps running. Reopening the task reuses the terminal. Stopping an agent preserves Claude history; deleting a task does not delete its history or stop its agent.

Board files use schema v3. Existing v1 and v2 files are read without modification and migrate to v3 on their next successful edit. Older plugin versions cannot edit v3 boards. Saved Claude, Codex, and Pi sessions can be linked to tasks and resumed by their exact provider session ID. An unverified start remains pending to prevent duplicate processes across Neovim restarts.

Marking a task done does not stop its agent. Stop and delete actions ask for confirmation.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for attribution.
