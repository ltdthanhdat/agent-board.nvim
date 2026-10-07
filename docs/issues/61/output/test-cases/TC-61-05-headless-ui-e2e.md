# TC-61-05 — Automated Neovim UI E2E

- Class: acceptance
- Status: PASS
- Evidence: automated UI contract log from headless Neovim; không thuộc catalog screenshot/video tier.
- Expected: command thật `:AgentBoard` mở board; mappings đi qua input Neovim; render và JSON khớp. Fake Herdr chỉ cho coverage contract/UI, không phải live runtime evidence.
- Command: `nvim --headless -u NONE -l tests/ui_e2e.lua`

## Steps

1. Chạy command trên từ repo root; kiểm tra exit code 0 và output `agent-board ui e2e passed`.
2. Script mở command thật hai lần, tạo/rename/move/Done/delete, xác nhận delete cancel, start và send prompt, attach/hide/reopen không spawn client mới.
3. Bind agent đã chạy, thử bind agent trùng vào task thứ hai, cancel/confirm stop; phân biệt offline với runtime unavailable và xác nhận cả hai giữ link.
4. Đóng rồi mở lại board; xác nhận ID, thứ tự task và agent link đã lưu.
5. Chuyển repo/global, tạo đúng repo đích, và sửa task ID giống nhau ở hai repo theo đúng repo đang focus.
6. Gọi refresh hai lần khi request pending; đóng buffer trước callback và xác nhận callback cũ không làm hỏng Neovim.

## Actual

Exit code 0; output `agent-board ui e2e passed`.

## Evidence

Evidence: [headless UI E2E log](../evidence/headless-ui-e2e.txt). Case này xác nhận command, mappings, buffer render assertions, persistence, lifecycle prompts, repo/global targeting, and callback safety; layout nhìn thấy được được xác nhận riêng ở TC-61-01 bằng PTY thật.
