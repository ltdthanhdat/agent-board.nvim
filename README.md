# AgentBoard

Kanban board cục bộ trong Neovim cho task coding, với một liên kết Herdr hiện tại cho mỗi task.

## Yêu cầu

- Neovim 0.10 trở lên.
- Git để tìm repo root.
- Herdr 0.7.5 trở lên và một Herdr server đang chạy để start, bind, attach, gửi prompt hoặc stop agent. CRUD vẫn dùng được khi Herdr không sẵn sàng.
- Provider được cài trong Herdr: Claude Code, Codex hoặc Pi.

Plugin không tự cài dependency, khởi động Herdr server, hay gửi prompt khi chưa có thao tác người dùng.

## Cài đặt

### Thử local

Trong Neovim:

```vim
:set runtimepath+=/absolute/path/to/agent-board
```

Sau đó mở repo Git bằng `:AgentBoard`, hoặc mở danh sách repo đã đăng ký bằng `:AgentBoard global`.

### lazy.nvim

```lua
{
  dir = '/absolute/path/to/agent-board',
  name = 'agent-board.nvim',
  lazy = false,
  config = function()
    require('agent-board').setup()
  end,
}
```

`:AgentBoard` chỉ nhận đối số rỗng hoặc `global`. Trong thư mục ngoài Git, dùng `:AgentBoard global`.

## Thao tác

Board mở ở tab riêng. Các phím chỉ hoạt động trong buffer board.

Trên màn hình hẹp, board giữ ba cột và tắt wrap; dùng `zh` / `zl` để cuộn ngang.

| Phím | Hành động |
| --- | --- |
| `n` | Tạo task; ở global chọn repo trước |
| `r` | Đổi tên task |
| `m` | Chọn cột Todo, Doing hoặc Done |
| `d` | Đánh dấu Done, không dừng agent |
| `a` | Chọn provider và start agent |
| `b` | Chọn agent Herdr đang chạy để bind |
| `<CR>` | Mở hoặc focus floating terminal của agent |
| `p` | Gửi prompt |
| `x` | Xác nhận rồi xóa task và liên kết |
| `s` | Xác nhận rồi dừng agent và đóng pane Herdr |
| `h` / `l` | Chuyển cột |
| `j` / `k` | Chuyển card trong cột |
| `g` | Chuyển repo/global; từ card global về repo của card |
| `q` | Đóng board |

Trong floating terminal, `<C-\><C-n>` về Normal mode rồi `q` để ẩn cửa sổ. Việc ẩn hoặc đóng Neovim chỉ kết thúc attach client; Herdr tiếp tục sở hữu agent.

## Dữ liệu và phục hồi

- Mỗi repo có `.agent-board.json`. Plugin sở hữu schema và các thao tác ghi; file có thể được commit cùng repo nếu muốn chia sẻ task.
- Registry tại `stdpath('data')/agent-board/repos.json` chỉ ghi repo root đã mở bằng `:AgentBoard`.
- Global chỉ tổng hợp các repo trong registry. Repo đã bị xóa hoặc di chuyển sẽ hiện cảnh báo.
- Ghi dùng lock độc quyền, kiểm tra snapshot và atomic rename. Nếu Neovim bị kill, file `.lock` còn lại sẽ chặn writer tiếp theo. Trước khi xóa lock thủ công, kiểm tra không còn Neovim nào đang ghi board/registry đó.
- JSON hỏng hoặc schema không hỗ trợ sẽ báo lỗi và không bị ghi đè. Sao lưu file, sửa JSON/schema rồi mở lại.
- Nếu Herdr start thành công nhưng lưu board thất bại, lỗi trả kèm `agent.terminal_id` và host ID để có thể bind lại. Plugin không dừng agent trong trường hợp này.
- Mỗi session runtime chỉ được bind vào một task trong các repo đã đăng ký. Repo ngoài registry không thuộc phạm vi kiểm tra trùng.

Stop xác nhận rõ và dùng Herdr để đóng pane đã kiểm tra identity. Stop không đổi cột task; xóa, rename và Done không dừng agent.

## Lua API

```lua
local board = require('agent-board')
board.focus_board({ scope = 'repo', repo = vim.fn.getcwd() })
board.focus_board({ scope = 'global' })

local tasks, warnings, snapshots = board.list_tasks({ scope = 'global' })
local ref = { repo = '/absolute/repo', id = 'task-id' }
board.start_agent(ref, { provider = 'codex' }, function(task, err)
  if err then vim.notify(err.message) end
end)
board.open_agent(ref, function(live_agent, err)
  if err then vim.notify(err.message) end
end)
```

Runtime calls are asynchronous and invoke `callback(value, err)` on Neovim's main loop. `err` contains `code` and `message`; after a successful start followed by a save failure it also contains `agent` and `host`. CRUD is synchronous and accepts the optional snapshot returned by `list_tasks` when rejecting stale views.

The terminal behavior adapted from herd.nvim is listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
