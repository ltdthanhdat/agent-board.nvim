# agent-board.nvim — thiết kế MVP

Ngày: 2026-10-07. Nguồn: https://github.com/ltdthanhdat/obsidian/issues/61 và các quyết định trong cuộc trao đổi.

## Mục tiêu và quyết định đã chốt

Plugin Kanban native trong Neovim để quản lý task coding và mở phiên Claude Code, Codex hoặc Pi tương ứng. Neovim sở hữu task, UI và liên kết task ↔ session; Herdr sở hữu tiến trình và terminal của agent.

- Mỗi repo có một board. Global là màn hình tổng hợp các board đã đăng ký.
- Mỗi task thuộc một repo, kể cả khi tạo từ global.
- Mỗi task giữ một session hiện tại. Không lưu lịch sử session trong MVP.
- Khởi động agent thành công chuyển task sang Doing. Người dùng đánh dấu Done.
- Có thể liên kết task với agent Herdr đã chạy sẵn.
- Đóng float hoặc Neovim không dừng agent.

## Kiến trúc

```text
Board repo / global
        ↓
Public Lua API
        ├─ Task + JSON storage + repo registry
        └─ Herdr adapter + floating terminal attach
```

UI gọi API chung, không tự sửa file dữ liệu. API và runtime được chia thành module theo trách nhiệm; không tạo framework adapter, storage backend thay thế hay event bus tổng quát trong MVP.

Cấu trúc dự kiến tối thiểu:

```text
plugin/agent-board.lua          command
lua/agent-board/init.lua       setup và public API
lua/agent-board/tasks.lua      nghiệp vụ task
lua/agent-board/storage.lua    JSON và registry
lua/agent-board/herdr.lua      Herdr CLI
lua/agent-board/terminal.lua   float attach/hide
lua/agent-board/board.lua      scratch-buffer UI
```

## Khảo sát tái sử dụng

Đã clone và đọc code ngày 2026-10-07; chưa chạy kiểm chứng runtime.

| Dự án | Commit khảo sát | Kết luận |
| --- | --- | --- |
| [super-kanban.nvim](https://github.com/hasansujon786/super-kanban.nvim) | `fbddd3f48bf672dab1fc6ca26424f3a158623be9` | Có custom mappings, nhưng API mở board và lifecycle lưu gắn với Markdown/Org. Dùng cho JSON/global cần phụ thuộc internals hoặc fork. |
| [herdr-agents.nvim](https://github.com/ctbaum/herdr-agents.nvim) | `a34fae97b2e145711195a35bf60514d22b1a6d45` | API theo provider và tích hợp plugin IDE; không phải API theo task/session cần ở đây. |
| [herd.nvim](https://github.com/MomePP/herd.nvim) | `aabb981b6198bafa4603d2db3e26b206352f6379` | Module terminal có flow float → `herdr agent attach <pane-id>`, hide và reuse buffer phù hợp. |

Quyết định: dựng board bằng API Neovim; thích nghi phần terminal nhỏ từ herd.nvim và giữ copyright/license MIT khi sao chép. Không phụ thuộc toàn bộ ba plugin trên. Không viết ANSI renderer hay thêm tmux/session layer.

## Phạm vi board và repo

- `:AgentBoard`: xác định Git repo chứa cwd và mở board của repo đó.
- `:AgentBoard global`: mở tổng hợp task từ các repo đã đăng ký.
- `g`: chuyển repo/global. Từ global, repo đích là repo của card đang chọn; nếu không có card thì chọn repo.
- Mở board repo lần đầu đăng ký đường dẫn repo trong registry.
- Tạo task ở global dùng danh sách repo đã đăng ký để chọn đích.
- Card ở global ghi tên repo; nếu trùng tên thì bổ sung đường dẫn để phân biệt.
- Repo bị di chuyển/xóa hiện cảnh báo không truy cập được; các repo khác vẫn dùng được.

Giả định cụ thể hóa: repo root là Git toplevel, chuẩn hóa đường dẫn thực để tránh đăng ký trùng. Ngoài Git repo, `:AgentBoard` hướng dẫn mở global; không tự tạo board tùy ý tại cwd. Không quét toàn máy. Người dùng phải mở board của repo ít nhất một lần để đăng ký.

## UI và thao tác

Scratch buffer không chỉnh sửa trực tiếp, ba cột Todo / Doing / Done. Khi màn hình hẹp, cho phép cuộn ngang thay vì thêm layout thứ hai.

| Phím | Hành vi |
| --- | --- |
| `n` | Tạo task, mặc định Todo; global chọn repo trước |
| `r` | Đổi tên task |
| `m` | Chọn cột đích |
| `d` | Đánh dấu Done, không dừng agent |
| `a` | Chọn provider và khởi động agent |
| `b` | Chọn agent đang chạy để liên kết |
| `<CR>` | Mở/focus floating terminal của session hiện tại |
| `p` | Nhập và gửi prompt cho session liên kết |
| `x` | Xóa task và liên kết, có xác nhận; không dừng agent |
| `s` | Dừng agent liên kết, có xác nhận |
| `h/l`, `j/k` | Di chuyển giữa cột và card |
| `g` | Chuyển repo/global |
| `q` | Đóng board |

Phím `b`, `s` và việc dùng `x` để xóa là đề xuất cụ thể hóa, không phải mapping bắt buộc từ issue. Trong float, mapping hide chỉ ẩn cửa sổ; các mapping board không áp dụng cho terminal input.

Card hiển thị title, provider và agent state. Task state (`todo`, `doing`, `done`) độc lập với trạng thái Herdr (`working`, `blocked`, `idle`, `done`, `unknown`). `offline` chỉ dùng khi xác nhận phiên liên kết không còn; lỗi kết nối Herdr không được suy ra thành phiên đã mất.

## Dữ liệu và lưu trữ

Mỗi repo có `.agent-board.json`:

```json
{
  "version": 1,
  "revision": 1,
  "tasks": [
    {
      "id": "opaque-stable-id",
      "title": "Sửa lỗi đăng nhập",
      "status": "doing",
      "agent": {
        "provider": "codex",
        "runtime": "herdr",
        "server": "server-identity",
        "pane_id": "opaque-pane-id",
        "name": "agent-board-task-name",
        "session_id": null
      }
    }
  ]
}
```

ID task ổn định, không đổi khi rename. Task chưa liên kết có `agent: null`. Thứ tự mảng xác định thứ tự card trong mỗi cột. Global dùng cặp `(repo_root, task_id)` để định vị task.

`server`, `pane_id`, `name` biểu diễn liên kết Herdr; trường nhận diện chính xác phải được đối chiếu CLI thực tế trước implementation. Không giả định pane ID chính là conversation/session ID của provider. `session_id` chỉ có giá trị khi runtime thực sự cung cấp; không cần nó để attach vào phiên còn chạy. Khi runtime identity thay đổi, kiểm tra lại liên kết trước khi gửi input hoặc stop để tránh điều khiển nhầm agent.

Registry tại `stdpath('data')/agent-board/repos.json`, chỉ chứa danh sách repo root. Không nhân bản task vào global store.

Đọc file phải validate schema, version, task ID, title, status và provider. File không tồn tại được coi là board rỗng; file hỏng hoặc version không hỗ trợ báo lỗi và không ghi đè.

Ghi file tạm cùng thư mục rồi rename thay thế. Mọi thao tác ghi lấy khóa độc quyền cho file đích, đọc lại và kiểm tra revision/nội dung so với snapshot đang dùng; có thay đổi thì yêu cầu reload, không ghi đè. Cơ chế này áp dụng cả registry. Khóa bỏ trong đường lỗi thông thường; khóa tồn tại sau crash báo rõ để người dùng xử lý, không tự xóa khi chưa biết writer còn sống hay không. Rename nguyên tử bảo vệ file khỏi ghi dở, còn khóa + kiểm tra snapshot bảo vệ khỏi hai instance ghi đè nhau.

## Herdr và lifecycle

Chỉ hỗ trợ Herdr local trong MVP. Cần Neovim có terminal/job API phù hợp và một Herdr server đang chạy. Không tự khởi động daemon. Xác định phiên bản Neovim/Herdr tối thiểu qua CLI và code attach thực tế khi lập kế hoạch.

### Start

1. Kiểm tra task, provider, liên kết hiện tại và thư mục repo.
2. Nếu task đã liên kết với agent còn sống, mở agent đó; không tạo bản sao.
3. Tạo host pane/tab Herdr tại repo root, không lấy pane đang focus của người dùng.
4. Start agent bằng argv, dùng ID từ response, không nội suy shell command.
5. Sau khi Herdr xác nhận thành công, lưu liên kết và chuyển Doing.
6. Nếu lỗi trước thành công, giữ task state cũ và chỉ dọn tài nguyên rỗng do thao tác này tạo.

Nếu agent đã chạy nhưng lưu JSON thất bại, báo định danh agent để có thể liên kết lại; không âm thầm dừng agent hoặc báo task đã lưu.

### Liên kết agent có sẵn

Chọn từ agent Herdr đang chạy, hiển thị provider, cwd, state và định danh. Một runtime session chỉ được gắn với một task trong các repo đăng ký. Phiên đã liên kết ghi rõ và không cho gắn thêm. MVP không tự chuyển liên kết khỏi task khác. Thao tác này chỉ lưu liên kết, không tự chuyển cột vì quy tắc tự Doing chỉ áp dụng start thành công.

Giới hạn: registry không biết board chưa đăng ký; bảo đảm không trùng áp dụng trong phạm vi board đã đăng ký. Cần serialize thao tác link/start giữa các instance bằng khóa registry để không cùng nhận một phiên.

### Open, hide, send và stop

- `<CR>` kiểm tra đúng liên kết rồi attach vào pane hiện tại; float reuse terminal buffer khi còn hợp lệ.
- Hide chỉ đóng cửa sổ float, giữ buffer/job attach nếu còn sống. Reopen reattach khi attach client đã kết thúc.
- Phiên đã mất hiện offline và đề nghị start phiên mới. Không tự start hoặc tự resume conversation cũ.
- Send dùng lệnh prompt của Herdr, kiểm tra identity và lỗi runtime.
- Stop yêu cầu xác nhận, chỉ tác động đúng agent liên kết; task giữ cột hiện tại.
- Rename task không rename runtime identity. Xóa task không stop agent.
- Khi quit Neovim, chỉ attach client kết thúc; Herdr tiếp tục sở hữu agent.

Status được đọc khi mở/refresh và polling nhẹ chỉ khi board đang hiển thị. Có một truy vấn danh sách agent cho mỗi đợt refresh; không một process cho mỗi card. UI update trên main loop Neovim. Không suy trạng thái task từ trạng thái agent, không coi `unknown` là hoàn thành.

## Public Lua API

API dùng tham chiếu task rõ repo để không phụ thuộc cwd lúc gọi, ví dụ `{ repo = '/absolute/repo', id = 'task-id' }`.

```lua
board.list_tasks({ scope = 'repo', repo = repo_root })
board.list_tasks({ scope = 'global' })
board.get_task(ref)
board.create_task({ repo = repo_root, title = title, status = 'todo' })
board.update_task(ref, { title = title })
board.move_task(ref, 'doing')
board.delete_task(ref)
board.start_agent(ref, { provider = 'codex' })
board.bind_agent(ref, runtime_identity)
board.open_agent(ref)
board.hide_agent(ref)
board.send(ref, message)
board.stop_agent(ref)
board.focus_board({ scope = 'global' })
```

API validate input, trả kết quả/lỗi rõ ràng; thao tác runtime là async để không chặn Neovim. UI lo prompt/xác nhận; API không tự mở hộp thoại. `update_task` không cho ghi tùy ý runtime identity hoặc bypass quy tắc liên kết. MCP/RPC bridge và event subscription để sau; không cung cấp eval Lua tùy ý.

## Tiêu chí kiểm chứng

- CRUD và reload giữ đúng ID, cột, title, liên kết và thứ tự.
- Repo view chỉ hiện task repo; global sửa đúng file nguồn và tạo task đúng repo được chọn.
- Start thành công mới chuyển Doing; start thất bại giữ dữ liệu cũ.
- Bind dùng phiên có sẵn, không spawn; chặn phiên đã gắn task khác.
- Hide/open và quit/reopen Neovim không dừng agent; attach trở lại đúng phiên.
- Agent mất → offline; mất kết nối → lỗi runtime, không xóa liên kết.
- JSON hỏng không ghi đè; hai Neovim sửa cùng board không mất cập nhật; lỗi save sau start vẫn chỉ ra agent đã chạy.
- Delete task không stop agent; stop không đổi task status.
- Chạy luồng start → attach → send → hide → reopen với từng provider đã cài. Provider chưa có phải ghi rõ chưa kiểm chứng.

Kiểm tra logic bằng headless Neovim tối thiểu cho storage và lifecycle với phản hồi CLI kiểm soát được; kiểm chứng attach/input/survival bằng Herdr thực. Mock không thay thế bằng chứng terminal/runtime.

## Ngoài MVP

Lịch sử hoặc nhiều session cho mỗi task; Sidekick; MCP/Pi bridge; RPC server; external event subscriptions; SQLite; tags/search/filter; parent-child task; tự quản lý Git worktree/branch; Herdr remote. Không fork toàn bộ Kanban plugin.

## Trạng thái và bước tiếp theo

Thiết kế và implementation plan đã được người dùng duyệt; execution được chọn là Native trên `master`. Workspace có Git local, chưa có baseline commit lúc ghi nội dung này. Chưa viết product code, chưa chạy kiểm chứng runtime.
