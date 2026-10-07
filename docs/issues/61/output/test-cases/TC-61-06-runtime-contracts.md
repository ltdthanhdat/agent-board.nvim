# TC-61-06 — Runtime và recovery contracts

- Class: acceptance
- Status: PASS
- Evidence: deterministic headless contract assertions/log plus a reproducible two-process stale-write run; không thuộc catalog screenshot/video tier và không phải live Herdr evidence.
- Expected: lỗi runtime hoặc storage không làm mất task/link hay dừng agent vô tình; link chỉ duy nhất khi bind đồng thời; stale/corrupt data fail closed.
- Fixture: `tests/check.lua` tạo Git repos và Herdr transport fake trong thư mục tạm. Runner riêng tạo Git repo và registry trong thư mục tạm cho hai process Neovim.
- Commands:
  - `nvim --headless -u NONE -l tests/check.lua`
  - `bash docs/issues/61/output/evidence/two-neovim-stale-check.sh`

## Steps

1. Chạy command từ repo root; kiểm tra exit code 0 và output `agent-board checks passed`.
2. Xác nhận failed start giữ Todo và link rỗng; identity thiếu provider session ID fail closed và trả thông tin pane/agent đã khởi động. Save failure sau start trả identity để phục hồi, không stop agent. Bind chỉ thay link cũ khi Herdr xác nhận link đó offline; recovery bind giữ link cũ khi còn live.
3. Xác nhận offline, timeout và server error được phân biệt; runtime error không được diễn giải là agent offline.
4. Xác nhận agent đã link ở repo khác hoặc đã được bind đồng thời không thể link lần hai.
5. Xác nhận board đăng ký hỏng/mất ngăn bind fail-open và attempted bind giữ nguyên bytes JSON lỗi trong headless checks. Chạy runner hai process: cả hai đọc cùng revision, writer B cập nhật trước, writer A nhận yêu cầu reload; JSON cuối vẫn giữ title mới và Todo.
6. Xác nhận rename, Done và delete không stop linked agent; stale expected identity từ send/stop bị từ chối trước Herdr; stop qua fake Herdr chỉ gọi một lần và giữ task status/link.

## Actual

Hai commands exit 0. Headless output `agent-board checks passed`; assertions gồm failed start, identity sessionless fail closed, save failure recovery identity và bind, không thay link đang live, stale expected identity không gửi/dừng nhầm agent, corrupt board bytes giữ nguyên, stale snapshot, duplicate/concurrent link và lifecycle không stop agent khi rename/Done/delete. Runner hai process ghi `Neovim A rejected stale snapshot with reload-required error`, `Neovim B saved a newer task revision`, và xác nhận JSON cuối giữ title `Fresh update from Neovim B` cùng status `todo`.

## Evidence

Evidence: [runtime contracts log](../evidence/runtime-contracts.txt), [reproducible two-process runner](../evidence/two-neovim-stale-check.sh), [runner output and final board](../evidence/two-neovim-stale-check.txt), [previous Neovim A log](../evidence/two-neovim-a.log), [previous Neovim B log](../evidence/two-neovim-b.log), [previous persisted board](../evidence/two-neovim-stale-board.json), [fixture descriptor](../fixtures/two-neovim-stale-check.json). Các assertions deterministic không thay thế thao tác Herdr server/provider thật.
