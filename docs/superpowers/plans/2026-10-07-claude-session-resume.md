# Claude Conversation Resume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Link one task to one durable Claude conversation, discover live/offline sessions by repo, and attach/resume through Herdr inside a Neovim board float.

**Architecture:** Store native conversation identity separately from the last Herdr runtime. An asynchronous metadata reader supplies saved sessions; a session coordinator reconciles these with verified live runtimes before starting anything. Herdr owns processes while Neovim owns only its floating attach client.

**Tech Stack:** Lua, Neovim 0.10+ APIs (vim.uv, vim.system, vim.json), Git, local Claude Code CLI/JSONL history, Herdr 0.9.3 capability baseline; no new third-party dependency.

**Spec:** [Approved design](../specs/2026-10-07-claude-session-resume-design.md).

## Global Constraints

- Keep Herdr as the background runtime; one Claude conversation per task.
- Local Claude sessions and local Herdr server only; Codex/Pi retain existing live workflows.
- Do not copy transcripts, delete Claude history, change Claude settings, or install global hooks.
- Honor CLAUDE_CONFIG_DIR, otherwise ~/.claude; JSONL fields are version-dependent.
- Preserve original session cwd; same-repository worktrees match by canonical Git common directory.
- Herdr unavailable/ambiguous/unknown never means permission to spawn another conversation.
- Resume uses the exact UUID; no --continue/plain-claude fallback and no automatic takeover.
- Board schema v2 migration is mutation-only; registry remains version 1.
- Preserve existing exclusive locks, snapshot conflicts, atomic writes, and runtime recovery reporting.
- All task checkboxes begin unchecked. Documentation remains uncommitted; product commits/pushes are not authorized by this plan alone.
- Preserve the user's untracked .agent-board.json and existing Herdr panes. Use isolated fixtures.
- If execution needs a worktree, follow the approved method and .worktrees/<branch-name> convention.

## Review Focus

1. A partial JSONL line while Claude is writing must not hide a valid session or block the UI (Task 1).
2. Two unrelated clones with the same basename must not share picker sessions; genuine Git worktrees must match (Task 1).
3. A timed-out start or double Enter must not create a second runtime, including when native identity is unavailable (Tasks 3–4).
4. Claude changes its native session through /clear or /resume: opening must reject an identity mismatch instead of silently retargeting a task (Task 4).
5. Neovim running inside Herdr must retain the board beneath a float; failed attach/another controller must not switch the outer workspace (Tasks 6–7).

## Files and shared contracts

- Create lua/agent-board/claude.lua: metadata scan/cache and cwd/repo identity.
- Create lua/agent-board/sessions.lua: merge saved/live records and validate native session targets; keep raw JSONL handling out of tasks.lua.
- Modify storage.lua: board v1/v2 validation and in-memory normalization, preserving raw-byte snapshots.
- Modify herdr.lua: optional explicit provider arguments, native identity verification, direct terminal-ID attachment.
- Modify tasks.lua and init.lua: bind_conversation, list_sessions, and existing lifecycle dispatch.
- Modify terminal.lua and board.lua: float ownership, lifecycle, picker/actions/status/help.
- Create tests/claude_sessions.lua, tests/conversation_lifecycle.lua, tests/herdr_resume_e2e.lua.
- Modify tests/check.lua and tests/ui_e2e.lua: migration and legacy compatibility assertions.
- Modify README.md: installation requirements/capabilities and revised user flow.

Shared types:

- Conversation={provider='claude',session_id:UUID,cwd:absolute-path}.
- Runtime=existing Herdr identity; optional session_id remains verified native evidence.
- Session={conversation?:Conversation,agent?:LiveAgent,title:string,updated_at?:string,state:'running'|'offline'|'unavailable'|'unknown',reason?:string}.
- Discovery={sessions:Session[],warnings:string[],runtime_error?:Error}.
- Ref={repo:string,id:string}; Error={code:string,message:string,agent?:Runtime,host?:table}.
- Async callbacks are scheduled on Neovim's main loop, exactly once: cb(value,err).

---

### Task 1: Asynchronous Claude session discovery

**Files:** Create lua/agent-board/claude.lua and tests/claude_sessions.lua.

**Interfaces:**
- claude.list(repo:string, cb(ConversationRecord[], warnings:string[])) where ConversationRecord={conversation,title,updated_at,resumable:boolean,reason?}.
- claude.get(repo:string, session_id:string, cb(ConversationRecord|nil, Error|nil)).
- claude.repo_identity(cwd:string, cb({root,common_dir}|nil,Error|nil)).
- claude.new_session_id() -> UUID, generated using native randomness; test validity/uniqueness.

- [ ] Write synthetic JSONL assertions named metadata_scan, partial_record, repo_membership, missing_cwd, config_override, and cache_invalidation. Verify main-session UUID/cwd/title/timestamp extraction, sidechain exclusion, malformed/truncated line tolerance, duplicate-record consolidation, no index-file dependency, and cache invalidation after size/mtime changes.
- [ ] Add tmp Git repo/worktree/independent-clone fixtures: common-dir equality includes the worktree but excludes the same-named clone. Keep moved/missing cwd candidates unavailable; never substitute the task repo cwd.
- [ ] Add scheduler responsiveness and resource-bound assertions. Set scan limits explicitly: 1 MiB per JSONL line, 16 MiB streamed per file, 2,048 top-level files per scan, 64 KiB read chunks. Exceeding limits preserves found records and yields a partial-scan warning; never read/decode full transcripts on the main thread.
- [ ] Run `nvim --headless -u NONE -l tests/claude_sessions.lua`; expect failure because the module is missing.
- [ ] Implement the reader using async uv operations, scheduled delivery, and asynchronous argv-only Git calls. Scan top-level project session files; extract metadata only; use realpath/common-dir identity. Cache by path,size,mtime plus config-root identity. Re-stat a changing file and mark a partial result rather than retaining a permanent stale cache entry.
- [ ] Run the same command; expect `claude session checks passed`, exit 0. Review that fixture conversation text never appears in test output.

### Task 2: Schema v2 and safe legacy normalization

**Files:** Modify lua/agent-board/storage.lua, lua/agent-board/tasks.lua (document creation/save boundaries), and tests/check.lua.

**Interfaces:** storage.read(path,kind) and write_locked(path,document,snapshot) keep their signatures. Board reads return a v2 in-memory document with task.conversation=null when unavailable; registry reads remain v1. Snapshots still reference original raw bytes. Storage performs structural normalization only; asynchronous native verification/promotion belongs to Task 4.

- [ ] Write assertions v1_normalization_no_write, v2_conversation_validation, migration_on_mutation, registry_stays_v1, and legacy_provider_preservation. Reading v1 must leave bytes unchanged; successful mutation writes v2; invalid UUID/cwd/provider, corrupt/version-unknown documents, and stale snapshots are rejected.
- [ ] Run `nvim --headless -u NONE -l tests/check.lua`; confirm new assertions fail for the intended v2 requirements.
- [ ] Implement v1/v2 board validators and pure in-memory normalization. Accept structurally valid legacy agent links without inventing conversation IDs. New tasks default conversation to null; mutations write v2 while preserving legacy provider/runtime fields and revision rules.
- [ ] Run the suite; expect `agent-board checks passed`, exit 0. Confirm lock/write failure tests still preserve original file bytes.

### Task 3: Herdr startup arguments and precise terminal attachment

**Files:** Modify lua/agent-board/herdr.lua and tests/check.lua.

**Interfaces:** Retain herdr.start(repo,provider,name,cb); add optional fifth opts={agent_args:string[],expected_session_id?:UUID}. Success remains {identity,host}. herdr.list/resolve retain current signatures. herdr.attach_argv(identity) returns {'herdr','terminal','attach',identity.terminal_id} after route/identity validation.

- [ ] Add argv assertions: Claude new uses `-- --session-id UUID`, resume uses `-- --resume UUID`, with arguments passed individually; old Codex/Pi start calls remain unchanged. Start still uses no-focus workspace/tab creation.
- [ ] Add readiness assertions: expected native UUID matches on success; missing/mismatched native identity returns session_identity_unverified/identity_mismatch with host/runtime recovery information. Never treat Herdr readiness as proof of a Claude session ID by itself.
- [ ] Add timeout/route-change/attach-controller-conflict tests and exact terminal-ID attach argv; no full Herdr UI command and no implicit --takeover.
- [ ] Run `nvim --headless -u NONE -l tests/check.lua`; expect the new argv/identity assertions to fail.
- [ ] Implement optional explicit arguments and bounded post-start identity verification. Retain start/query timeouts (35 seconds command, 30 seconds readiness, 5 seconds query). An uncertain timeout returns recovery information; it does not blindly repeat start or kill an unverified occupant.
- [ ] Run the suite; expect `agent-board checks passed`, exit 0. Record whether the installed Herdr integration can supply trustworthy Claude native session IDs; lack of that capability is an explicit unsupported state, not permission to infer IDs from names.

### Task 4: Durable binding and conversation lifecycle

**Files:** Create lua/agent-board/sessions.lua and tests/conversation_lifecycle.lua; modify tasks.lua and init.lua.

**Interfaces:**
- sessions.list(repo, cb(Discovery|nil,Error|nil)) consumes Task 1 metadata and Task 3 Herdr list, merging by verified native UUID.
- sessions.resolve(conversation, cb(Session|nil,Error|nil)) verifies repo/cwd and live identity; offline requires successful complete-enough runtime discovery. Unknown native identity in a relevant live Claude runtime cannot prove the target offline.
- tasks.list_sessions(ref,cb(Discovery|nil,Error|nil)) adds duplicate-task annotations.
- tasks.bind_conversation(ref,conversation,expected_snapshot?,cb(Task|nil,Error|nil)) validates metadata and duplicate links before saving; no process launch.
- Existing bind_agent/start_agent/open_agent/stop_agent/send signatures remain. Claude-linked start delegates to open/resume; other providers retain their existing path.

- [ ] Write merge_running_offline assertions: matching live+saved UUID appears once; native IDs are never derived from title/cwd; query failure yields unknown, multiple native matches yield ambiguous_runtime, and a live record without an ID cannot be silently classified as offline.
- [ ] Write offline_bind_reload_open and new_exit_resume tests using synthetic history + fake Herdr transport: persisted UUID/cwd survive independent reloads, new starts receive --session-id, resume receives --resume with that exact UUID, and runtime IDs may change while conversation identity does not.
- [ ] Add uniqueness/acquisition tests across two registered repos, double Enter, stale snapshots, unknown start outcome, and unreadable registered boards. Exactly one start is allowed; callback/lock release occurs once; save failure returns recovery information and preserves old linked history.
- [ ] Add legacy_native_promotion and changed_native_session tests: promote v1 only after verified metadata/native evidence; /clear or an unrelated /resume creates an identity mismatch rather than changing the task's linked UUID. Missing transcript/cwd and invalid UUID report unavailable; never fall back to a fresh conversation.
- [ ] Add stop/delete/prompt tests: stop/exit retain conversation and task column; delete does not touch JSONL or stop runtime; offline prompt requires open; empty-new history remains explicitly not yet resumable after exit.
- [ ] Run `nvim --headless -u NONE -l tests/conversation_lifecycle.lua`; expect the named lifecycle requirements to fail.
- [ ] Implement sessions reconciliation and transaction-coordinated lifecycle. Discover metadata before taking mutation locks; reload/revalidate under the existing bounded coordinator locks before side effects. On runtime identity change, persist only verified replacement runtime. Unknown recovery must remain blocked until discovery proves the requested target's state; use returned host identity and conservative missing-ID handling to prevent retries from duplicating an uncertain runtime.
- [ ] Run lifecycle and existing check suites; expect `conversation lifecycle checks passed` and `agent-board checks passed`, exit 0.

### Task 5: Board picker, statuses, and action semantics

**Files:** Modify board.lua, init.lua exports, tests/ui_e2e.lua, and README.md.

**Interfaces:** action_bind uses api.list_sessions and bind_conversation for Claude rows; legacy provider rows retain bind_agent. Existing command/mappings remain; add '?' board-local help. has-link/render/open checks must include conversation-only tasks, not only task.agent.

- [ ] Write UI assertions for offline-only task rows, merged picker formatting/title-ID fallback/updated time, already-bound disabled selection, task-already-linked rejection, global task-repo filtering, partial metadata warnings, and runtime-unknown display.
- [ ] Add action assertions: Enter handles a conversation-only task; 'a' on Claude-linked task does not offer replacement provider; picker selection saves without starting; 's' and 'x' confirmations explain preserving history; '?' documents hide/stop/resume and does not capture terminal input.
- [ ] Run `nvim --headless -u NONE -l tests/ui_e2e.lua`; expect failures for the revised UI behavior.
- [ ] Implement picker/status/action updates and help text. Document Claude resume capability, v2 incompatibility with old plugin versions, and Codex/Pi live-only scope in the minimal README. Distinguish session ID unavailable from confirmed offline.
- [ ] Run UI and lifecycle suites; expect their success messages and exit 0.

### Task 6: Float ownership and attach lifecycle

**Files:** Modify terminal.lua, board.lua where owner tab is passed, and tests/ui_e2e.lua.

**Interfaces:** terminal.open(key,identity,opts?) accepts opts={tabpage?:number,label?:string}; existing two-argument callers continue working. owner tab is a captured valid board tab, revalidated after async resolve; a closed/replaced board must not open a float in an unrelated tab.

- [ ] Add assertions capturing board tab/current window before asynchronous open. Verify a valid relative='editor' float appears in that board tab with a session label/hide hint; the board remains visible below it.
- [ ] Add hide/reopen, attach exit, closed owner tab, stale callbacks, replacement runtime, and controller-conflict assertions. Hide keeps the attach job; cleanup does not erase the persisted conversation or close a newer terminal entry.
- [ ] Run `nvim --headless -u NONE -l tests/ui_e2e.lua`; confirm the new ownership/footer requirements fail.
- [ ] Implement direct terminal attachment in the captured board tab and float title/footer. Preserve the existing q-in-normal-terminal-mode hide mapping and literal terminal input. Treat failed/exited attachment as a client error with recovery guidance, never as automatic runtime stop or takeover.
- [ ] Run the UI suite; expect `agent-board ui e2e passed`, exit 0. This proves Neovim ownership behavior; Task 7 must prove actual Herdr presentation.

### Task 7: Isolated real-Herdr acceptance and final review

**Files:** Create tests/herdr_resume_e2e.lua with reproducible local fixture setup/cleanup; adjust only defects found in Tasks 1–6. Keep runtime evidence under uncommitted docs/.

**Interfaces:** Test runner accepts explicit isolated HERDR_SESSION/HERDR_SOCKET_PATH and synthetic CLAUDE_CONFIG_DIR; fake Claude executable logs argv and reports a native session reference through official compatible Herdr reporting. Use no current user panes and no LLM requests.

- [ ] Build isolated new/offline history fixtures and a provider executable handling --session-id/--resume and exit. Report native UUID through the same supported identity channel required by Task 3; do not bypass identity verification by patching production resolve/list functions.
- [ ] Run acceptance from an external Neovim process and from Neovim inside an isolated Herdr pane. Assert Enter creates a real float over the board, parent Herdr workspace/tab focus does not switch, typed fixture input reaches the correct terminal, and a second controller produces an error rather than takeover.
- [ ] Exercise bind-offline -> Enter -> exit -> Enter, stop -> Enter, hide/reopen, and independent Neovim restart with surviving runtime. Check exact UUID/argv, runtime replacement, one-start concurrency, persisted task state, and unchanged Claude history except fixture-owned records.
- [ ] Stop only test-created servers/processes, and record success/failure/coverage in docs/. Expected result: `Herdr conversation resume acceptance passed`, exit 0; record terminal captures for inside/outside Herdr separately.
- [ ] Run final deterministic suites in order: `nvim --headless -u NONE -l tests/claude_sessions.lua`, `tests/check.lua`, `tests/conversation_lifecycle.lua`, and `tests/ui_e2e.lua` with the same command prefix. Each must exit 0 with its documented success message. Run `git diff --check` and review production diff against spec sections 4–9.
- [ ] Record actual Claude CLI coverage separately. Launching a real Claude fixture session requires explicit agreement on that session; fake-provider results must not be described as real Claude resume verification. If that check is deferred, state the precise integration boundary and any missing native-ID capability.
- [ ] Obtain the final independent review required by the chosen execution skill; fix in-scope findings and repeat only affected checks. Do not commit/push/update the installed plugin until those actions are authorized; docs stay uncommitted.

## Self-review and handoff

Coverage map: spec 4 -> Task 2/4; spec 5 -> Task 1/4/5; spec 6 -> Task 3/4;
spec 7 -> Task 6/7; spec 8 -> file map; spec 9 -> task assertions and Task 7.
All five Review Focus items have named tests. Async signatures, durable/runtime field
names, provider compatibility, and failure semantics are shared above.

Dependencies: Tasks 1 and 2 supply metadata/storage; Task 3 supplies runtime transport;
Task 4 joins them; Tasks 5 and 6 expose the user experience; Task 7 checks the real
integration. This is one coordinated lifecycle change, not independent product subsystems.

Await user review of this plan and execution method selection. Recommend native
execution because the seven tasks share lifecycle and schema contracts and fit the
existing small Lua plugin; independent review remains a final gate. Subagent-driven
execution is available when the user explicitly chooses it. No implementation has begun.
