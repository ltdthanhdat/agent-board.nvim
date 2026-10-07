package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path

local ok, storage = pcall(require, 'agent-board.storage')
assert(ok, 'agent-board.storage is missing')
local configured_registry_path = storage.registry_path()
assert(configured_registry_path:match('agent%-board[/\\]repos%.json$'), 'registry path must be under agent-board')

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

local tasks_ok, tasks = pcall(require, 'agent-board.tasks')
assert(tasks_ok, 'agent-board.tasks is missing')
storage.registry_path = function()
  return root .. '/isolated-data/agent-board/repos.json'
end

local function git_init(path)
  assert(vim.fn.mkdir(path, 'p') == 1)
  local result = vim.system({ 'git', 'init', '-q', '--initial-branch=main', path }):wait()
  assert(result.code == 0, result.stderr)
  return assert(vim.uv.fs_realpath(path))
end

local repo_a = git_init(root .. '/repo space 日本語')
local repo_b = git_init(root .. '/another-repo')
assert(vim.fn.mkdir(repo_a .. '/nested/work', 'p') == 1)
local resolved_repo, resolve_error = tasks.resolve_repo(repo_a .. '/nested/work')
eq(resolved_repo, repo_a, resolve_error)

local alias = root .. '/repo-alias'
assert(vim.uv.fs_symlink(repo_a, alias))
eq(tasks.register_repo(repo_a), repo_a, 'register first repo')
eq(tasks.register_repo(alias), repo_a, 'symlink registration canonicalizes path')
local isolated_registry = assert(storage.read(storage.registry_path(), 'registry'))
eq(isolated_registry.repos, { repo_a }, 'duplicate repo registration is idempotent')

local first = assert(tasks.create_task({ repo = repo_a, title = 'Same title' }))
local second = assert(tasks.create_task({ repo = repo_a, title = 'Same title' }))
assert(first.id ~= second.id, 'duplicate titles still have unique IDs')
local original_id = first.id
first = assert(tasks.update_task({ repo = repo_a, id = first.id }, { title = 'Renamed' }))
eq(first.id, original_id, 'rename preserves task ID')
assert(tasks.update_task({ repo = repo_a, id = first.id }, { status = 'doing' }) == nil, 'status cannot bypass move_task')
assert(tasks.update_task({ repo = repo_a, id = first.id }, { agent = {} }) == nil, 'agent cannot bypass link API')
first = assert(tasks.move_task({ repo = repo_a, id = first.id }, 'doing'))
eq(tasks.get_task({ repo = repo_a, id = first.id }), first, 'task reload preserves move and rename')
local third = assert(tasks.create_task({ repo = repo_b, title = 'Other repo' }))
assert(third.id ~= first.id and third.id ~= second.id, 'task IDs do not collide across boards')

local repo_tasks = assert(tasks.list_tasks({ scope = 'repo', repo = repo_a }))
eq(#repo_tasks, 2, 'repo scope includes only its cards')
local global_tasks, global_warnings, global_snapshots = tasks.list_tasks({ scope = 'global' })
eq(#global_tasks, 3, 'global scope aggregates registered boards')
eq(global_warnings, {}, 'healthy repos have no warnings')
local global_repos = {}
for _, row in ipairs(global_tasks) do
  global_repos[row.repo] = true
end
assert(global_repos[repo_a] and global_repos[repo_b], 'global rows identify their source repos')

local external, external_snapshot = storage.read(repo_a .. '/.agent-board.json', 'board')
external.revision = external.revision + 1
external.tasks[1].title = 'external change'
local release_external = assert(storage.lock(repo_a .. '/.agent-board.json'))
assert(storage.write_locked(repo_a .. '/.agent-board.json', external, external_snapshot))
release_external()
local stale_result, stale_error = tasks.move_task({ repo = repo_a, id = first.id }, 'done', global_snapshots[repo_a])
assert(stale_result == nil and stale_error:find('reload', 1, true), 'stale UI snapshot must require reload')
eq(tasks.get_task({ repo = repo_a, id = first.id }).title, 'external change', 'stale UI cannot overwrite external edits')

local missing_repo = git_init(root .. '/removed-repo')
assert(tasks.register_repo(missing_repo))
assert(vim.fn.delete(missing_repo, 'rf') == 0)
local surviving_tasks, missing_warnings = tasks.list_tasks({ scope = 'global' })
eq(#surviving_tasks, 3, 'unavailable repo does not hide healthy boards')
assert(#missing_warnings == 1 and missing_warnings[1].repo == missing_repo, 'unavailable repo is reported')

local broken_repo = git_init(root .. '/broken-repo')
assert(tasks.register_repo(broken_repo))
write(broken_repo .. '/.agent-board.json', '{broken json')
local hidden_broken, broken_error = tasks.list_tasks({ scope = 'global' })
assert(hidden_broken == nil and broken_error, 'corrupt registered board must not be silently skipped')

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

vim.fn.delete(root, 'rf')
print('agent-board checks passed')
