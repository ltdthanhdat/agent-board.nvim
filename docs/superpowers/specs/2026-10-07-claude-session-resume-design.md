# AgentBoard: persistent Claude conversations and board terminal

Status: approved by the user; implementation plan awaiting review. Documentation only; no implementation,
commit, push, provider launch, or user Herdr session manipulation in this phase.

## 1. Agreed intent and scope

A task represents work associated with one Claude conversation. The conversation
remains linked after Claude exits and can be resumed from the same task. Herdr owns
the running process in the background; Neovim displays its terminal in a floating
window above the board.

Agreed by the user:

- Keep Herdr as the background runtime.
- Each task links to one Claude conversation.
- The session picker includes live and offline Claude sessions belonging to the repo.
- Enter attaches a live conversation or resumes an offline conversation.
- Exit/stop preserves the conversation link; hiding the float preserves the runtime.
- Place this design in docs/ but do not commit it.

Scope: local Claude sessions and a local Herdr server. Existing Codex/Pi live-agent
features continue to work; offline resume for those providers is outside this change.
No conversation viewer, transcript copying, remote session discovery, or multi-session
history per task is introduced.

## 2. Evidence and current gaps

Current code stores Herdr server/pane/terminal identity and an optional session_id
inside task.agent. Storage requires a complete runtime identity. open_agent resolves
that live identity before opening a terminal; an exited agent cannot be opened.
start_agent replaces an offline link with a new agent rather than resuming Claude.

terminal.lua already creates a Neovim float and runs herdr agent attach inside it.
The user reports that actual opening happens through Herdr rather than the desired
float. The cause is not established. Float creation alone is insufficient evidence;
the revised flow must be exercised inside Neovim launched within Herdr as well as
outside Herdr, and must leave the board visible beneath the float.

Verified locally: Claude Code 2.1.290 supports --resume and --session-id; Herdr 0.9.3
supports agent start with arguments after -- and direct terminal attach by terminal ID.
Local ~/.claude/projects contains top-level session JSONL files. Sample record schemas
include sessionId, cwd, timestamp, isSidechain, and ai-title/aiTitle. No sessions-index.json
was found. Only key names and record counts were inspected; user conversation text
was not printed or copied into this design.

Official references:

- https://code.claude.com/docs/en/how-claude-code-works
- https://code.claude.com/docs/en/cli-reference
- https://herdr.dev/docs/persistence-remote/
- https://herdr.dev/docs/agents/

JSONL metadata details are an observed, version-dependent format, not a guaranteed
public API. Keep the parser isolated and test it with synthetic fixtures.

## 3. Options and selected direction

A. Persist native conversation identity separately from runtime identity, merge local
Claude metadata with live Herdr agents, and resume through Herdr. Selected: matches
the user's desired workflow and preserves background execution.

B. Run Claude directly in the float. Rejected by the user's selection of Herdr as backend.

C. Keep live-only links and require manually resuming/rebinding each time. Does not
satisfy the requested MVP behavior.

## 4. Data model and migration

Introduce board schema version 2. A task retains id/title/status and carries:

- conversation: null or { provider: 'claude', session_id: UUID, cwd: absolute path }.
- agent: null or the existing Herdr runtime identity shape.

conversation is the durable link. agent is the last observed runtime and may become
stale without losing the conversation. Status belongs to the task, not the runtime.
Metadata titles/timestamps are read for the picker, not copied into the board.

Read version 1 boards and normalize in memory. A Claude agent.session_id becomes a
conversation link only when its ID and cwd can be verified through session metadata
or trustworthy native session evidence. Do not interpret an arbitrary Herdr identifier
as a Claude UUID. Links without verifiable IDs remain legacy live links and show
'resume unavailable' rather than creating a guessed conversation identity.

Write version 2 on the next successful mutation under the existing locks/snapshot
checks. Do not rewrite boards merely on read. Registry schema remains unchanged.
Unsupported versions/corrupt data remain errors. Existing Codex/Pi links are preserved.
Document that older plugin versions cannot edit a version 2 board.

Conversation uniqueness is checked across registered repos by provider + session ID;
existing runtime uniqueness checks remain. A stale/unreadable registered board must
not silently bypass duplicate checks. Repositories outside the registry remain outside
this uniqueness boundary, as with the current implementation.

## 5. Session discovery and picker

Add an isolated Claude session metadata reader, honoring CLAUDE_CONFIG_DIR when set
and otherwise using ~/.claude. Do not change Claude settings or install hooks globally.

Read top-level session JSONL files; exclude subagent/sidechain records. Extract verified
session ID, actual cwd, available display title, and latest valid timestamp. Display ID
as fallback when no title exists. Never execute values taken from metadata.

Resolve each cwd to a canonical Git root and canonical absolute Git common directory
(using git rev-parse --git-common-dir, resolving relative output against cwd). A session
belongs to a task's repo when roots match or their common directories match. This
includes worktrees of the same repository without grouping unrelated clones. Preserve
the session's original cwd for resume.
If that directory is missing, mark resume unavailable; do not substitute another cwd.

Use asynchronous bounded streaming and a cache keyed by file path, size, and mtime.
No full transcript decode on Neovim's main thread. Limit individual line/resource sizes,
ignore malformed records, and retain valid sessions with a visible partial-scan warning.
A missing metadata directory means no local saved sessions, not a fatal board error.

Merge metadata with Herdr agents by verified Claude session ID, never by title or cwd
alone. Duplicate live matches are an ambiguous runtime error. A live agent with no
native ID is shown as 'live — session ID unavailable'; it cannot be presented as a
resumable conversation. Existing legacy live-link functionality remains available.

Picker row: title or short ID, updated time, and running/offline/unavailable state.
Already linked sessions are marked and cannot be selected for a second task. Select
only saves the link; it does not start/resume Claude. If a task is already linked, show
its current link and reject replacement in this MVP.

Herdr query failure means runtime unknown, not offline. Metadata sessions may still
be listed, but opening must verify the runtime before launching a second process.

## 6. Open, new, stop, and hide behavior

Enter on a Claude-linked task:

1. Refresh native metadata and Herdr live identities.
2. If the conversation has one verified live runtime, attach it into the board float.
   Refresh saved runtime IDs if they changed but the native conversation ID matches.
3. If live discovery fails or is ambiguous, report the error and launch nothing.
4. If confirmed offline, validate the saved session and cwd, reserve the task operation,
   and start Claude through Herdr with --resume <exact-session-id>.
5. Verify the started runtime targets the requested native session. Save the new runtime
   identity without replacing conversation identity, then attach in the float.

If native identity cannot be verified after launch, report recovery details and avoid
silently accepting a different conversation. Never fall back to --continue or plain claude
when resume fails. The old link remains intact.

For a new Claude conversation, generate a valid UUID before launch and pass
--session-id <uuid> through Herdr's agent arguments. Persist the requested conversation
identity with successful start; a session with no saved transcript yet is shown explicitly
as not yet resumable. If no transcript exists after exit, report that condition rather than
creating a new conversation under an old task implicitly.

'a' on an unlinked task starts a new conversation. For a linked Claude task, reuse the
same open/resume flow and do not offer a different provider/new conversation.
's' stops the runtime using existing explicit confirmation, keeps the conversation link,
and does not change task status. Claude exit is detected as offline while preserving
the link. Prompt on an offline task reports that the user must open/resume first.
Delete task removes the link but never deletes Claude history or stops a live agent.

Serialize start/resume per task and preserve cross-repo uniqueness checks. Repeated
Enter cannot create duplicate runtimes. After uncertain start timeout, discover and
verify the requested session before retrying; if discovery is inconclusive, report an
unknown outcome rather than spawning again. Save failure after launch returns runtime
recovery information and does not automatically kill the successfully launched agent.

## 7. Float behavior

The visible terminal is a Neovim floating window in the board tab. Herdr creates and
owns the background pane without switching the user's Herdr workspace or tab.

Prefer direct attachment by verified terminal ID so attachment addresses the terminal
itself. Confirm behavior with the installed Herdr CLI; do not substitute a full Herdr UI
launch or agent-focus command. Existing writable controller conflicts produce an
explicit error; do not take over another client automatically.

Ctrl-\\ Ctrl-n then q hides the float and retains the local attach job for reuse.
Closing Neovim ends only the attach client. Reopening the board can attach the same
live runtime or resume the same offline conversation. Attach-client exit must not erase
the durable link or be interpreted as Claude exiting.

Show the current session label and hide shortcut on the float border/footer. Help in
the board and the README must distinguish hide, runtime stop, and conversation link.
Terminal input is passed to Claude; board mappings do not intercept its normal input.

## 8. Components affected

- New Claude metadata module: discovery, parsing, cache, repo/cwd validation.
- storage.lua: schema v2 validation and v1 normalization/migration.
- tasks.lua: conversation uniqueness, bind/open/resume/new/stop coordination.
- herdr.lua: explicit Claude startup arguments and verified native identity discovery.
- terminal.lua: direct attachment and board float lifecycle.
- board.lua: merged picker, offline/runtime-unknown display, updated actions/help.
- README and focused synthetic/headless/runtime fixture tests.

## 9. Acceptance and verification

- Bind an offline session from the repo picker, restart Neovim, Enter: launch arguments
  contain --resume and the exact stored UUID; conversation identity remains unchanged.
- New conversation receives --session-id; exit then Enter resumes that UUID.
- Live metadata + runtime merge into one picker row; a duplicate binding is rejected.
- Sessions from another repo/sidechains are excluded; same-repo worktrees retain their cwd.
- Missing files, invalid JSONL, moved cwd, missing native IDs, and corrupt boards produce
  clear states/errors without replacing the existing conversation link.
- Herdr unavailable, wrong identity, ambiguous runtime, and unknown start outcome never
  become implicit permission to start a new conversation.
- Double Enter starts at most one runtime; conflicts/save failures preserve recovery data.
- Version 1 fixtures migrate safely; Codex/Pi live workflows remain covered.
- Enter opens a real Neovim float with board visible underneath, both when Neovim runs
  inside Herdr and when launched externally. Assert tab/window identity and geometry;
  record terminal captures for the actual UX, not only mocked calls.
- Hide/reopen reuses the attach client; Neovim restart reattaches a surviving runtime.
- Stop/Claude exit preserves the conversation; deletion never deletes Claude JSONL.

Use synthetic Claude history and isolated Herdr server/provider executables first.
Do not manipulate the user's current panes or launch paid prompts. Actual Claude CLI
resume readiness is a separate final integration check with an explicitly agreed fixture
session; no LLM prompt is required to validate launch/attach mechanics. Report real
Claude coverage separately from fake-provider coverage.

## 10. Review boundary

No product code is changed by this document. After design approval, write an
implementation plan for review; implementation starts only after plan approval and
execution method selection. Keep this spec and the plan uncommitted as requested.
