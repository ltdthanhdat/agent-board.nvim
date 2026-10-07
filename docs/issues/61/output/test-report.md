# Runtime E2E: AgentBoard

## Phạm vi

- Issue: [#61 — Build agent-board.nvim](https://github.com/ltdthanhdat/obsidian/issues/61)
- Runtime: local Neovim TUI qua tmux PTY; không có browser surface.
- Checkout: `master`; implementation đang được kiểm tra từ working tree Task 5.
- Môi trường: Neovim 0.12.4, tmux 3.6a, hai Git repo fixture tạm, fake Herdr CLI.
- Account/role: không dùng account; chỉ dữ liệu fixture local.
- Fixture: [runtime-local-pty-fixtures.json](fixtures/runtime-local-pty-fixtures.json).
- Spec được duyệt: [AgentBoard MVP design](../../../superpowers/specs/2026-10-07-agent-board-design.md).
- Issue và hai comment mới nhất đã đọc qua `gh issue view`: issue cập nhật 2026-10-06; ưu tiên Herdr làm runtime duy nhất trong MVP và dùng floating Neovim terminal attach vào pane Herdr.

## Baseline và coverage

- Screen: board TUI Todo / Doing / Done.
- Bundle gần nhất trong runtime catalog: `list-table-screen`, dùng làm baseline cho collection; catalog không có bundle riêng cho terminal TUI.
- Modules: `runtime:env-readiness`, `runtime:screen-structure`, `runtime:initial-load`, `runtime:data-display`, `runtime:empty-loading-error`, `runtime:visual-layout`, `runtime:responsive-layout`, `runtime:form-input-behavior`, `runtime:primary-actions`, `runtime:navigation`, `runtime:refresh-and-persistence`.
- Không áp dụng: permission/role, URL state, pagination, search/filter/sort, email, browser network.
- Edge cases: Unicode title; màn hình hẹp 36×16; task ID giống nhau ở hai repo; tạo từ global vào repo đã chọn; cancel delete/stop; bind trùng agent; agent offline so với Herdr runtime unavailable; task ID, thứ tự và link sau khi đóng/mở board; Herdr list pending không chồng query; callback trả về sau khi đóng board; hide/reopen không tạo attach client thứ hai; stale mutation giữa hai Neovim process.
- Mockup: issue có ASCII wireframe Kanban; không tìm thấy HTML, image hoặc Figma mockup được duyệt trong repo. Đối chiếu thứ tự ba cột và card theo wireframe; pixel diff/computed-style không áp dụng cho terminal TUI.
- Evidence adaptation: PTY pane captures là text, không phải ảnh hoặc video; chúng ghi nội dung TUI ở terminal thật nhưng không tạo pixel/screenshot evidence. `asciinema` không cài sẵn; không thêm dependency chỉ để ghi video. Log headless là automated contract evidence. Các nhãn này không được tính vào catalog screenshot/video tiers.

## Ma trận requirement → case → status → evidence

| Requirement | Case | Status | Evidence |
| --- | --- | --- | --- |
| UI Neovim có ba cột, title Unicode và provider/runtime state | [TC-61-01](test-cases/TC-61-01-board-layout.md) | PASS, fixture local | PTY text captures; không có screenshot/video |
| Create, rename, move, Done, cancel/delete giữ dữ liệu đúng; delete không stop agent | [TC-61-02](test-cases/TC-61-02-task-crud.md) | PASS, fixture local | PTY text captures, JSON snapshots |
| Repo/global switching; tạo từ global vào đúng repo; task ID trùng giữa hai repo không nhầm đích | [TC-61-03](test-cases/TC-61-03-repo-global.md) | PASS, fixture local | PTY text captures, registry/JSON |
| Attach float, hide/reopen giữ cùng attach client; input và prompt đi qua fake CLI | [TC-61-04](test-cases/TC-61-04-herdr-float.md) | PASS, fixture local | PTY text captures, attach/input/prompt logs |
| `:AgentBoard` và mappings qua Neovim headless; persistence, bind/start/stop/send, selected-agent targeting, lỗi runtime, callback safety và stale prompt conflict sau poll | [TC-61-05](test-cases/TC-61-05-headless-ui-e2e.md) | PASS | `headless-ui-e2e.txt` |
| Runtime/lifecycle contracts: failed start, fail closed khi thiếu session identity, recovery sau save failure, bảo vệ live link, stale action identity, offline, duplicate/concurrent link, corrupt board, stale write giữa hai Neovim | [TC-61-06](test-cases/TC-61-06-runtime-contracts.md) | PASS trong headless/fake fixture | `runtime-contracts.txt`, [reproducible two-Neovim runner and output](evidence/two-neovim-stale-check.sh) |

## Kết luận

Case matrix đã được duyệt độc lập trước retest. Sáu case pass trên Neovim headless hoặc PTY thật với fake Herdr CLI. Người dùng chốt hoàn tất ở E2E UI hiện tại; đây không phải xác nhận live Herdr/provider. Capture pilot cũ trong `evidence/pilot-*` và `docs/superpowers/verification/2026-10-07-agent-board/` chỉ là tham khảo, không tính vào kết quả này.

## Giới hạn đã biết

- Fake Herdr CLI chỉ chứng minh giao diện attach hoạt động với terminal process và fixture identity. Chưa chứng minh kết nối tới Herdr server/provider thật hoặc prompt tới agent thật.
- Chỉ provider Codex có fixture UI; Claude Code và Pi chưa được kiểm chứng runtime.
- Theo phạm vi người dùng đã chốt, không chạy Herdr server, agent thật hoặc provider thật. Link sau khi khởi động lại Neovim cũng chưa được kiểm chứng.
- PTY text capture thể hiện nội dung terminal và layout ở 120×40/36×16; không có pixel screenshot hoặc video recorder trong môi trường.
