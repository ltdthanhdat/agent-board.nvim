# AgentBoard MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Xây board repo/global trong Neovim để quản lý task và liên kết một phiên Herdr hiện tại cho mỗi task.

**Architecture:** Scratch buffer gọi public Lua API chung. JSON mỗi repo giữ task; registry chỉ giữ repo root. Herdr adapter chạy CLI async, còn floating terminal là attach client của Herdr.

**Tech Stack:** Lua, Neovim ≥ 0.10, `vim.system`, `vim.uv`, JSON native, Git CLI, Herdr ≥ 0.7.5. Không thêm thư viện runtime hoặc framework test.

**Spec:** `docs/superpowers/specs/2026-10-07-agent-board-design.md`

## Global Constraints

- Mỗi repo có một board. Global là màn hình tổng hợp các board đã đăng ký.
- Mỗi task thuộc một repo, kể cả khi tạo từ global.
- Mỗi task giữ một session hiện tại. Không lưu lịch sử session trong MVP.
- Khởi động agent thành công chuyển task sang Doing. Người dùng đánh dấu Done.
- Có thể liên kết task với agent Herdr đã chạy sẵn.
- Đóng float hoặc Neovim không dừng agent.
- Chỉ hỗ trợ Herdr local trong MVP. Không tự khởi động daemon.
- UI gọi API chung, không tự sửa file dữ liệu.
- Giữ copyright/license MIT khi sao chép code herd.nvim.
- Không fork Kanban plugin, thêm tmux, ANSI renderer, SQLite, MCP/RPC hoặc framework adapter.
- Không thêm AI co-author vào commit. Git worktree nếu cần chỉ nằm trong `.worktrees/<branch-name>`.

## Review Focus

1. Repo có space, Unicode hoặc symlink: argv nguyên vẹn, registry chuẩn hóa một đường dẫn thực (Task 2/3).
2. Hai Neovim bind cùng agent hoặc sửa cùng file: chỉ một writer thành công, writer còn lại nhận conflict (Task 1/4).
3. Agent chạy được nhưng save thất bại: trả identity để phục hồi, không stop agent hay báo đã lưu (Task 4).
4. Pane bị thay agent hoặc server restart: không attach/send/stop nhầm occupant (Task 3/4).
5. Window đóng trong lúc query đang chạy: callback không ghi vào buffer chết, poller được dừng (Task 5).

## Trạng thái đầu vào và các quyết định triển khai

- Workspace mới trên Git local `master`; không có code cũ cần tương thích.
- Đã kiểm tra help của binary ngày 2026-10-07: Neovim 0.12.4, Herdr 0.7.5; không coi đây là bằng chứng runtime.
- `agent start NAME --kind KIND --pane ID`, `agent attach TARGET`, `agent prompt TARGET TEXT` có trên CLI.
- Không có `agent stop`; MVP dùng `pane close ID` sau kiểm tra identity. UI xác nhận rõ “dừng agent và đóng pane”, áp dụng cả phiên bind từ ngoài; không âm thầm dùng Ctrl-C vì Ctrl-C không bảo đảm thoát agent.
- Phiên khảo sát không có `HERDR_ENV=1`; không inspect/control session Herdr của người dùng từ phiên này. Task 6 cần môi trường kiểm chứng cô lập hợp lệ.
- Herdr v0.7.5 `AgentInfo` có `terminal_id`, `pane_id`, `agent_status`, optional `name` và optional `agent_session.value`; status không có server-incarnation UUID. Khóa server là route local (`HERDR_SOCKET_PATH` hoặc `HERDR_SESSION`/`default`); occupant proof là `terminal_id`, cộng `agent_session.value` khi đã lưu. `name` có thể vắng ở agent phát hiện sẵn. Không derive terminal/session ID từ pane/name.
- Status refresh: mỗi 2 giây khi board visible, một query async; không chồng query. Lỗi query hiển thị runtime unavailable, không đổi liên kết thành offline.
- CRUD đồng bộ trả `value, err`; runtime async nhận callback cuối cùng `cb(value, err)`, được gọi đúng một lần trên main loop. `err = { code, message, agent? }`.
- Snapshot là raw bytes, kể cả trạng thái missing; revision tăng sau mỗi write. So sánh bytes để phát hiện cả sửa ngoài plugin không tăng revision.
- Khóa filesystem dùng exclusive create, không chờ chặn UI. Lock registry là coordinator cho mọi mutation; sau đó lock board đích. Thứ tự luôn registry → board, không lấy lại registry lock lồng nhau. Giữ khóa qua start async, giải phóng mọi nhánh lỗi; lock sau crash được báo để xử lý thủ công.

## Files và contracts

| File | Trách nhiệm |
| --- | --- |
| `lua/agent-board/storage.lua` | Read/validate JSON, snapshots, exclusive locks, atomic writes, registry |
| `lua/agent-board/tasks.lua` | Repo identity, task CRUD, global aggregation, liên kết/lifecycle |
| `lua/agent-board/herdr.lua` | Async CLI, normalization, identity verification, start/send/close |
| `lua/agent-board/terminal.lua` | Float attach/hide, terminal buffers |
| `lua/agent-board/init.lua` | Public API, setup; forwarding tới modules |
| `lua/agent-board/board.lua` | Board render, navigation, user prompts, polling |
| `plugin/agent-board.lua` | Đăng ký `:AgentBoard [global]` |
| `tests/check.lua` | Một headless entry point cho store/logic/runtime seams; không framework |
| `tests/ui_e2e.lua` | E2E Neovim command, mappings, buffer và persisted JSON |
| `README.md` | Install, mappings, runtime requirements, recovery/limits |
| `THIRD_PARTY_NOTICES.md` | License/copyright phần terminal thích nghi |

Shared types: `Ref={repo:string,id:string}`; `Task` như spec; `ViewTask={repo:string,task:Task}`; `Identity={provider,runtime='herdr',server,terminal_id,pane_id,name?,session_id?}`; `LiveAgent={identity,cwd,state}`. `cb` runtime luôn nhận result hoặc structured error. Không ghi runtime state transient vào JSON.

### Task 1: JSON store an toàn

**Files:** Create `lua/agent-board/storage.lua`, `tests/check.lua`.

**Interfaces:** Produces `storage.read(path, kind) -> document,snapshot | nil,err`; `storage.lock(path) -> release | nil,err`; `storage.write_locked(path, document, snapshot) -> new_snapshot | nil,err`; `storage.registry_path() -> string`. `kind` chỉ `board` hoặc `registry`; registry document là `{version=1,revision=0,repos={}}`.

- [ ] Viết assertions trong `tests/check.lua` dùng tmpdir: missing board trả version 1/revision 0/tasks rỗng; roundtrip Unicode/null; duplicate ID, status/provider sai, JSON hỏng và version khác 1 đều bị từ chối. Kiểm tra lock thứ hai thất bại; snapshot cũ không overwrite; write lỗi giữ file cũ và release lock.
- [ ] Chạy `nvim --headless -u NONE -l tests/check.lua`; kỳ vọng FAIL vì module chưa có.
- [ ] Implement contracts bằng `vim.json`, `vim.uv`; temporary file cùng directory, kiểm tra tất cả return/error của write/close/rename; dọn temporary file trên lỗi. Validate raw JSON table/list/null, title không rỗng, revision integer không âm, agent fields đúng type. Không tạo empty document khi read bị lỗi.
- [ ] Chạy cùng lệnh; kỳ vọng exit 0 và `agent-board checks passed`.
- [ ] Khi execution đã tạo Git repo, commit đúng hai file: `feat: add safe JSON board storage`.

### Task 2: Task CRUD, repo và global

**Files:** Create `lua/agent-board/tasks.lua`, `lua/agent-board/init.lua`; extend `tests/check.lua`.

**Interfaces:** Consumes Task 1. Produces `tasks.resolve_repo(cwd) -> root | nil,err`, `tasks.list_tasks(opts) -> ViewTask[],warnings,snapshots | nil,err`, `tasks.get_task(ref)`, `tasks.create_task(opts,expected_snapshot?)`, `tasks.update_task(ref,patch,expected_snapshot?)`, `tasks.move_task(ref,status,expected_snapshot?)`, `tasks.delete_task(ref,expected_snapshot?)`, `tasks.register_repo(root)`. Init exports public CRUD functions plus `setup(opts)`; list snapshots map canonical repo roots to storage snapshots; CRUD returns saved task (delete returns true).

- [ ] Thêm assertions: tạo hai temp Git repo, một đường dẫn space/Unicode và một symlink; đăng ký symlink không tạo duplicate. Tạo/move/rename/reload giữ ID; title duplicate được phép, ID không trùng. Global chứa đúng hai repo; delete chỉ sửa board đích. Repo missing cảnh báo nhưng repo tốt vẫn đọc được; board hỏng không bị bỏ qua khi kiểm tra tính duy nhất liên kết. Patch agent/ID/status ngoài API riêng bị từ chối.
- [ ] Chạy headless check; kỳ vọng FAIL ở contracts mới.
- [ ] Implement Git toplevel bằng argv và `fs_realpath`; stable opaque IDs bằng native randomness nếu có, hoặc SHA-256 của high-resolution time/process/counter với kiểm tra collision trong document. Registry mutations và CRUD luôn lock registry rồi board, so snapshot, save, release. List/get reload từ disk; UI snapshot được truyền nội bộ cho mutation để stale view nhận conflict. Không cho public caller bypass validator.
- [ ] Chạy check; kỳ vọng exit 0. Xác nhận temp Git repos chỉ nằm trong tmpdir.
- [ ] Commit files Task 2, tests, and this interface clarification: `feat: add repo and global task API`.

### Task 3: Herdr transport và định danh

**Files:** Modify `lua/agent-board/storage.lua`; Create `lua/agent-board/herdr.lua`; extend `tests/check.lua`.

**Interfaces:** Produces `Identity={provider,runtime='herdr',server,terminal_id,pane_id,name?,session_id?}` and `LiveAgent={identity,cwd,state}`; `herdr.list(cb)`, `herdr.resolve(identity,cb)`, `herdr.start(repo,provider,name,cb)`, `herdr.send(identity,message,cb)`, `herdr.stop(identity,cb)`, `herdr.attach_argv(identity) -> string[]`. Transport seam `herdr.run(argv,timeout_ms,cb)` uses `vim.system`; fake thay hàm này trong check. Start returns Identity and owned host IDs; resolve returns LiveAgent or `offline`/`identity_mismatch`/`runtime_unavailable`.

- [x] Đọc source canonical Herdr v0.7.5 tại commit `ef4c23f5775bb8cfec05f05d0844226ff959a07a`: `AgentInfo`/`PaneInfo` có `terminal_id`, `pane_id`, `agent_status`; `AgentInfo.name` và `agent_session` là optional. CLI status không phát server-incarnation UUID.
- [ ] Thêm fake transport assertions theo JSON envelope thật: list/get/start, unnamed existing agent, malformed/null JSON, agent-not-found/offline, nonzero/timeout/runtime-unavailable. Server route, `terminal_id`, hoặc stored `agent_session.value` đổi thì attach/send/close bị chặn. `terminal_id` bắt buộc khi lưu; argv giữ nguyên repo/name/message có space và shell metacharacters; callback đúng một lần.
- [ ] Chạy check; kỳ vọng FAIL ở adapter.
- [ ] Implement async contracts, `vim.schedule` callbacks và timeout hữu hạn. Dedicated workspace label `agent-board.nvim`; create tab `--cwd repo --no-focus`, lấy IDs từ JSON rồi start unique name hợp lệ Herdr. Không prune workspace hoặc đóng tài nguyên có sẵn. Identity lưu route local, terminal ID từ AgentInfo và optional `agent_session.value`; bind cho phép name null. Nếu start timeout, xác minh occupant trước khi dọn host; nếu không chắc, trả host identity để recovery.
- [ ] Implement send bằng `agent prompt` không `--wait`; stop kiểm tra identity rồi `pane close`. Queries tối đa 5 giây, start CLI tối đa 35 giây với Herdr readiness timeout 30 giây. Không mặc định server absence thành agent absence.
- [ ] Chạy check; kỳ vọng exit 0; ghi CLI contract vào ledger để README ở Task 5 nêu Herdr 0.7.5 yêu cầu.
- [ ] Commit adapter/tests: `feat: add async Herdr runtime adapter`.

### Task 4: Liên kết session và floating terminal

**Files:** Modify `tasks.lua`, `init.lua`; Create `terminal.lua`, `THIRD_PARTY_NOTICES.md`; extend `tests/check.lua`.

**Interfaces:** Consumes Tasks 1–3. Public async API `start_agent(ref,opts,cb)`, `bind_agent(ref,identity,cb)`, `open_agent(ref,cb)`, `send(ref,message,cb)`, `stop_agent(ref,cb)`; synchronous `hide_agent(ref)`. Terminal exports `open(key,identity)`, `hide(key)`, `is_open(key)`; key includes repo/task/runtime identity, not title.

- [ ] Thêm checks: start fail giữ Todo; start success lưu liên kết + Doing cùng write. Existing live link mở phiên cũ, không spawn. Bind không đổi cột; duplicate trong board khác bị chặn. Save failure sau start trả `err.agent`, không stop. Delete/rename/done không gọi stop. Stop không đổi cột. Hai coordinator acquisitions bind cùng agent chỉ một thành công; missing/corrupt board trong registry không cho bypass uniqueness.
- [ ] Thêm terminal checks với fake attach process: hide giữ buffer/job, reopen không spawn lần hai; attach exit dọn registry; reopen sau exit tạo client mới. Session replacement không reuse client cũ. Callback cũ không dọn buffer của client mới.
- [ ] Chạy check; kỳ vọng FAIL ở lifecycle/terminal.
- [ ] Implement lifecycle dưới coordinator lock; giữ snapshot từ trước start để save conflict sau side effect được báo recovery. Revalidate live identity trước action; duplicate check toàn registered boards. Release locks mọi đường callback và timeout.
- [ ] Thích nghi terminal từ herd.nvim commit `aabb981b6198bafa4603d2db3e26b206352f6379`, dùng `nvim_open_win` + `termopen(argv)`. Float mặc định width 0.85/height 0.80/border rounded, clamp theo screen. Hide mapping `<C-\><C-n>` chuyển normal terminal mode rồi `q` buffer-local hide; không trộn mappings board vào agent input. Ghi nguyên copyright và MIT notice của phần sao chép.
- [ ] Chạy check; kỳ vọng exit 0. Kiểm tra attach client shutdown không gọi runtime stop.
- [ ] Commit lifecycle/terminal/tests/license: `feat: link tasks to persistent Herdr sessions`.

### Task 5: Board UI và command

**Files:** Create `board.lua`, `plugin/agent-board.lua`, `README.md`; Modify `init.lua`; extend `tests/check.lua`.

**Tests:** Create `tests/ui_e2e.lua` for the real Neovim command and keyboard flow.

**Interfaces:** Consumes public API Tasks 2/4 và `herdr.list(cb)`. Produces `board.open({scope,repo?})`, `board.close()`, `board.refresh()`; public `focus_board(opts)`. Command accepts only empty argument hoặc `global`.

- [ ] Thêm checks: render ba cột, cursor resolve đúng Ref kể cả ID giống nhau ở hai repo; navigation empty column không crash. Global repo names trùng có đường dẫn phân biệt; narrow screen/Unicode title không phá card targeting. Closing window giữa query không update buffer chết; repeated refresh không chồng process và stop timer khi hide/close.
- [ ] Chạy check; kỳ vọng FAIL ở UI.
- [ ] Thêm `tests/ui_e2e.lua`: chạy plugin thật trong headless Neovim với hai tmp Git repo; mở `:AgentBoard`, gửi key qua `nvim_feedkeys` cho create → rename → move → Done → delete, rồi assert rendered buffer, repo/global scope và JSON sau mỗi thao tác. Dùng storage/API thật; stub riêng câu trả lời `vim.ui.input/select`; fake Herdr transport ở bước start/bind.
- [ ] Chạy `nvim --headless -u NONE -l tests/ui_e2e.lua`; kỳ vọng FAIL vì plugin command/UI chưa có.
- [ ] Implement scratch buffer unmodifiable và line/card hit map, dùng display width cho Unicode, horizontal scrolling trên màn hẹp. Bind mappings đúng spec; `d` gọi move Done, `x` confirm delete, `s` confirm stop **và đóng pane**, `b` chọn agent và ghi rõ already-bound. `n` global chọn repo. Offline open đề nghị start nhưng không tự start. `g` về selected repo hoặc picker nếu không có selected task.
- [ ] Implement một timer 2 giây chỉ khi visible và query đang không pending; lỗi status giữ task/link, hiện runtime unavailable. UI actions gọi API với snapshot đang hiển thị, conflict nhắc reload. Prompt bằng `vim.ui.input/select`; cancel không mutation. Task creation chọn provider lúc start, không bắt buộc runtime sẵn để CRUD.
- [ ] Đăng ký command idempotent; thêm README install local/lazy.nvim, requirements, mappings, `.agent-board.json` ownership, registry/lock recovery, stop-pane semantics và public API callback examples. Không có implicit keymaps ngoài board/terminal.
- [ ] Chạy `nvim --headless -u NONE -l tests/ui_e2e.lua`; kỳ vọng command, keymaps, rendered buffer, repo/global scope và JSON cùng khớp. Đây là E2E tự động qua Neovim thật nhưng headless; không coi là bằng chứng layout nhìn thấy được.
- [ ] Chạy E2E tương tác trong Neovim TUI qua PTY cô lập ở kích thước thường và hẹp: mở `:AgentBoard`, dùng phím thật tạo/đổi tên/di chuyển/xóa task, chuyển repo/global, mở rồi hide/reopen floating terminal bằng fixture agent. Kiểm tra screen render, focus, cuộn ngang, keymap không lọt vào agent, và JSON sau luồng; lưu screen capture/terminal transcript vào `docs/superpowers/verification/2026-10-07-agent-board/`.
- [ ] Commit UI/README/tests: `feat: add repo and global Kanban board`.

### Task 6: Kiểm chứng runtime và hoàn tất MVP

**Files:** Modify `README.md` chỉ khi có limits thực tế; Create `docs/superpowers/verification/2026-10-07-agent-board.md` để ghi bằng chứng.

**Interfaces:** Consumes toàn MVP, không thêm chức năng mới.

- [ ] Chạy `nvim --headless -u NONE -l tests/check.lua`; kỳ vọng exit 0 trước live checks.
- [ ] Chạy `nvim --headless -u NONE -l tests/ui_e2e.lua`; kỳ vọng plugin command và thao tác bàn phím CRUD/global hoàn tất trên hai repo tạm. Đây là UI E2E qua Neovim thực; layout trực quan được kiểm tra trong PTY ở Task 5.
- [ ] Chạy lại E2E tương tác TUI trong PTY sạch theo Task 5; ghi capture cho board ở kích thước thường/hẹp và floating terminal sau open/hide/reopen, cùng kết quả CRUD/repo-global và JSON. Báo riêng lỗi tương tác/render với lỗi Herdr runtime.
- [ ] Trong môi trường Herdr hợp lệ, tạo session test cô lập và hai Git repo tạm, không dùng agent/pane sẵn của người dùng. Nếu harness/skill chưa cho phép tạo môi trường test, ghi blocker và yêu cầu môi trường đó; không báo pass runtime.
- [ ] Kiểm chứng thủ công bằng Neovim thật: CRUD/reload, repo/global switching, create từ global đúng đích, delete không stop, stale edit giữa hai Neovim trả conflict. Ghi command/setup và kết quả.
- [ ] Với từng provider đã cài, start → Doing → attach → prompt vô hại → hide → reopen cùng identity → quit/reopen Neovim → attach lại. Kiểm tra bind phiên đã mở trước và duplicate-link rejection. Ghi provider vắng mặt là chưa kiểm chứng.
- [ ] Chỉ trong session test, stop có confirm đóng đúng pane; session missing hiện offline; mất kết nối hiện runtime unavailable. JSON hỏng không overwrite. Dọn chỉ tài nguyên test tạo ra và các khóa/temp file do kiểm chứng tạo.
- [ ] Rà diff với spec: không có dependency mới, remote/MCP/Sidekick/history, arbitrary Lua eval hoặc AI commit attribution. Báo riêng headless pass và live provider/terminal evidence; không gọi mock là E2E.
- [ ] Commit documentation/runtime fixes nếu có; không push/publish. Bàn giao file thay đổi, các checks thực chạy và hạn chế còn lại.

## Execution setup và handoff

Plan đã được self-review theo coverage, contracts, concurrency, failure recovery và phạm vi. Người dùng đã duyệt Native trên `master`. Chưa chạy tests, chưa viết product code.

Workspace có Git local trên `master` chưa có commit; ghi baseline spec/plan rồi thực hiện task trên branch này theo lựa chọn rõ ràng của người dùng. Không cấu hình remote hoặc push. Không tạo worktree.

Đề xuất **Native** vì sáu task phụ thuộc trực tiếp API và lifecycle của nhau; tự triển khai tuần tự giảm chi phí chuyển context. Nếu chọn subagent-driven, tuân theo skill tương ứng và review từng task.
