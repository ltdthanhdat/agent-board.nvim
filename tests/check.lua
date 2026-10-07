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
      terminal_id = 'term_1234',
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

local missing_terminal_id = vim.deepcopy(board)
missing_terminal_id.tasks[1].agent.terminal_id = nil
write(board_path, vim.json.encode(missing_terminal_id))
local unsafe_identity = storage.read(board_path, 'board')
assert(unsafe_identity == nil, 'linked agent without terminal_id must be rejected')
write(board_path, vim.json.encode(board))

local unnamed_agent = vim.deepcopy(board)
unnamed_agent.tasks[1].agent.name = vim.NIL
write(board_path, vim.json.encode(unnamed_agent))
assert(storage.read(board_path, 'board'), 'unnamed Herdr agent can be stored by pane identity')
write(board_path, vim.json.encode(board))

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

local herdr_ok, herdr = pcall(require, 'agent-board.herdr')
assert(herdr_ok, 'agent-board.herdr is missing')
local previous_socket = vim.env.HERDR_SOCKET_PATH
vim.env.HERDR_SOCKET_PATH = root .. '/test.sock'
local expected_server = 'socket:' .. root .. '/test.sock'
local requests, responses, repeat_response = {}, {}, false
herdr.run = function(argv, timeout_ms, callback)
  requests[#requests + 1] = vim.deepcopy(argv)
  assert(timeout_ms > 0, 'runtime commands have a bounded timeout')
  local response = table.remove(responses, 1)
  assert(response, 'a fake Herdr response is required')
  callback(response)
  if repeat_response then
    callback(response)
  end
end

local function result(value)
  return { code = 0, stdout = vim.json.encode({ result = value }), stderr = '' }
end

local function failed(code, message)
  return { code = code, stdout = '', stderr = vim.json.encode({ error = { code = code, message = message } }) }
end

local function agent_info(overrides)
  local info = {
    terminal_id = 'term_1234', name = 'codex_2', agent = 'codex', agent_status = 'working',
    state_labels = {}, tokens = {}, workspace_id = 'w1', tab_id = 'w1:t1', pane_id = 'w1:p1',
    focused = false, launch_pending = false, interactive_ready = true, state_change_seq = 8,
    cwd = '/repo', revision = 1,
    agent_session = { source = 'herdr:codex', agent = 'codex', kind = 'id', value = 'session-1' },
  }
  for key, value in pairs(overrides or {}) do
    info[key] = value
  end
  return info
end

local function await(start)
  local calls, value, err = 0, nil, nil
  start(function(result_value, result_error)
    calls = calls + 1
    value, err = result_value, result_error
  end)
  assert(vim.wait(1000, function() return calls > 0 end, 5), 'async callback timed out')
  vim.wait(20)
  eq(calls, 1, 'async callback runs once')
  return value, err
end

responses[#responses + 1] = result({ type = 'agent_list', agents = {
  agent_info(), agent_info({ name = vim.NIL, terminal_id = 'term_unnamed', pane_id = 'w1:p2' }),
} })
local listed, list_error = await(herdr.list)
assert(not list_error)
eq(#listed, 2, 'named and unnamed supported agents are bindable')
eq(listed[1].identity.server, expected_server, 'agent records the current server route')
eq(listed[1].identity.terminal_id, 'term_1234', 'agent uses Herdr terminal identity')
eq(listed[1].identity.session_id, 'session-1', 'agent records provider session identity when present')
eq(listed[2].identity.name, nil, 'unnamed agent remains addressable by pane')

repeat_response = true
responses[#responses + 1] = result({ type = 'agent_list', agents = {} })
local no_agents = await(herdr.list)
repeat_response = false
eq(no_agents, {}, 'an empty successful agent list is not an offline error')

responses[#responses + 1] = { code = 0, stdout = 'null', stderr = '' }
local malformed_list, malformed_list_error = await(herdr.list)
assert(malformed_list == nil and malformed_list_error.code == 'runtime_unavailable', 'null response is not an empty live list')

local identity = {
  provider = 'codex', runtime = 'herdr', server = expected_server, terminal_id = 'term_1234',
  pane_id = 'w1:p1', name = 'codex_2', session_id = 'session-1',
}
local request_count = #requests
local wrong_server = vim.tbl_extend('force', identity, { server = 'session:other' })
local wrong_server_result, wrong_server_error = await(function(cb) herdr.resolve(wrong_server, cb) end)
assert(wrong_server_result == nil and wrong_server_error.code == 'identity_mismatch', 'different Herdr route is rejected')
eq(#requests, request_count, 'route mismatch makes no CLI request')

responses[#responses + 1] = result({ type = 'agent_info', agent = agent_info({ terminal_id = 'term_replaced' }) })
local replaced, replaced_error = await(function(cb) herdr.resolve(identity, cb) end)
assert(replaced == nil and replaced_error.code == 'identity_mismatch', 'replacement terminal is rejected')

responses[#responses + 1] = result({ type = 'agent_info', agent = agent_info({ agent_session = vim.NIL }) })
local changed_session, changed_session_error = await(function(cb) herdr.resolve(identity, cb) end)
assert(changed_session == nil and changed_session_error.code == 'identity_mismatch', 'changed provider session is rejected')

responses[#responses + 1] = result({ type = 'agent_info', agent = agent_info() })
local resolved, resolve_error = await(function(cb) herdr.resolve(identity, cb) end)
assert(not resolve_error)
eq(resolved.identity.terminal_id, 'term_1234', 'resolve returns the verified terminal')
eq(resolved.state, 'working', 'resolve preserves Herdr state')
eq(resolved.cwd, '/repo', 'resolve returns the Herdr working directory')

responses[#responses + 1] = failed('agent_not_found', 'agent target not found')
local offline, offline_error = await(function(cb) herdr.resolve(identity, cb) end)
assert(offline == nil and offline_error.code == 'offline', 'missing agent is offline')
responses[#responses + 1] = failed('server_unavailable', 'server unavailable')
local unavailable, unavailable_error = await(function(cb) herdr.resolve(identity, cb) end)
assert(unavailable == nil and unavailable_error.code == 'runtime_unavailable', 'server error is not reported offline')
responses[#responses + 1] = { code = 124, stdout = '', stderr = '' }
local timed_out, timeout_error = await(herdr.list)
assert(timed_out == nil and timeout_error.code == 'runtime_unavailable', 'CLI timeout is a runtime error')

local message = 'Run `echo $(literal)`; keep $HOME unchanged'
responses[#responses + 1] = result({ type = 'agent_info', agent = agent_info() })
responses[#responses + 1] = result({ type = 'agent_prompted', agent = agent_info() })
local sent, send_error = await(function(cb) herdr.send(identity, message, cb) end)
assert(sent and not send_error)
eq(requests[#requests], { 'agent', 'prompt', 'w1:p1', message }, 'prompt uses argv and does not wait for the turn')

eq(herdr.attach_argv(identity), { 'herdr', 'agent', 'attach', 'w1:p1' }, 'attach targets the exact pane')
responses[#responses + 1] = result({ type = 'agent_info', agent = agent_info() })
responses[#responses + 1] = result({ type = 'pane_closed' })
local stopped, stop_error = await(function(cb) herdr.stop(identity, cb) end)
assert(stopped and not stop_error)
eq(requests[#requests], { 'pane', 'close', 'w1:p1' }, 'stop closes only the verified agent pane')

local start_repo = root .. '/repo with $(literal)'
local started_info = agent_info({ terminal_id = 'term_started', name = 'ab-task', workspace_id = 'w-agent', tab_id = 'w-agent:t1', pane_id = 'w-agent:p1', cwd = start_repo })
responses[#responses + 1] = result({ type = 'workspace_list', workspaces = {} })
responses[#responses + 1] = result({ type = 'workspace_created', workspace = { workspace_id = 'w-agent' } })
responses[#responses + 1] = result({ type = 'tab_created', tab = { tab_id = 'w-agent:t1' }, root_pane = { pane_id = 'w-agent:p1' } })
responses[#responses + 1] = result({ type = 'agent_started', agent = started_info, argv = { 'codex' } })
local started, start_error = await(function(cb) herdr.start(start_repo, 'codex', 'ab-task', cb) end)
assert(started and not start_error)
eq(started.identity.terminal_id, 'term_started', 'start stores the terminal ID from Herdr')
eq(started.host, { workspace_id = 'w-agent', tab_id = 'w-agent:t1', pane_id = 'w-agent:p1' }, 'start returns created host IDs')
eq(requests[#requests - 3], { 'workspace', 'list' }, 'start checks the dedicated workspace')
eq(requests[#requests - 2], { 'workspace', 'create', '--no-focus', '--label', 'agent-board.nvim' }, 'start creates only its workspace')
eq(requests[#requests - 1], { 'tab', 'create', '--cwd', start_repo, '--no-focus', '--workspace', 'w-agent', '--label', 'ab-task' }, 'start preserves repo path in argv')
eq(requests[#requests], { 'agent', 'start', 'ab-task', '--kind', 'codex', '--pane', 'w-agent:p1', '--timeout', '30000' }, 'start uses returned pane ID')

local second_start_info = agent_info({ terminal_id = 'term_second', name = 'ab-second', workspace_id = 'w-agent', tab_id = 'w-agent:t2', pane_id = 'w-agent:p2' })
responses[#responses + 1] = result({ type = 'workspace_list', workspaces = { { workspace_id = 'w-agent', label = 'agent-board.nvim' } } })
responses[#responses + 1] = result({ type = 'tab_created', tab = { tab_id = 'w-agent:t2' }, root_pane = { pane_id = 'w-agent:p2' } })
responses[#responses + 1] = result({ type = 'agent_started', agent = second_start_info, argv = { 'codex' } })
local previous_request_count = #requests
local second_start = await(function(cb) herdr.start(start_repo, 'codex', 'ab-second', cb) end)
assert(second_start.identity.terminal_id == 'term_second')
eq(#requests, previous_request_count + 3, 'existing workspace skips workspace creation')
eq(requests[previous_request_count + 2], { 'tab', 'create', '--cwd', start_repo, '--no-focus', '--workspace', 'w-agent', '--label', 'ab-second' }, 'existing workspace starts in the owned workspace')

vim.env.HERDR_SOCKET_PATH = previous_socket

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
