# TC-61-03 — Chuyển repo/global và tạo đúng đích

- Class: acceptance
- Status: PASS, local PTY fixture
- Evidence: PTY text screen captures (TUI-specific adaptation), registry và persisted JSON; không phải screenshot/pixel evidence. Video không có recorder sẵn.
- Expected: mở repo A và B đăng ký đúng root; `g` chuyển sang global; `n` ở global chọn repo B và chỉ ghi task vào board B; `g` từ card đó quay về repo B.
- Fixture: hai repo Git tạm.

## Steps

1. Mở board repo A, sau đó repo B.
2. Chuyển sang global bằng `g`.
3. Tạo task qua `n`, chọn repo B.
4. Từ card global quay về repo của card bằng `g`.
5. Dùng task ID trùng ở hai repo để kiểm tra cursor/mutation vẫn trỏ đúng cặp repo + ID; đối chiếu registry và hai file JSON.

## Actual

Global liệt kê hai repo cùng basename bằng `[one/same-name]` và `[two/same-name]`. Hai board dùng cùng task ID; rename từ global chỉ sửa Repo B. Tạo task từ global ghi vào Repo B; `g` quay lại board B.

## Evidence

Evidence: [repo B](../evidence/pty-repo-b.txt), [global](../evidence/pty-global.txt), [rename same ID](../evidence/pty-global-rename.txt), [create from global](../evidence/pty-global-created.txt), [return to repo](../evidence/pty-global-to-repo.txt), [registry](../evidence/pty-registry-final.json), [Repo A JSON](../evidence/pty-repo-a-final.json), [Repo B JSON](../evidence/pty-repo-b-final.json).
