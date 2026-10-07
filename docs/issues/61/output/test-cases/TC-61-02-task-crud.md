# TC-61-02 — CRUD task bằng phím TUI

- Class: acceptance
- Status: PASS, local PTY fixture
- Evidence: PTY text screen captures (TUI-specific adaptation) và persisted JSON; không phải screenshot/pixel evidence. Video không có recorder sẵn.
- Expected: `n`, `r`, `m`, `d`, `x` tạo, đổi tên, di chuyển, đánh dấu Done và xóa task; Cancel không mutate; xóa task đã link không stop agent; JSON phản ánh đúng title/status/card.
- Fixture: repo Git tạm, task Unicode có sẵn.

## Steps

1. Rename task Unicode bằng `r`.
2. Đánh dấu Done bằng `d`.
3. Tạo task bằng `n`, đổi cột bằng `m`, đổi tên bằng `r`; kiểm tra trạng thái và file JSON.
4. Chọn `x` rồi Cancel; xác nhận card còn nguyên. Xóa task bằng `x` và xác nhận; đối chiếu JSON.
5. Trên linked task, xác nhận delete không đóng phiên Herdr.

## Actual

Create, rename Unicode, Doing, Done, cancel delete và confirm delete đều khớp UI với JSON snapshot. Xóa linked task không gọi `pane close`; fake Herdr marker vẫn live.

## Evidence

Evidence: PTY [created](../evidence/pty-crud-created.txt), [renamed](../evidence/pty-crud-renamed.txt), [Doing](../evidence/pty-crud-doing.txt), [Done](../evidence/pty-crud-done.txt), [delete cancelled](../evidence/pty-crud-delete-cancel.txt), [deleted](../evidence/pty-crud-deleted.txt); JSON snapshots [created](../evidence/pty-crud-created.json), [renamed](../evidence/pty-crud-renamed.json), [Doing](../evidence/pty-crud-doing.json), [Done](../evidence/pty-crud-done.json), [cancel](../evidence/pty-crud-delete-cancel.json), [deleted](../evidence/pty-crud-deleted.json). Linked-delete assertion: [check](../evidence/pty-delete-linked-check.txt).
