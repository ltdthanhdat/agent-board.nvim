# TC-61-04 — Floating terminal attach/hide/reopen

- Class: acceptance (fixture runtime)
- Status: PASS, fake local Herdr CLI fixture
- Evidence: PTY text screen captures (TUI-specific adaptation), attach/input logs; không phải screenshot/pixel evidence. Video không có recorder sẵn.
- Expected: `<CR>` mở floating terminal rounded attach vào pane identity hiện tại; gõ trực tiếp trong float đi tới stdin của attach process; `<C-\><C-n>` rồi `q` chỉ ẩn float; mở lại cùng task dùng attach client đang chạy, không tạo client thứ hai. Phím `p` gửi prompt là luồng riêng, được kiểm tra ở TC-61-05.
- Fixture: fake Herdr CLI và fake Codex pane; không dùng Herdr server hoặc agent thật.

## Steps

1. Mở task đang liên kết bằng `<CR>`.
2. Capture float.
3. Hide bằng `<C-\><C-n>`, `q`, rồi mở lại bằng `<CR>`.
4. Gõ chuỗi vô hại trực tiếp trong float, nhấn Enter, rồi xác nhận fake attach process nhận đúng stdin trong fixture log.
5. Đọc attach log để xác nhận chỉ một attach process được tạo.

## Actual

Float rounded mở đúng task. Gõ `SAFE_INPUT_61` trong float tới attach stdin; hide/reopen chỉ tạo một attach client. Board command `p` gửi prompt qua fake Herdr CLI. Không có server/provider thật.

## Evidence

Evidence: [float](../evidence/pty-normal-float.txt), [hidden board](../evidence/pty-normal-hidden.txt), [reopened float](../evidence/pty-normal-reopen.txt), [attach count](../evidence/pty-attach-count.txt), [attach stdin](../evidence/pty-attach-input.txt), [prompt CLI](../evidence/pty-prompt-log.txt). Đây không phải xác nhận Herdr server/provider thật.
