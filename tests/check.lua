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

local sessionless_identity = {
  provider = 'codex', runtime = 'herdr', server = expected_server,
  terminal_id = 'term_1234', pane_id = 'w1:p1',
}
local sessionless_requests = #requests
responses[#responses + 1] = result({ type = 'agent_info', agent = agent_info({
  terminal_id = 'term_1234', pane_id = 'w1:p1', name = vim.NIL, agent_session = vim.NIL,
}) })
local sessionless, sessionless_error = await(function(cb) herdr.resolve(sessionless_identity, cb) end)
assert(sessionless == nil and sessionless_error.code == 'identity_unverifiable', 'sessionless identity cannot verify an agent occupant')
eq(#requests, sessionless_requests, 'sessionless identity is rejected before querying Herdr')
local sessionless_argv, sessionless_attach_error = herdr.attach_argv(sessionless_identity)
assert(sessionless_argv == nil and sessionless_attach_error.code == 'identity_unverifiable', 'sessionless identity cannot attach')
table.remove(responses, #responses)

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

local no_session_start_info = agent_info({
  terminal_id = 'term_no_session', name = 'ab-no-session', workspace_id = 'w-agent',
  tab_id = 'w-agent:t-no-session', pane_id = 'w-agent:p-no-session', agent_session = vim.NIL,
})
responses[#responses + 1] = result({ type = 'workspace_list', workspaces = { { workspace_id = 'w-agent', label = 'agent-board.nvim' } } })
responses[#responses + 1] = result({ type = 'tab_created', tab = { tab_id = 'w-agent:t-no-session' }, root_pane = { pane_id = 'w-agent:p-no-session' } })
responses[#responses + 1] = result({ type = 'agent_started', agent = no_session_start_info, argv = { 'codex' } })
local no_session_start, no_session_start_error = await(function(cb) herdr.start(start_repo, 'codex', 'ab-no-session', cb) end)
assert(no_session_start == nil and no_session_start_error.code == 'identity_unverifiable', 'start cannot persist an agent without provider session identity')
eq(no_session_start_error.agent.terminal_id, 'term_no_session', 'sessionless start failure returns the started agent identity')
eq(no_session_start_error.host.pane_id, 'w-agent:p-no-session', 'sessionless start failure returns the created host')

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

local function check_lifecycle_and_board()
local api = require('agent-board')
for _, name in ipairs({ 'start_agent', 'bind_agent', 'open_agent', 'hide_agent', 'send', 'stop_agent' }) do
  assert(type(api[name]) == 'function', 'public lifecycle API is missing: ' .. name)
end

local terminal = require('agent-board.terminal')
assert(type(terminal.open) == 'function' and type(terminal.hide) == 'function' and type(terminal.is_open) == 'function', 'terminal API is missing')

local task4_registry_path = root .. '/task4-data/agent-board/repos.json'
storage.registry_path = function() return task4_registry_path end
local task4_repo_a = git_init(root .. '/task4-repo-a')
local task4_repo_b = git_init(root .. '/task4-repo-b')
local function make_task(repo, title)
  return assert(tasks.create_task({ repo = repo, title = title }))
end
local bind_task = make_task(task4_repo_a, 'Bind target')
local duplicate_task = make_task(task4_repo_b, 'Duplicate target')
local failed_start_task = make_task(task4_repo_a, 'Failed start')
local started_task = make_task(task4_repo_a, 'Started task')
local save_failed_task = make_task(task4_repo_a, 'Save failure')
local stop_task = make_task(task4_repo_a, 'Stop target')
local rename_task = make_task(task4_repo_a, 'Rename target')
local delete_task = make_task(task4_repo_a, 'Delete target')
local concurrent_a = make_task(task4_repo_a, 'Concurrent A')
local concurrent_b = make_task(task4_repo_a, 'Concurrent B')

vim.env.HERDR_SOCKET_PATH = root .. '/task4.sock'
local task4_server = 'socket:' .. root .. '/task4.sock'
local previous_runtime = {
  resolve = herdr.resolve,
  start = herdr.start,
  send = herdr.send,
  stop = herdr.stop,
}
local live_agents, starts, sends, stops, start_failure = {}, 0, 0, 0, nil
local hold_pane, held_resolve

local function identity_for(terminal_id, pane_id, name, session_id)
  return {
    provider = 'codex', runtime = 'herdr', server = task4_server,
    terminal_id = terminal_id, pane_id = pane_id, name = name,
    session_id = session_id or vim.NIL,
  }
end

local function live_for(identity)
  return { identity = vim.deepcopy(identity), cwd = task4_repo_a, state = 'working' }
end

herdr.resolve = function(identity, callback)
  if identity.pane_id == hold_pane then
    held_resolve = callback
    return
  end
  local live = live_agents[identity.pane_id]
  if not live then
    return callback(nil, { code = 'offline', message = 'offline' })
  end
  callback(live)
end

herdr.start = function(repo, provider, name, callback)
  starts = starts + 1
  if start_failure then
    return callback(nil, vim.deepcopy(start_failure))
  end
  local identity = identity_for('term-start-' .. starts, 'task4:p' .. starts, name, 'session-start-' .. starts)
  identity.provider = provider
  local live = { identity = identity, cwd = repo, state = 'idle' }
  live_agents[identity.pane_id] = live
  callback({ identity = vim.deepcopy(identity), host = { workspace_id = 'task4-w', tab_id = 'task4-t', pane_id = identity.pane_id } })
end

herdr.send = function(_, _, callback)
  sends = sends + 1
  callback(true)
end

herdr.stop = function(identity, callback)
  stops = stops + 1
  callback(true)
end

local bind_identity = identity_for('term-bound', 'task4:bound', 'existing-agent', 'session-bound')
live_agents[bind_identity.pane_id] = live_for(bind_identity)
local bound, bind_error = await(function(callback) api.bind_agent({ repo = task4_repo_a, id = bind_task.id }, bind_identity, callback) end)
assert(bound and not bind_error, 'binding a live agent should succeed')
eq(bound.status, 'todo', 'binding does not move the task')
eq(bound.agent.terminal_id, bind_identity.terminal_id, 'binding persists verified identity')

local stale_identity = vim.deepcopy(bind_identity)
stale_identity.session_id = 'replaced-session'
local sends_before_stale_identity = sends
local stale_send, stale_send_error = await(function(callback)
  api.send({ repo = task4_repo_a, id = bind_task.id }, 'must not be sent', stale_identity, callback)
end)
assert(stale_send == nil and stale_send_error.code == 'conflict', 'send refuses a task whose current link differs from the selected identity')
eq(sends, sends_before_stale_identity, 'stale send does not reach Herdr')

local live_replacement_identity = identity_for('term-live-replacement', 'task4:live-replacement', 'replacement-agent', 'session-replacement')
live_agents[live_replacement_identity.pane_id] = live_for(live_replacement_identity)
local live_rebind, live_rebind_error = await(function(callback)
  api.bind_agent({ repo = task4_repo_a, id = bind_task.id }, live_replacement_identity, callback)
end)
assert(live_rebind == nil and live_rebind_error.code == 'already_linked', 'a live link cannot be replaced through bind')
eq(tasks.get_task({ repo = task4_repo_a, id = bind_task.id }).agent.terminal_id, bind_identity.terminal_id, 'rejected live rebind preserves its link')

local duplicate, duplicate_error = await(function(callback)
  api.bind_agent({ repo = task4_repo_b, id = duplicate_task.id }, bind_identity, callback)
end)
assert(duplicate == nil and duplicate_error and duplicate_error.code == 'already_bound', 'agent already linked on another repo is rejected')

start_failure = { code = 'start_failed', message = 'provider is not installed' }
local failed_start, failed_start_error = await(function(callback)
  api.start_agent({ repo = task4_repo_a, id = failed_start_task.id }, { provider = 'codex' }, callback)
end)
assert(failed_start == nil and failed_start_error, 'failed Herdr start reports an error')
eq(tasks.get_task({ repo = task4_repo_a, id = failed_start_task.id }).status, 'todo', 'failed start leaves status unchanged')
eq(tasks.get_task({ repo = task4_repo_a, id = failed_start_task.id }).agent, vim.NIL, 'failed start leaves link empty')

start_failure = nil
local start_count_before = starts
local started_task_value, started_error = await(function(callback)
  api.start_agent({ repo = task4_repo_a, id = started_task.id }, { provider = 'codex' }, callback)
end)
assert(started_task_value and not started_error)
eq(started_task_value.status, 'doing', 'successful start and Doing status are saved together')
assert(started_task_value.agent.terminal_id and starts == start_count_before + 1, 'successful start persists returned terminal identity')

local opened_existing = 0
local original_terminal_open = terminal.open
terminal.open = function(_, identity)
  opened_existing = opened_existing + 1
  eq(identity.terminal_id, started_task_value.agent.terminal_id, 'existing start opens the linked agent')
  return true
end
local existing_start_count = starts
local existing_task, existing_error = await(function(callback)
  api.start_agent({ repo = task4_repo_a, id = started_task.id }, { provider = 'codex' }, callback)
end)
assert(existing_task and not existing_error and existing_task.existing, 'starting an already-live task reuses its agent')
eq(starts, existing_start_count, 'an already-live link does not spawn another agent')
eq(opened_existing, 1, 'an already-live link opens its existing terminal')
terminal.open = original_terminal_open

local offline_identity = identity_for('term-offline-save-failure', 'task4:offline-save-failure', 'old-agent', 'session-old')
live_agents[offline_identity.pane_id] = live_for(offline_identity)
assert(await(function(callback)
  api.bind_agent({ repo = task4_repo_a, id = save_failed_task.id }, offline_identity, callback)
end))
live_agents[offline_identity.pane_id] = nil

local saved_write_locked = storage.write_locked
storage.write_locked = function(path, document, snapshot)
  if path == task4_repo_a .. '/.agent-board.json' then
    return nil, 'simulated disk failure'
  end
  return saved_write_locked(path, document, snapshot)
end
local stops_before_save_failure = stops
local save_failed, save_error = await(function(callback)
  api.start_agent({ repo = task4_repo_a, id = save_failed_task.id }, { provider = 'codex' }, callback)
end)
storage.write_locked = saved_write_locked
assert(save_failed == nil and save_error and save_error.agent and save_error.agent.terminal_id, 'save failure returns the started agent identity')
eq(stops, stops_before_save_failure, 'save failure never stops a started agent')
eq(tasks.get_task({ repo = task4_repo_a, id = save_failed_task.id }).status, 'todo', 'save failure does not claim Doing was persisted')
eq(tasks.get_task({ repo = task4_repo_a, id = save_failed_task.id }).agent.terminal_id, offline_identity.terminal_id, 'save failure preserves the previously persisted offline link')
local recovered, recovery_error = await(function(callback)
  api.bind_agent({ repo = task4_repo_a, id = save_failed_task.id }, save_error.agent, callback)
end)
assert(recovered and not recovery_error, 'a verified running replacement can recover a failed replacement save')
eq(recovered.agent.terminal_id, save_error.agent.terminal_id, 'recovery links the new running agent')

local stop_identity = identity_for('term-stop', 'task4:stop', 'stop-agent', 'session-stop')
live_agents[stop_identity.pane_id] = live_for(stop_identity)
local stop_target = await(function(callback)
  api.bind_agent({ repo = task4_repo_a, id = stop_task.id }, stop_identity, callback)
end)
assert(stop_target)
local stale_stop_identity = vim.deepcopy(stop_identity)
stale_stop_identity.session_id = 'replaced-session'
local stops_before_stale_identity = stops
local stale_stop, stale_stop_error = await(function(callback)
  api.stop_agent({ repo = task4_repo_a, id = stop_task.id }, stale_stop_identity, callback)
end)
assert(stale_stop == nil and stale_stop_error.code == 'conflict', 'stop refuses a task whose current link differs from the confirmed identity')
eq(stops, stops_before_stale_identity, 'stale stop does not reach Herdr')
local stopped, stop_error = await(function(callback) api.stop_agent({ repo = task4_repo_a, id = stop_task.id }, callback) end)
assert(stopped and not stop_error)
eq(stops, stops_before_save_failure + 1, 'stop calls Herdr once')
local stopped_task = tasks.get_task({ repo = task4_repo_a, id = stop_task.id })
eq(stopped_task.status, 'todo', 'stopping an agent leaves its task status unchanged')
eq(stopped_task.agent.terminal_id, stop_identity.terminal_id, 'stop preserves the task link')

local rename_identity = identity_for('term-rename', 'task4:rename', 'rename-agent', 'session-rename')
local delete_identity = identity_for('term-delete', 'task4:delete', 'delete-agent', 'session-delete')
live_agents[rename_identity.pane_id] = live_for(rename_identity)
live_agents[delete_identity.pane_id] = live_for(delete_identity)
assert(await(function(callback) api.bind_agent({ repo = task4_repo_a, id = rename_task.id }, rename_identity, callback) end))
assert(await(function(callback) api.bind_agent({ repo = task4_repo_a, id = delete_task.id }, delete_identity, callback) end))
assert(api.update_task({ repo = task4_repo_a, id = rename_task.id }, { title = 'Renamed task' }))
assert(api.move_task({ repo = task4_repo_a, id = rename_task.id }, 'done'))
assert(api.delete_task({ repo = task4_repo_a, id = delete_task.id }))
eq(stops, stops_before_save_failure + 1, 'rename, Done, and delete do not stop agents')

local concurrent_identity = identity_for('term-concurrent', 'task4:concurrent', 'concurrent-agent', 'session-concurrent')
local concurrent_live = live_for(concurrent_identity)
live_agents[concurrent_identity.pane_id] = concurrent_live
hold_pane = concurrent_identity.pane_id
local first_bind_calls, first_bind_value, first_bind_error = 0, nil, nil
api.bind_agent({ repo = task4_repo_a, id = concurrent_a.id }, concurrent_identity, function(value, err)
  first_bind_calls = first_bind_calls + 1
  first_bind_value, first_bind_error = value, err
end)
assert(held_resolve, 'first bind keeps the coordinator lock while Herdr verifies identity')
local second_bind, second_bind_error = await(function(callback)
  api.bind_agent({ repo = task4_repo_a, id = concurrent_b.id }, concurrent_identity, callback)
end)
assert(second_bind == nil and second_bind_error, 'concurrent bind cannot pass the held coordinator lock')
held_resolve(concurrent_live)
hold_pane = nil
assert(vim.wait(1000, function() return first_bind_calls > 0 end, 5), 'first bind callback timed out')
eq(first_bind_calls, 1, 'first concurrent bind callback runs once')
assert(first_bind_value and not first_bind_error)

local missing_registered = git_init(root .. '/task4-missing-registered')
assert(tasks.register_repo(missing_registered))
assert(vim.fn.delete(missing_registered, 'rf') == 0)
local missing_identity = identity_for('term-missing', 'task4:missing')
live_agents[missing_identity.pane_id] = live_for(missing_identity)
local failed_closed, missing_error = await(function(callback)
  api.bind_agent({ repo = task4_repo_a, id = concurrent_b.id }, missing_identity, callback)
end)
assert(failed_closed == nil and missing_error and missing_error.code == 'board_unavailable', 'missing registered repo fails closed during uniqueness scan')

local task4_registry, task4_registry_snapshot = storage.read(task4_registry_path, 'registry')
local registry_release = assert(storage.lock(task4_registry_path))
for index, repo in ipairs(task4_registry.repos) do
  if repo == missing_registered then
    table.remove(task4_registry.repos, index)
    break
  end
end
task4_registry.revision = task4_registry.revision + 1
assert(storage.write_locked(task4_registry_path, task4_registry, task4_registry_snapshot))
registry_release()

local corrupt_registered = git_init(root .. '/task4-corrupt-registered')
assert(tasks.register_repo(corrupt_registered))
write(corrupt_registered .. '/.agent-board.json', '{broken json')
local corrupt_identity = identity_for('term-corrupt', 'task4:corrupt')
live_agents[corrupt_identity.pane_id] = live_for(corrupt_identity)
local corrupt_board_path = corrupt_registered .. '/.agent-board.json'
local corrupt_bytes = read_bytes(corrupt_board_path)
local failed_closed_corrupt, corrupt_error = await(function(callback)
  api.bind_agent({ repo = task4_repo_a, id = concurrent_b.id }, corrupt_identity, callback)
end)
assert(failed_closed_corrupt == nil and corrupt_error and corrupt_error.code == 'board_unavailable', 'corrupt registered repo fails closed during uniqueness scan')
eq(read_bytes(corrupt_board_path), corrupt_bytes, 'failed binding leaves corrupt board bytes untouched')

local fake_jobs, running_jobs, spawn_count, spawn_exits, local_stops = {}, {}, 0, {}, 0
terminal.spawn_term = function(argv, on_exit)
  spawn_count = spawn_count + 1
  local job = spawn_count
  fake_jobs[job] = vim.deepcopy(argv)
  running_jobs[job] = true
  spawn_exits[job] = on_exit
  return job
end
terminal.job_running = function(job) return running_jobs[job] == true end
terminal.stop_term = function(job)
  local_stops = local_stops + 1
  running_jobs[job] = false
end
local terminal_key = 'task4-terminal-key'
local first_terminal_identity = identity_for('term-terminal-1', 'task4:terminal-1', 'terminal-one', 'session-one')
local first_entry = assert(terminal.open(terminal_key, first_terminal_identity))
eq(fake_jobs[1], { 'herdr', 'agent', 'attach', first_terminal_identity.pane_id }, 'terminal attaches using argv')
local normal_maps = vim.api.nvim_buf_get_keymap(first_entry.buf, 'n')
local has_hide_key = false
for _, map in ipairs(normal_maps) do
  if map.lhs == 'q' then has_hide_key = true end
end
assert(has_hide_key, 'terminal buffer has a local q hide mapping')
terminal.hide(terminal_key)
assert(vim.api.nvim_buf_is_valid(first_entry.buf) and running_jobs[first_entry.job], 'hide keeps the attach buffer and job alive')
local reopened_entry = assert(terminal.open(terminal_key, first_terminal_identity))
eq(reopened_entry.buf, first_entry.buf, 'reopen reuses the live attach buffer')
eq(spawn_count, 1, 'reopening a live attach does not spawn a second client')

running_jobs[first_entry.job] = false
spawn_exits[first_entry.job](first_entry.job, 0, 'exit')
assert(vim.wait(1000, function() return not terminal.is_open(terminal_key) end, 5), 'attach exit cleans the terminal registry')
local after_exit_entry = assert(terminal.open(terminal_key, first_terminal_identity))
eq(spawn_count, 2, 'reopen after attach exit starts a new client')

local replacement_identity = identity_for('term-terminal-2', 'task4:terminal-2', 'terminal-two', 'session-two')
local stopped_before_replace = stops
local replacement_entry = assert(terminal.open(terminal_key, replacement_identity))
eq(spawn_count, 3, 'identity replacement does not reuse an old attach client')
running_jobs[after_exit_entry.job] = false
spawn_exits[after_exit_entry.job](after_exit_entry.job, 0, 'exit')
vim.wait(20)
assert(terminal.is_open(terminal_key) and vim.api.nvim_buf_is_valid(replacement_entry.buf), 'stale exit callback does not clean the replacement client')
eq(stops, stopped_before_replace, 'terminal client replacement does not stop the Herdr agent')
eq(local_stops, 1, 'replacement stops only the old local attach client')
terminal.hide(terminal_key)
running_jobs[replacement_entry.job] = false
spawn_exits[replacement_entry.job](replacement_entry.job, 0, 'exit')
vim.wait(20)

local board = require('agent-board.board')
assert(type(board.open) == 'function' and type(board.close) == 'function' and type(board.refresh) == 'function', 'board UI API is missing')
assert(type(api.focus_board) == 'function', 'public focus_board API is missing')

herdr.resolve = previous_runtime.resolve
herdr.start = previous_runtime.start
herdr.send = previous_runtime.send
herdr.stop = previous_runtime.stop
vim.env.HERDR_SOCKET_PATH = previous_socket
end

check_lifecycle_and_board()

vim.fn.delete(root, 'rf')
print('agent-board checks passed')
