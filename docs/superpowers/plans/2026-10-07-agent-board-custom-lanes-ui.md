# AgentBoard Custom Lanes and UI Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Give each repository editable workflow lanes, keep tasks in place when agents start or resume, and make the Neovim board easier to navigate and read.

**Architecture:** Store ordered lane definitions with stable IDs in each repository's board document. Keep task status as the lane ID, expose snapshot-safe lane operations through the task API, and render global boards as project sections with independent lanes. Improve the existing `board.lua` and preserve the existing terminal float.

**Tech Stack:** Lua, Neovim 0.10+ APIs, Git, existing Neovim test scripts; no new runtime dependency.

**Spec:** [AgentBoard custom lanes and UI polish](../specs/2026-10-07-agent-board-custom-lanes-ui-design.md).

## Global Constraints

- Each repository's `.agent-board.json` stores an ordered `lanes` array. Built-in lane IDs remain `todo`, `doing`, and `done`.
- Adding a lane appends it and assigns a new unique ID. Renaming changes only its display name. Deleting and reordering lanes are out of scope.
- Board schema version 3 accepts version 1 and 2 files. Reads normalize legacy files in memory and do not write. The next successful mutation writes version 3. The registry schema is unchanged.
- `+` adds a lane, `R` renames a lane, `r` renames a task, `m` moves a task, `[`/`]` switch project groups in global scope, and `h`/`l` navigate lanes.
- The global board renders project sections in registered-repository order. Each project has only its own tasks and lanes; equal lane names are not merged across projects.
- Starting, binding, or resuming an agent must preserve the task's lane. New tasks use the first configured lane. `d` targets the built-in `done` lane ID.
- Below 64 columns, show one selected lane for the focused project. At wider sizes, show at most three adjacent lanes per project. Keep the board in its tab and the terminal in a centered float.
- Keep the spec and plan in `docs/` uncommitted. Preserve existing untracked user data and do not read or modify the root `.agent-board.json`.

## Review Focus

1. A legacy task status must map to a default lane while the raw file remains unchanged until mutation. Test in Task 1 with both schema v1 and v2 fixtures.
2. A task referencing a missing lane or a document with duplicate lane IDs/names must be rejected without writing. Test invalid documents in Task 1 and API inputs in Task 2.
3. Concurrent file changes must prevent lane add/rename/move from overwriting newer data. Test stale snapshots in Task 2.
4. Projects with the same lane names must remain separate in the global view, including empty lanes and projects with different lane counts. Test in Task 4.
5. Successful and failed agent starts/resumes must preserve custom lane IDs. Test success and failure paths in Task 3 and the UI action in Task 4.

## File Map

- `lua/agent-board/storage.lua`: board schema validation, defaults, and legacy normalization.
- `lua/agent-board/tasks.lua`: repository-scoped lane reads/mutations and task lane validation.
- `lua/agent-board/init.lua`: export the lane API used by plugin callers.
- `lua/agent-board/board.lua`: per-project lane rendering, lane actions, navigation, help, highlights, and resize redraw.
- `tests/check.lua`: schema, lane API, and generic-agent lifecycle assertions.
- `tests/conversation_lifecycle.lua`: Claude start/resume lane preservation.
- `tests/ui_e2e.lua`: interactive lane and visual behavior.
- `README.md`: shortcuts, custom lanes, and schema compatibility.
- `docs/issues/ui-ux-polish/`: keep existing runtime evidence uncommitted; update the test cases and report only after verification.

---

### Task 1: Board schema v3 and legacy normalization

**Files:**
- Modify: `lua/agent-board/storage.lua`
- Test: `tests/check.lua`

**Interfaces:**
- Produces: `storage.read(path, 'board')` returns `{version=3, revision, tasks, lanes}` and a snapshot whose `data` remains the original bytes.
- Preserves: registry documents remain version 1; `storage.write_locked` retains its current signature and snapshot/revision behavior.

- [x] **Step 1: Write failing storage assertions** for missing-board defaults, v1 and v2 in-memory migration, no-write reads, version 3 custom lanes, duplicate lane IDs/names, invalid lane references, and unsupported version 4.
- [x] **Step 2: Run `nvim --headless -u NONE -l tests/check.lua`** and confirm the new version 3 and lane assertions fail before implementation.
- [x] **Step 3: Implement version 3 board defaults and validation** in `storage.lua`. Normalize v1/v2 documents in memory with the default ordered lanes and preserve each task's existing `todo`/`doing`/`done` status. Keep the raw snapshot bytes unchanged until a successful write.
- [x] **Step 4: Run `nvim --headless -u NONE -l tests/check.lua`** and confirm schema, migration, and existing storage assertions pass.
- [x] **Step 5: Commit only `lua/agent-board/storage.lua` and `tests/check.lua`.**

### Task 2: Repository lane API and task movement

**Files:**
- Modify: `lua/agent-board/tasks.lua`
- Modify: `lua/agent-board/init.lua`
- Test: `tests/check.lua`

**Interfaces:**
- Consumes: normalized version 3 documents from Task 1.
- Produces: `list_lanes(repo) -> lanes`; `add_lane(repo, name, expected_snapshot) -> lane`; `rename_lane(repo, lane_id, name, expected_snapshot) -> lane`.
- Produces: `list_tasks(opts) -> rows, warnings, snapshots, projects`, where `projects` is an ordered array of `{repo, lanes}` that includes registered empty boards.
- Updates: `move_task(ref, lane_id, expected_snapshot)` validates the lane in that repository; `create_task` uses the first configured lane.

- [x] **Step 1: Add failing API tests** for list/add/rename, append order, stable IDs after rename, whitespace/empty and duplicate names, custom lane movement, missing lane rejection, first-lane task creation, per-repo lane maps, and stale snapshots.
- [x] **Step 2: Run `nvim --headless -u NONE -l tests/check.lua`** and confirm the lane API assertions fail.
- [x] **Step 3: Implement snapshot-safe lane operations** using existing repo locks and `with_repo_lock`; export the methods from `init.lua`. Keep default lane IDs stable and reject mutation when the expected snapshot is stale.
- [x] **Step 4: Run `nvim --headless -u NONE -l tests/check.lua`** and confirm lane and existing task API assertions pass.
- [x] **Step 5: Commit only `lua/agent-board/tasks.lua`, `lua/agent-board/init.lua`, and `tests/check.lua`.**

### Task 3: Keep lane state independent from agent lifecycle

**Files:**
- Modify: `lua/agent-board/tasks.lua`
- Test: `tests/check.lua`
- Test: `tests/conversation_lifecycle.lua`
- Test: `tests/ui_e2e.lua` (existing start-status expectation)
- Test: `tests/herdr_resume_e2e.lua` (existing native-start status expectation)

**Interfaces:**
- Consumes: lane IDs and mutation behavior from Task 2.
- Preserves: start, bind, resume, stop, and failure callbacks keep their existing runtime/conversation results and error contracts.

- [x] **Step 1: Change lifecycle assertions first** so a successful generic-agent start and a newly created Claude conversation remain in their pre-start lane; add a custom-lane start/resume case and confirm failed starts preserve the lane.
- [x] **Step 2: Run `nvim --headless -u NONE -l tests/check.lua` and `nvim --headless -u NONE -l tests/conversation_lifecycle.lua`** before implementation and confirm both fail on the automatic Doing transitions. After implementation, run `tests/ui_e2e.lua` and `tests/herdr_resume_e2e.lua`; update any old Doing expectation they expose.
- [x] **Step 3: Remove only the automatic `doing` assignments** from successful generic-agent and new-Claude-session launch paths. Do not change task status in open/resume, bind, stop, or error paths.
- [x] **Step 4: Run the four commands again** and confirm every lifecycle assertion passes, including legacy Claude migration, offline resume, and Herdr attach.
- [x] **Step 5: Commit only `lua/agent-board/tasks.lua`, `tests/check.lua`, `tests/conversation_lifecycle.lua`, `tests/ui_e2e.lua`, and `tests/herdr_resume_e2e.lua`.**

### Task 4: Project-grouped board, lane controls, and UI polish

**Files:**
- Modify: `lua/agent-board/board.lua`
- Test: `tests/ui_e2e.lua`

**Interfaces:**
- Consumes: `list_tasks` lane metadata and lane operations from Task 2.
- Produces: repo sections ordered by the `projects` array; local/global lane navigation; `+`, `R`, `[`, and `]` actions; a non-selectable help float.
- Preserves: existing task actions, `vim.ui.select` for pickers, board tab, and terminal float API.

- [x] **Step 1: Add failing UI assertions** for independent project sections (including same-named and empty lanes), lane counts, `+`/`R`/`m`, `[`/`]` project navigation, `h`/`l` lane navigation, and task selection after refresh.
- [x] **Step 2: Add failing layout assertions** for one lane below 64 columns, at most three adjacent lanes at wider sizes, immediate resize redraw, and a floating help window dismissed by `Esc`/`q` without invoking `vim.ui.select`.
- [x] **Step 3: Run `nvim --headless -u NONE -l tests/ui_e2e.lua`** and confirm the new project/lane and layout assertions fail.
- [x] **Step 4: Implement project sections and lane actions** using the ordered `projects` array, including empty registered projects; `m` must offer the selected task repository's lanes. `+` and `R` operate on the focused project/lane. Preserve `r` for task rename and `d` for the built-in `done` ID.
- [x] **Step 5: Implement visual hierarchy** with theme-linked highlights, selected-card styling, lane counts, concise footer and actionable empty state, `eob` filler suppression, and a non-selectable rounded help float.
- [x] **Step 6: Add resize autocmds** for `VimResized` and `WinResized`, redraw the board immediately, and keep the focused project/lane and selected task stable.
- [x] **Step 7: Run `nvim --headless -u NONE -l tests/ui_e2e.lua`** and confirm UI actions and layout assertions pass.
- [x] **Step 8: Commit only `lua/agent-board/board.lua` and `tests/ui_e2e.lua`.**

### Task 5: User-facing guide and final verification

**Files:**
- Modify: `README.md`
- Verify: all test scripts and isolated Neovim TUI

**Interfaces:**
- Consumes: final key bindings and behaviors from Tasks 2–4.
- Produces: concise documentation of per-repo lanes, global project groups, migration, and current shortcuts.

- [x] **Step 1: Update README** for `+`, `R`, `[ ]`, custom lane behavior, no automatic Doing transition, and schema v3 compatibility.
- [x] **Step 2: Run the complete test set:** `nvim --headless -u NONE -l tests/check.lua`, `tests/claude_sessions.lua`, `tests/conversation_lifecycle.lua`, `tests/ui_e2e.lua`, and `tests/herdr_resume_e2e.lua`; require exit code 0 from each. Run the Herdr integration only with its isolated fixture/server.
- [x] **Step 3: Run an isolated real-Neovim TUI pass** with temporary XDG and Claude directories, a temporary Git repo, mocked Herdr operations, and blocked Herdr/Claude executables. Exercise lane creation/rename/move, project-group navigation, agent start/resume status preservation, narrow and wide resize, help, and terminal float hide/reopen/exit.
- [x] **Step 4: Update the uncommitted runtime test cases/report with actual results, then run `git diff --check`**. Confirm no user `.agent-board.json`, real Claude history, or Herdr pane was modified, and no file under `docs/` is staged.
- [x] **Step 5: Commit `README.md` with the verified product change; never stage or commit files under `docs/`. Do not push.**
- [x] **Step 6: Fast-forward the verified feature branch into local `master`** so the existing local-path plugin install uses the tested code; leave `origin/master` untouched.
