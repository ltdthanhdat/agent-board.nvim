# TC-61-01 — Board layout và trạng thái card

- Class: acceptance
- Status: PASS, local PTY fixture
- Evidence: PTY text screen captures (TUI-specific adaptation). Nội dung được ghi từ Neovim TUI thật, nhưng không phải screenshot/pixel evidence; video không có recorder sẵn.
- Expected: `:AgentBoard` mở board TUI có Todo / Doing / Done; title Unicode không làm vỡ card; provider và runtime state hiển thị riêng với task status; board vẫn dùng được ở 36×16 qua cuộn ngang.
- Fixture: hai repo Git tạm; Herdr CLI giả lập một Codex agent `working`.

## Steps

1. Mở `:AgentBoard` ở repo fixture.
2. Kiểm tra heading/card và provider/runtime state trong PTY 120×40.
3. Resize PTY còn 36×16, xác nhận ba cột không làm crash board, dùng `zh`/`zL` cuộn ngang và capture từng trạng thái.

## Actual

`AgentBoard` hiển thị ba cột và `codex · working` ở 120×40. Ở 36×16 board vẫn hoạt động và `zh`/`zL` đổi vùng ngang đang xem.

## Evidence

Evidence: [normal](../evidence/pty-normal-board.txt), [narrow](../evidence/pty-narrow-board.txt), [scroll left](../evidence/pty-narrow-left.txt), [scroll right](../evidence/pty-narrow-right.txt), [capture dimensions](../evidence/pty-environment.txt). Đây là text capture từ terminal, không phải pixel screenshot/video.
