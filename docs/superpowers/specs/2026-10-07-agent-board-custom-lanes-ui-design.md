# AgentBoard custom lanes and UI polish

Status: conversational design approved; written spec awaiting user review.
Documentation only. Keep this file uncommitted as requested.

## 1. Intent and acceptance criteria

Make AgentBoard easier to scan and use while letting each repository define its
own workflow lanes. Starting or resuming an agent must not move a task; the user
controls task movement.

Acceptance criteria:

- Each repository can add lanes and rename existing lanes.
- Tasks stay in their lane when an agent starts, is linked, or resumes.
- `m` lists lanes defined by the selected task's repository.
- A new task starts in the first lane, which remains `Todo` by default.
- Existing board files keep their tasks and lane meanings when upgraded.
- The global board groups tasks by project/repository. Each group uses only that
  project's own lanes; equal names in different projects are not merged.
- Below 64 terminal columns, the board displays one selected lane. `h` and `l`
  navigate lanes; at wider sizes, the board shows at most three lanes at a time.
- The board remains in its tab and the agent terminal remains a centered float.
- Empty boards, task selection, shortcuts, counts, colors, and resizing receive
  clear visual feedback.

## 2. Data model and compatibility

Each `.agent-board.json` stores an ordered `lanes` array. A lane has a stable
repository-local ID and a non-empty display name. Tasks keep their current
`status` property, whose value becomes a lane ID. The built-in lanes retain IDs
`todo`, `doing`, and `done`, with default names `Todo`, `Doing`, and `Done`.

Adding a lane appends it and assigns a new unique ID. Renaming changes only its
display name, so existing tasks remain attached. Lane names must be non-empty
after trimming and unique within a repository. Deleting and reordering lanes are
out of scope.

Board schema version 3 accepts version 1 and 2 files. Reads normalize legacy
files in memory by adding the three default lanes and preserving existing task
statuses. Reads do not write. The next successful mutation writes version 3
under the existing lock, snapshot, and atomic-write rules. Invalid or
unsupported documents continue to fail without modifying their bytes. The
registry schema is unchanged. Older plugin versions cannot edit version 3 files.

## 3. Lane behavior and board scopes

Each repository owns its lane configuration. `+` adds a lane and `R` renames
the currently focused lane; the existing `r` continues to rename a task. In
global scope, `[` and `]` move focus between project groups in registry order;
lane management applies to the focused project. When a task is selected, `m`
offers only that task repository's lanes. Each global project group contains
only its own tasks and lanes, even when another project has lanes with the same
names.

Task creation uses the first configured lane. Starting a new provider, binding
an existing session, starting a new Claude conversation, and resuming Claude
preserve the task's current lane. The `d` shortcut continues to target the
built-in `done` lane ID even if its displayed name is changed. Lane selection
and movement remain explicit user actions.

The global view renders project sections in registered-repository order. Each
section preserves that repository's lane order. `[` and `]` move the active
project while keeping the current lane when possible; `h` and `l` navigate
lanes within that project. `j` and `k` navigate cards in the active
project/lane. Movement always uses the selected task's repository-specific
lane list.

## 4. UI and interaction

Keep AgentBoard in its existing tab and preserve the current centered terminal
float. Improve the board with theme-linked highlight groups, a distinct selected
task, lane counts, a compact shortcut footer, an actionable empty state, and no
end-of-buffer filler. `?` opens a non-selectable floating help panel closed by
`Esc` or `q`; action pickers continue to use the user's configured `vim.ui.select`.

Redraw immediately when the editor or board window resizes. At widths below 64
columns, show only the focused project's selected lane at full width; `h` and
`l` change the selected lane, while `[` and `]` change projects in global
scope. At wider widths, each project section shows no more than three adjacent
lanes and shifts the visible range as the user navigates. Preserve task
selection across refresh and lane rename.

## 5. Interface and validation

Expose lane listing, addition, and renaming through the existing task API so
the UI can use the same storage checks as other task actions. `move_task` accepts
only a lane ID present in the task's repository document. `create_task` uses
the first configured lane. Lane mutations honor expected snapshots and the
existing repository locks. Reject duplicate lane names and attempts to move a
task to a missing lane.

Keep agent runtime operations independent from lane state. The launch and resume
success paths only update conversation/runtime fields. A failed runtime start
must preserve both lane and task data.

## 6. Verification

- Storage tests cover version 1/2 normalization, version 3 validation, default
  lane IDs, custom lane persistence, duplicate/missing lane rejection, and
  read-without-write migration behavior.
- Task API tests cover add, rename, movement, stale snapshots, and task creation
  in the first lane.
- Lifecycle tests assert successful generic-agent start and Claude start/resume
  leave the task lane unchanged; binding and stopping continue to preserve it.
- UI tests exercise `+`, `R`, `m`, global repository selection, help dismissal,
  counts, project-group navigation, project-specific lanes, single-lane narrow
  rendering, three-lane viewport navigation, and immediate resize redraw.
- Run the full existing Neovim test suite and an isolated Neovim TUI pass using
  temporary repositories and mocked Herdr/Claude commands. Verify that the real
  terminal float still overlays the board and remains reusable.
- Update README keys and document the per-repository lanes and schema migration.

No provider launch, external write, push, or commit is part of this design.
