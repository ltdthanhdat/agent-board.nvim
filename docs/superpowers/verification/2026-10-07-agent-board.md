# AgentBoard runtime verification

Tested implementation commit: `2b790ca` on `master`.

## Results

- `nvim --headless -u NONE -l tests/check.lua` → `agent-board checks passed`.
- `nvim --headless -u NONE -l tests/ui_e2e.lua` → `agent-board ui e2e passed`.
- Interactive Neovim TUI via isolated tmux PTY passed at 120×40 and 36×16. Covered Unicode rendering, horizontal scrolling, task create/rename/move/Done/delete/cancel, linked-task delete, global/repo switching, duplicate task IDs across repos, and creation into the selected repo.
- Floating terminal opened, accepted typed input, hid and reopened with one attach process. Board prompt `p` reached the fake CLI prompt log.
- Two independent headless Neovim processes read the same revision; after one saved, the stale writer received `board changed; reload before saving` and did not overwrite the saved change.
- Reproducible runner: `bash docs/issues/61/output/evidence/two-neovim-stale-check.sh`; its final JSON assertion passed and output is captured in `two-neovim-stale-check.txt`.
- The temporary Git repos, fake Herdr CLI and isolated tmux servers were removed after capturing evidence.

## Runtime boundary

All Herdr behavior in the PTY run used a fake local CLI and fixture identity. At the user's choice, verification ends at this UI E2E scope: no Herdr server, user pane, or real provider was accessed. Real provider start, prompt, stop, and survival after Neovim restart remain unverified. The terminal evidence is `tmux capture-pane` text; no pixel screenshot or video recorder was available.

## Evidence

- [Issue #61 test report](../../issues/61/output/test-report.md)
- PTY captures: [verification directory](2026-10-07-agent-board/)
- [Headless UI E2E log](../../issues/61/output/evidence/headless-ui-e2e.txt)
- [Runtime contract log](../../issues/61/output/evidence/runtime-contracts.txt)
- [Two-Neovim conflict case](../../issues/61/output/evidence/two-neovim-a.log)
- [Reproducible two-Neovim runner](../../issues/61/output/evidence/two-neovim-stale-check.sh) and [captured output](../../issues/61/output/evidence/two-neovim-stale-check.txt)
