local project_root = vim.fn.getcwd()
package.path = project_root .. '/lua/?.lua;' .. project_root .. '/lua/?/init.lua;' .. package.path

local root = vim.fn.tempname() .. '-agent-board-resume'
assert(vim.fn.mkdir(root, 'p') == 1)
local repo = root .. '/repo'
assert(vim.fn.mkdir(repo, 'p') == 1)
assert(vim.system({ 'git', 'init', '-q', '--initial-branch=main', repo }):wait().code == 0)
repo = assert(vim.uv.fs_realpath(repo))
assert(vim.system({ 'git', '-c', 'user.name=Agent Board Fixture', '-c', 'user.email=fixture@example.com', '-C', repo,
  'commit', '--allow-empty', '-q', '-m', 'fixture' }):wait().code == 0)
local sibling_repo = root .. '/sibling-worktree'
assert(vim.system({ 'git', '-C', repo, 'worktree', 'add', '--detach', sibling_repo, 'HEAD' }):wait().code == 0)
sibling_repo = assert(vim.uv.fs_realpath(sibling_repo))

local storage = require('agent-board.storage')
local tasks = require('agent-board.tasks')
local api = require('agent-board')
storage.registry_path = function() return root .. '/registry.json' end
assert(tasks.register_repo(repo))
vim.env.CLAUDE_CONFIG_DIR = root .. '/claude'

local herdr = require('agent-board.herdr')
local terminal = require('agent-board.terminal')
local server, live_agents = herdr.server_key(), {}
local starts, opens, start_args = {}, {}, {}
local session_ids = {
  codex = '0199abcd-1234-7abc-8def-123456789abc',
  pi = '0199abcd-1234-7abc-8def-123456789abd',
}
local bind_session_ids = {
  codex = '0199abcd-1234-7abc-8def-123456789abe',
  pi = '0199abcd-1234-7abc-8def-123456789abf',
}
local function make_identity(provider, pane, session_id, name)
  return {
    provider = provider, runtime = 'herdr', server = server,
    terminal_id = 'term-' .. pane, pane_id = pane, name = name, session_id = session_id,
  }
end
herdr.list = function(callback)
  local rows = {}
  for _, value in pairs(live_agents) do rows[#rows + 1] = vim.deepcopy(value) end
  callback(rows)
end
herdr.resolve = function(identity, callback)
  local value = live_agents[identity.pane_id]
  if value then callback(vim.deepcopy(value)) else callback(nil, { code = 'offline', message = 'pane is offline' }) end
end
herdr.start = function(cwd, provider, name, callback, opts)
  local count = (starts[provider] or 0) + 1
  starts[provider] = count
  start_args[provider] = opts and vim.deepcopy(opts) or nil
  local session_id = opts and opts.expected_session_id or session_ids[provider]
  local identity = make_identity(provider, provider .. '-' .. count, session_id, name)
  local live = { identity = identity, cwd = cwd, state = 'idle' }
  live_agents[identity.pane_id] = live
  vim.schedule(function() callback({ identity = identity, host = { pane_id = identity.pane_id } }) end)
end
terminal.open = function(key, identity, opts)
  opens[#opens + 1] = { key = key, identity = vim.deepcopy(identity), opts = opts }
  return true
end

local function await(fn)
  local done, value, err = false, nil, nil
  fn(function(result, failure) value, err, done = result, failure, true end)
  assert(vim.wait(10000, function() return done end), 'callback timeout')
  return value, err
end

local function set_pending_start(ref)
  local path = ref.repo .. '/.agent-board.json'
  local document, snapshot = assert(storage.read(path, 'board'))
  for _, task in ipairs(document.tasks) do
    if task.id == ref.id then task.pending_start = true end
  end
  document.revision = document.revision + 1
  local release = assert(storage.lock(path))
  assert(storage.write_locked(path, document, snapshot))
  release()
end

for _, provider in ipairs({ 'codex', 'pi' }) do
  local task = assert(api.create_task({ repo = repo, title = provider .. ' mapped task' }))
  local ref = { repo = repo, id = task.id }
  local created = assert(await(function(callback) api.start_agent(ref, { provider = provider }, callback) end))
  local old_identity = vim.deepcopy(created.agent)
  local expected_id = old_identity.session_id
  assert(created.conversation and created.conversation.provider == provider, provider .. ' start stores a durable native session mapping')
  local history_dir, history_path
  if provider == 'codex' then
    vim.env.CODEX_HOME = root .. '/codex'
    history_dir = root .. '/codex/sessions/2026/10/08'
    assert(vim.fn.mkdir(history_dir, 'p') == 1)
    history_path = history_dir .. '/fixture.jsonl'
    local file = assert(io.open(history_path, 'w'))
    file:write(vim.json.encode({ type = 'session_meta', payload = { id = expected_id, cwd = repo, timestamp = '2026-10-08T00:00:00Z' } }), '\n')
    file:close()
  else
    vim.env.PI_CODING_AGENT_DIR = root .. '/pi'
    history_dir = root .. '/pi/sessions/--' .. repo:gsub('^/', ''):gsub('[/\\:]', '-') .. '--'
    assert(vim.fn.mkdir(history_dir, 'p') == 1)
    history_path = history_dir .. '/fixture_' .. expected_id .. '.jsonl'
    local file = assert(io.open(history_path, 'w'))
    file:write(vim.json.encode({ type = 'session', version = 3, id = expected_id, cwd = repo, timestamp = '2026-10-08T00:00:00Z' }), '\n')
    file:write(vim.json.encode({ type = 'session_info', name = 'Saved Pi fixture' }), '\n')
    file:close()
  end
  local bind_id = bind_session_ids[provider]
  if provider == 'codex' then
    local file = assert(io.open(history_dir .. '/fixture-bind.jsonl', 'w'))
    file:write(vim.json.encode({ type = 'session_meta', payload = { id = bind_id, cwd = repo, timestamp = '2026-10-08T00:00:00Z' } }), '\n')
    file:close()
  else
    local file = assert(io.open(history_dir .. '/fixture_' .. bind_id .. '.jsonl', 'w'))
    file:write(vim.json.encode({ type = 'session', version = 3, id = bind_id, cwd = repo, timestamp = '2026-10-08T00:00:00Z' }), '\n')
    file:close()
  end
  live_agents[old_identity.pane_id] = nil

  local resumed, resume_error = await(function(callback)
    api.open_agent(ref, old_identity, callback, { tabpage = vim.api.nvim_get_current_tabpage(), label = task.title })
  end)
  assert(resumed and not resume_error, provider .. ' offline session resumes: ' .. vim.inspect(resume_error))
  assert((starts[provider] or 0) == 2, provider .. ' resumes through the provider, not a new empty task')
  assert(resumed.identity.session_id == expected_id, provider .. ' preserves its exact native session ID')
  assert(api.get_task(ref).agent.session_id == expected_id, provider .. ' keeps the saved task mapping')
  assert(#opens == (provider == 'codex' and 1 or 3), provider .. ' opens the resumed session in the task float')
  local args = assert(start_args[provider], provider .. ' receives exact resume arguments')
  assert(args.expected_session_id == expected_id, provider .. ' verifies the resumed native ID')
  if provider == 'codex' then
    assert(vim.deep_equal(args.agent_args, { 'resume', expected_id }), 'Codex resumes the named UUID')
  else
  assert(vim.deep_equal(args.agent_args, { '--session', expected_id }), 'Pi opens the named saved session')
  end

  live_agents[resumed.identity.pane_id] = nil
  local bind_task = assert(api.create_task({ repo = repo, title = provider .. ' offline bind' }))
  local bind_ref = { repo = repo, id = bind_task.id }
  local discovery = assert(await(function(callback) api.list_sessions(bind_ref, callback) end))
  local saved
  for _, row in ipairs(discovery.sessions) do
    if row.conversation and row.conversation.provider == provider and row.conversation.session_id == bind_id then saved = row end
  end
  assert(saved and saved.state == 'offline', provider .. ' saved history appears for offline binding')
  local bound, bound_error = await(function(callback) api.bind_conversation(bind_ref, saved.conversation, callback) end)
  assert(bound, 'offline bind failed: ' .. vim.inspect(bound_error))
  assert(bound.conversation.provider == provider and bound.conversation.session_id == bind_id, provider .. ' binds the existing native session')
  assert(bound.agent == vim.NIL and (starts[provider] or 0) == 2, provider .. ' offline binding does not launch a runtime')

  local duplicate = assert(api.create_task({ repo = repo, title = provider .. ' duplicate binding' }))
  local duplicate_value, duplicate_error = await(function(callback)
    api.bind_conversation({ repo = repo, id = duplicate.id }, saved.conversation, callback)
  end)
  assert(not duplicate_value and duplicate_error.code == 'already_bound', provider .. ' session can belong to only one task')

  local opened_bound = assert(await(function(callback) api.open_agent(bind_ref, callback) end))
  assert(opened_bound.identity.session_id == bind_id and (starts[provider] or 0) == 3,
    provider .. ' bound offline task resumes the exact existing session')
end

-- A durable provider pending_start marker must block retry when Herdr lists no runtime.
live_agents = {}
vim.env.CODEX_HOME = root .. '/codex'
local pending_codex_id = '0199abcd-1234-7abc-8def-123456789ac4'
local codex_dir = root .. '/codex/sessions/2026/10/08'
assert(vim.fn.mkdir(codex_dir, 'p') == 1)
local pending_codex_file = assert(io.open(codex_dir .. '/fixture-pending.jsonl', 'w'))
pending_codex_file:write(vim.json.encode({ type = 'session_meta', payload = { id = pending_codex_id, cwd = repo, timestamp = '2026-10-08T00:00:00Z' } }), '\n')
pending_codex_file:close()
local pending_codex_task = assert(api.create_task({ repo = repo, title = 'Pending Codex start' }))
local pending_codex_ref = { repo = repo, id = pending_codex_task.id }
local pending_codex_bound, pending_codex_bind_error = await(function(callback)
  api.bind_conversation(pending_codex_ref, { provider = 'codex', session_id = pending_codex_id, cwd = repo }, callback)
end)
assert(pending_codex_bound, 'pending Codex fixture bind failed: ' .. vim.inspect(pending_codex_bind_error))
set_pending_start(pending_codex_ref)
local codex_starts_before_retry = starts.codex
local pending_codex_open, pending_codex_error = await(function(callback)
  api.open_agent(pending_codex_ref, callback)
end)
assert(not pending_codex_open and pending_codex_error.code == 'runtime_unknown',
  'a persisted pending provider start blocks retry when Herdr lists no runtime')
assert(starts.codex == codex_starts_before_retry and api.get_task(pending_codex_ref).pending_start,
  'refused provider retry neither starts a duplicate nor clears the uncertain reservation')
local pending_codex_live = make_identity('codex', 'codex-pending-recovered', pending_codex_id, 'ab-pending-codex')
live_agents[pending_codex_live.pane_id] = { identity = pending_codex_live, cwd = repo, state = 'idle' }
local recovered_codex = assert(await(function(callback) api.open_agent(pending_codex_ref, callback) end))
assert(recovered_codex.identity.session_id == pending_codex_id and starts.codex == codex_starts_before_retry,
  'an exact live provider identity recovers a pending start without launching again')
assert(not api.get_task(pending_codex_ref).pending_start, 'exact provider recovery clears pending_start')

-- A durable pending_start marker must block retry when no exact runtime is visible.
live_agents = {}
local claude_id = '0199abcd-1234-7abc-8def-123456789ac0'
local claude_dir = root .. '/claude/projects/fixture'
assert(vim.fn.mkdir(claude_dir, 'p') == 1)
local claude_file = assert(io.open(claude_dir .. '/' .. claude_id .. '.jsonl', 'w'))
claude_file:write(vim.json.encode({ type = 'user', sessionId = claude_id, cwd = repo, timestamp = '2026-10-08T00:00:00Z' }), '\n')
claude_file:close()
local claude_task = assert(api.create_task({ repo = repo, title = 'Pending Claude resume' }))
local claude_ref = { repo = repo, id = claude_task.id }
local claude_conversation = { provider = 'claude', session_id = claude_id, cwd = repo }
local claude_bound, claude_bind_error = await(function(callback) api.bind_conversation(claude_ref, claude_conversation, callback) end)
assert(claude_bound, 'Claude fixture bind failed: ' .. vim.inspect(claude_bind_error))
set_pending_start(claude_ref)
local task_name = 'ab-' .. vim.fn.sha256(repo .. '\0' .. claude_task.id):sub(1, 16)
local wrong_live = make_identity('claude', 'claude-wrong', '0199abcd-1234-7abc-8def-123456789ac1', task_name)
live_agents[wrong_live.pane_id] = { identity = wrong_live, cwd = repo, state = 'idle' }
local unsafe_retry, unsafe_retry_error = await(function(callback) api.open_agent(claude_ref, callback) end)
assert(not unsafe_retry and unsafe_retry_error.code == 'runtime_unknown' and not starts.claude,
  'a task pane with a different Claude session blocks offline recovery')
live_agents = {}
local duplicate_retry, duplicate_retry_error = await(function(callback) api.open_agent(claude_ref, callback) end)
assert(not duplicate_retry and duplicate_retry_error.code == 'runtime_unknown' and not starts.claude,
  'a persisted pending Claude start blocks retry when Herdr currently lists no runtime')
assert(api.get_task(claude_ref).pending_start, 'an unverified Claude start remains reserved after a refused retry')
local pending_claude_live = make_identity('claude', 'claude-pending-recovered', claude_id, task_name)
live_agents[pending_claude_live.pane_id] = { identity = pending_claude_live, cwd = repo, state = 'idle' }
local recovered_claude = assert(await(function(callback) api.open_agent(claude_ref, callback) end))
assert(recovered_claude.identity.session_id == claude_id and not starts.claude,
  'an exact live Claude identity recovers a pending start without launching again')
assert(not api.get_task(claude_ref).pending_start, 'exact Claude recovery clears pending_start')

-- Once Herdr confirms that exact runtime offline, the saved transcript remains resumable.
live_agents = {}
local claude_started, claude_open_error = await(function(callback) api.open_agent(claude_ref, callback) end)
assert(claude_started, 'offline Claude resume failed: ' .. vim.inspect(claude_open_error))
assert(claude_started.identity.provider == 'claude' and claude_started.identity.session_id == claude_id,
  'offline Claude resume keeps its saved native UUID')
assert((starts.claude or 0) == 1 and start_args.claude.expected_session_id == claude_id,
  'offline Claude resume starts only after exact-session discovery')
assert(vim.deep_equal(start_args.claude.agent_args, { '--resume', claude_id }),
  'offline Claude resume uses the existing transcript instead of creating a fresh session')
assert(not api.get_task(claude_ref).pending_start, 'successful offline recovery clears its reservation')

-- A session ID shared by sibling worktrees must not attach a runtime from the wrong cwd.
vim.env.CODEX_HOME = root .. '/codex'
local worktree_id = '0199abcd-1234-7abc-8def-123456789ac3'
local codex_dir = root .. '/codex/sessions/2026/10/08'
assert(vim.fn.mkdir(codex_dir, 'p') == 1)
local worktree_file = assert(io.open(codex_dir .. '/fixture-wrong-worktree.jsonl', 'w'))
worktree_file:write(vim.json.encode({ type = 'session_meta', payload = { id = worktree_id, cwd = repo, timestamp = '2026-10-08T00:00:00Z' } }), '\n')
worktree_file:close()
local worktree_task = assert(api.create_task({ repo = repo, title = 'Wrong worktree session' }))
local worktree_ref = { repo = repo, id = worktree_task.id }
local worktree_conversation = { provider = 'codex', session_id = worktree_id, cwd = repo }
local worktree_bound, worktree_bind_error = await(function(callback)
  api.bind_conversation(worktree_ref, worktree_conversation, callback)
end)
assert(worktree_bound, 'wrong-worktree fixture bind failed: ' .. vim.inspect(worktree_bind_error))
local wrong_worktree = make_identity('codex', 'codex-wrong-worktree', worktree_id, 'ab-wrong-worktree')
live_agents[wrong_worktree.pane_id] = { identity = wrong_worktree, cwd = sibling_repo, state = 'idle' }
local resolved_worktree, worktree_resolve_error = await(function(callback)
  require('agent-board.sessions').resolve(worktree_conversation, callback)
end)
assert(not resolved_worktree and worktree_resolve_error.code == 'identity_mismatch',
  'session resolution rejects a matching provider ID whose runtime cwd is a sibling worktree')
local opened_before_wrong_worktree = #opens
local started_before_wrong_worktree = starts.codex
local opened_wrong_worktree, open_wrong_worktree_error = await(function(callback)
  api.open_agent(worktree_ref, callback)
end)
assert(not opened_wrong_worktree and open_wrong_worktree_error.code == 'identity_mismatch',
  'opening a saved session never attaches a runtime from a sibling worktree')
assert(#opens == opened_before_wrong_worktree and starts.codex == started_before_wrong_worktree,
  'wrong-worktree rejection neither opens nor starts a runtime')

vim.fn.delete(root, 'rf')
print('offline provider resume checks passed')
vim.cmd('qa!')
