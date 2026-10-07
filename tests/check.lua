package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path

local ok, storage = pcall(require, 'agent-board.storage')
assert(ok, 'agent-board.storage is missing')

local function eq(actual, expected, message)
  assert(vim.deep_equal(actual, expected), message or ('values differ: ' .. vim.inspect(actual)))
end

local root = vim.fn.tempname() .. '-agent-board'
assert(vim.fn.mkdir(root, 'p') == 1)

local function write(path, value)
  local file = assert(io.open(path, 'wb'))
  assert(file:write(value))
  assert(file:close())
end

local function read_bytes(path)
  local file = assert(io.open(path, 'rb'))
  local value = assert(file:read('*a'))
  assert(file:close())
  return value
end

local function task(title)
  return {
    id = 'task-1',
    title = title,
    status = 'todo',
    agent = {
      provider = 'codex',
      runtime = 'herdr',
      server = 'server-a',
      pane_id = 'w1:p1',
      name = 'codex_2',
      session_id = vim.NIL,
    },
  }
end

local board_path = root .. '/.agent-board.json'
local missing, missing_snapshot = storage.read(board_path, 'board')
eq(missing, { version = 1, revision = 0, tasks = {} }, 'missing board defaults')
assert(missing_snapshot.data == nil, 'missing file snapshot must be distinguishable')

local board = { version = 1, revision = 1, tasks = { task('Sửa lỗi đăng nhập 🔐') } }
write(board_path, vim.json.encode(board))
local loaded, snapshot = storage.read(board_path, 'board')
eq(loaded, board, 'valid Unicode and null round-trip')
assert(type(snapshot.data) == 'string', 'existing snapshot must preserve raw bytes')

local registry_path = root .. '/agent-board/repos.json'
local empty_registry = storage.read(registry_path, 'registry')
eq(empty_registry, { version = 1, revision = 0, repos = {} }, 'missing registry defaults')

local invalid_documents = {
  { version = 1, revision = 1, tasks = { task('first'), task('duplicate') } },
  { version = 1, revision = 1, tasks = { { id = 'task-1', title = 'bad status', status = 'blocked', agent = vim.NIL } } },
  { version = 1, revision = 1, tasks = { { id = 'task-2', title = 'bad provider', status = 'todo', agent = {
    provider = 'unknown', runtime = 'herdr', server = 'server-a', pane_id = 'w1:p2', name = 'unknown_2', session_id = vim.NIL,
  } } } },
}
for _, invalid in ipairs(invalid_documents) do
  write(board_path, vim.json.encode(invalid))
  local value, err = storage.read(board_path, 'board')
  assert(value == nil and err, 'invalid board must be rejected')
end

write(board_path, '{broken json')
local malformed, malformed_err = storage.read(board_path, 'board')
assert(malformed == nil and malformed_err, 'malformed JSON must be rejected')
write(board_path, vim.json.encode({ version = 2, revision = 1, tasks = {} }))
local unsupported, unsupported_err = storage.read(board_path, 'board')
assert(unsupported == nil and unsupported_err, 'unsupported version must be rejected')

write(board_path, vim.json.encode(board))
local current, current_snapshot = storage.read(board_path, 'board')
local release = assert(storage.lock(board_path))
local second_lock, lock_err = storage.lock(board_path)
assert(second_lock == nil and lock_err, 'second writer must not acquire the lock')

current.tasks[1].title = 'renamed'
current.revision = current.revision + 1
local next_snapshot = assert(storage.write_locked(board_path, current, current_snapshot))
release()
eq(storage.read(board_path, 'board'), current, 'successful write is visible')
assert(next_snapshot.revision == 2, 'write increments document revision')

local stale = { version = 1, revision = 2, tasks = { task('stale write') } }
local bytes_before = read_bytes(board_path)
local release_stale = assert(storage.lock(board_path))
local stale_result, stale_err = storage.write_locked(board_path, stale, current_snapshot)
assert(stale_result == nil and stale_err, 'stale snapshot must be rejected')
eq(read_bytes(board_path), bytes_before, 'stale write must preserve current bytes')
release_stale()

local latest, latest_snapshot = storage.read(board_path, 'board')
local release_invalid = assert(storage.lock(board_path))
latest.revision = -1
local invalid_write, invalid_write_err = storage.write_locked(board_path, latest, latest_snapshot)
assert(invalid_write == nil and invalid_write_err, 'invalid write must fail')
eq(read_bytes(board_path), bytes_before, 'failed write must preserve current bytes')
release_invalid()
local release_after_error = assert(storage.lock(board_path))
release_after_error()

local registry = storage.registry_path()
assert(registry:match('agent%-board[/\\]repos%.json$'), 'registry path must be under agent-board')

vim.fn.delete(root, 'rf')
print('agent-board checks passed')
