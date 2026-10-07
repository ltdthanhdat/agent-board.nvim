local project_root = vim.fn.getcwd()
package.path = project_root .. '/lua/?.lua;' .. project_root .. '/lua/?/init.lua;' .. package.path

local root = vim.fn.tempname() .. '-agent-board-ui'
assert(vim.fn.mkdir(root, 'p') == 1)

local function git_init(path)
  assert(vim.fn.mkdir(path, 'p') == 1)
  local result = vim.system({ 'git', 'init', '-q', '--initial-branch=main', path }):wait()
  assert(result.code == 0, result.stderr)
  return assert(vim.uv.fs_realpath(path))
end

vim.env.CLAUDE_CONFIG_DIR = root .. '/claude'

local repo_a = git_init(root .. '/one/same-name')
local repo_b = git_init(root .. '/two/same-name')
local storage = require('agent-board.storage')
local tasks = require('agent-board.tasks')
local api = require('agent-board')
local board = require('agent-board.board')
storage.registry_path = function() return root .. '/data/agent-board/repos.json' end
assert(tasks.register_repo(repo_a))
assert(tasks.register_repo(repo_b))

local herdr = require('agent-board.herdr')
local terminal = require('agent-board.terminal')
local server = herdr.server_key()
local live_agents, starts, prompts, stops = {}, 0, {}, 0
local function identity(pane, terminal_id, name)
  return { provider = 'codex', runtime = 'herdr', server = server, pane_id = pane, terminal_id = terminal_id, name = name, session_id = 'session-' .. pane }
end
local function live(agent_identity, cwd)
  return { identity = vim.deepcopy(agent_identity), cwd = cwd or repo_a, state = 'working' }
end

local existing_identity = identity('existing:pane', 'term-existing', 'existing-agent')
live_agents[existing_identity.pane_id] = live(existing_identity)
herdr.list = function(callback)
  local agents = {}
  for _, item in pairs(live_agents) do agents[#agents + 1] = vim.deepcopy(item) end
  callback(agents)
end
herdr.resolve = function(agent_identity, callback)
  local item = live_agents[agent_identity.pane_id]
  if item then callback(vim.deepcopy(item)) else callback(nil, { code = 'offline', message = 'agent is offline' }) end
end
herdr.start = function(repo, provider, name, callback)
  starts = starts + 1
  local agent_identity = identity('started:pane:' .. starts, 'term-started-' .. starts, name)
  agent_identity.provider = provider
  local item = live(agent_identity, repo)
  live_agents[agent_identity.pane_id] = item
  callback({ identity = vim.deepcopy(agent_identity), host = { workspace_id = 'ui-workspace', tab_id = 'ui-tab', pane_id = agent_identity.pane_id } })
end
herdr.send = function(agent_identity, message, callback)
  prompts[#prompts + 1] = { pane_id = agent_identity.pane_id, message = message }
  callback(true)
end
herdr.stop = function(agent_identity, callback)
  stops = stops + 1
  live_agents[agent_identity.pane_id] = nil
  callback(true)
end

local spawn_count, jobs, exits = 0, {}, {}
terminal.spawn_term = function(argv, on_exit)
  spawn_count = spawn_count + 1
  jobs[spawn_count] = argv
  exits[spawn_count] = on_exit
  return spawn_count
end
terminal.job_running = function(job) return job and not jobs['exited:' .. job] end
terminal.stop_term = function(job) jobs['exited:' .. job] = true end

local input_responses, select_responses = {}, {}
vim.ui.input = function(_, callback) callback(table.remove(input_responses, 1)) end
vim.ui.select = function(items, opts, callback)
  local answer = table.remove(select_responses, 1)
  if type(answer) == 'function' then answer = answer(items, opts) end
  callback(answer)
end

local function choose(value)
  return function(items)
    for _, item in ipairs(items) do
      if item == value then return item end
      if type(item) == 'table' and (item.repo == value or item.root == value or item.identity and item.identity.pane_id == value or item.agent and item.agent.identity.pane_id == value) then
        return item
      end
    end
    error('selection not found: ' .. tostring(value))
  end
end

local function contains(value, needle)
  assert(value:find(needle, 1, true), ('missing %q in:\n%s'):format(needle, value))
end

local function eq(actual, expected, message)
  assert(vim.deep_equal(actual, expected), message or vim.inspect(actual))
end

local function lines(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
end

local function press(key)
  local termcode = vim.api.nvim_replace_termcodes(key, true, false, true)
  vim.api.nvim_feedkeys(termcode, 'xt', false)
  vim.wait(20)
end

local function task_from(repo, id)
  return assert(tasks.get_task({ repo = repo, id = id }))
end

local function row_ids(repo)
  local rows = assert(tasks.list_tasks({ scope = 'repo', repo = repo }))
  local ids = {}
  for _, row in ipairs(rows) do ids[#ids + 1] = row.task.id end
  return ids, rows
end

dofile(project_root .. '/plugin/agent-board.lua')
assert(vim.fn.exists(':AgentBoard') == 2, ':AgentBoard command was not registered')
dofile(project_root .. '/plugin/agent-board.lua')

vim.api.nvim_set_current_dir(repo_a)
vim.cmd('AgentBoard')
local board_buf = vim.api.nvim_get_current_buf()
assert(vim.b[board_buf].agent_board, ':AgentBoard did not open its board buffer')
press('h')
press('l')
press('j')
press('k')

input_responses[#input_responses + 1] = 'Unicode task 🔐'
press('n')
local initial = assert(tasks.list_tasks({ scope = 'repo', repo = repo_a }))
assert(#initial == 1)
local first_id = initial[1].task.id
contains(lines(board_buf), 'Unicode task 🔐')
eq(task_from(repo_a, first_id).title, 'Unicode task 🔐')

input_responses[#input_responses + 1] = 'Renamed task 🔐'
press('r')
eq(task_from(repo_a, first_id).title, 'Renamed task 🔐')

select_responses[#select_responses + 1] = choose('doing')
press('m')
eq(task_from(repo_a, first_id).status, 'doing')
press('d')
eq(task_from(repo_a, first_id).status, 'done')

input_responses[#input_responses + 1] = 'Agent task'
press('n')
local repo_rows = assert(tasks.list_tasks({ scope = 'repo', repo = repo_a }))
local agent_task_id = repo_rows[#repo_rows].task.id
select_responses[#select_responses + 1] = choose('codex')
press('a')
local started_task = task_from(repo_a, agent_task_id)
eq(started_task.status, 'doing')
assert(started_task.agent ~= vim.NIL and starts == 1)

press('<CR>')
assert(terminal.is_open(table.concat({ repo_a, agent_task_id, 'herdr' }, '\0')))
local float_win=vim.api.nvim_get_current_win()
local float_config=vim.api.nvim_win_get_config(float_win)
assert(float_config.relative=='editor' and float_config.title and float_config.footer,'float label and hide hint')
assert(vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_list_wins(0)[1])==board_buf,'board below float')
press('<Esc>')
press('q')
assert(not terminal.is_open(table.concat({ repo_a, agent_task_id, 'herdr' }, '\0')), 'q hides the floating terminal')
press('<CR>')
eq(spawn_count, 1, 'reopen reuses the attach client')
press('<Esc>')
press('q')
press('<CR>')
local conflict_buf=vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(conflict_buf,0,-1,false,{'{"type":"terminal.closed","reason":"terminal attach failed: terminal term-existing already has an attached client; retry with --takeover"}'})
local conflict_notifications={}
local original_notify=vim.notify
vim.notify=function(message)conflict_notifications[#conflict_notifications+1]=tostring(message)end
exits[1](1,0,'exit')
assert(vim.wait(1000,function()return not terminal.is_open(table.concat({repo_a,agent_task_id,'herdr'},'\0'))end),'conflict attach cleanup')
vim.notify=original_notify
contains(table.concat(conflict_notifications,'\n'),'already has an attached client')

input_responses[#input_responses + 1] = 'Reply with only OK'
press('p')
eq(prompts[#prompts], { pane_id = started_task.agent.pane_id, message = 'Reply with only OK' }, 'p sends the entered prompt')

select_responses[#select_responses + 1] = function() return nil end
press('x')
assert(task_from(repo_a, agent_task_id), 'canceling delete keeps the linked task')
eq(stops, 0, 'canceling delete does not stop the agent')
select_responses[#select_responses + 1] = choose('Delete')
press('x')
assert(not tasks.get_task({ repo = repo_a, id = agent_task_id }), 'deleting a task removes its persisted card')
eq(stops, 0, 'deleting a linked task does not stop its agent')

input_responses[#input_responses + 1] = 'Bind task'
press('n')
local bind_rows = assert(tasks.list_tasks({ scope = 'repo', repo = repo_a }))
local bind_task_id = bind_rows[#bind_rows].task.id
select_responses[#select_responses + 1] = choose(existing_identity.pane_id)
press('b')
assert(vim.wait(10000,function() return task_from(repo_a,bind_task_id).agent~=vim.NIL end),'live picker bind timeout')
local bound_task = task_from(repo_a, bind_task_id)
eq(bound_task.agent.terminal_id, existing_identity.terminal_id, 'b links the selected existing agent')
eq(bound_task.status, 'todo', 'binding through the UI leaves the task in Todo')

input_responses[#input_responses + 1] = 'Duplicate binding task'
press('n')
local duplicate_bind_id = row_ids(repo_a)[3]
select_responses[#select_responses + 1] = choose(existing_identity.pane_id)
local saved_notify, notifications = vim.notify, {}
vim.notify = function(message) notifications[#notifications + 1] = tostring(message) end
press('b')
assert(vim.wait(10000,function() return #notifications>0 end),'duplicate warning timeout')
vim.notify = saved_notify
eq(task_from(repo_a, duplicate_bind_id).agent, vim.NIL, 'binding an already-linked agent leaves the second task unlinked')
contains(table.concat(notifications, '\n'), 'already linked')

press('k')
select_responses[#select_responses + 1] = function() return 'Cancel' end
press('s')
eq(stops, 0, 'canceling stop does not close the agent pane')
eq(task_from(repo_a, bind_task_id).agent.terminal_id, existing_identity.terminal_id, 'canceling stop keeps the link')

local saved_list = herdr.list
live_agents[existing_identity.pane_id] = nil
board.refresh()
vim.wait(20)
contains(lines(board_buf), 'codex · offline')
eq(task_from(repo_a, bind_task_id).agent.terminal_id, existing_identity.terminal_id, 'offline status preserves the persisted link')
herdr.list = function(callback)
  callback(nil, { code = 'runtime_unavailable', message = 'fixture unavailable' })
end
board.refresh()
vim.wait(20)
contains(lines(board_buf), 'Herdr runtime unavailable')
eq(task_from(repo_a, bind_task_id).agent.terminal_id, existing_identity.terminal_id, 'runtime errors preserve the persisted link')
live_agents[existing_identity.pane_id] = live(existing_identity)
herdr.list = saved_list
board.refresh()
vim.wait(20)

select_responses[#select_responses + 1] = choose('Stop')
press('s')
eq(task_from(repo_a, bind_task_id).status, 'todo', 'confirmed stop does not change task status')
eq(task_from(repo_a, bind_task_id).agent.terminal_id, existing_identity.terminal_id, 'stop keeps the persisted link')
local saved_ids = row_ids(repo_a)
eq(saved_ids, { first_id, bind_task_id, duplicate_bind_id }, 'task IDs and order are stable before board reload')
eq(stops, 1, 'confirmed stop closes the selected pane once')

local closed_buf = board_buf
press('q')
assert(not vim.api.nvim_buf_is_valid(closed_buf), 'q closes the board buffer')
vim.cmd('AgentBoard')
board_buf = vim.api.nvim_get_current_buf()
vim.wait(20)
eq(row_ids(repo_a), saved_ids, 'reopening the board preserves task IDs and order')
eq(task_from(repo_a, bind_task_id).agent.terminal_id, existing_identity.terminal_id, 'reopening preserves the stopped task link')

select_responses[#select_responses + 1] = choose('Delete')
press('x')
assert(not tasks.get_task({ repo = repo_a, id = bind_task_id }))
eq(stops, 1, 'deleting after stop does not stop the agent a second time')

press('g')
contains(lines(board_buf), 'AgentBoard · global')
select_responses[#select_responses + 1] = choose(repo_b)
input_responses[#input_responses + 1] = 'Created from global'
press('n')
local repo_b_rows = assert(tasks.list_tasks({ scope = 'repo', repo = repo_b }))
eq(#repo_b_rows, 1)
eq(repo_b_rows[1].task.title, 'Created from global')
eq(row_ids(repo_a), { first_id, duplicate_bind_id }, 'global creation writes only to its selected repo')
contains(lines(board_buf), 'two/same-name')
contains(lines(board_buf), 'one/same-name')

local function seed_shared_id(repo, title)
  local document, snapshot = storage.read(repo .. '/.agent-board.json', 'board')
  document.tasks = { { id = 'shared-id', title = title, status = 'todo', agent = vim.NIL } }
  document.revision = snapshot.revision + 1
  local release = assert(storage.lock(repo .. '/.agent-board.json'))
  assert(storage.write_locked(repo .. '/.agent-board.json', document, snapshot))
  release()
end
seed_shared_id(repo_a, 'Repo A shared')
seed_shared_id(repo_b, 'Repo B shared')
assert(api.focus_board({ scope = 'global' }))
press('j')
input_responses[#input_responses + 1] = 'Repo B selected'
press('r')
eq(task_from(repo_a, 'shared-id').title, 'Repo A shared', 'same task ID in another repo does not receive the rename')
eq(task_from(repo_b, 'shared-id').title, 'Repo B selected', 'cursor resolves the repo and task ID pair')
contains(lines(board_buf), '[two/same-name] Repo B')

local hold_list, held_list_callback = false, nil
local regular_list = herdr.list
local list_calls = 0
herdr.list = function(callback)
  list_calls = list_calls + 1
  if hold_list then
    held_list_callback = callback
    return
  end
  regular_list(callback)
end
hold_list = true
local before_refresh_calls = list_calls
board.refresh()
board.refresh()
eq(list_calls, before_refresh_calls + 1, 'refresh does not overlap Herdr list requests')
local dead_buffer = board_buf
board.close()
assert(not vim.api.nvim_buf_is_valid(dead_buffer), 'closing the board wipes its scratch buffer')
local callback_ok = pcall(held_list_callback, {})
assert(callback_ok, 'late Herdr result does not update a closed buffer')
vim.wait(20)
herdr.list = regular_list

vim.api.nvim_set_current_dir(repo_a)
assert(board.open({scope='repo',repo=repo_a}))
board_buf=vim.api.nvim_get_current_buf()
local native_id='12345678-1234-4234-8234-123456789abc'
vim.env.CLAUDE_CONFIG_DIR=root..'/claude'
vim.fn.mkdir(root..'/claude/projects/repo','p')
local history=assert(io.open(root..'/claude/projects/repo/'..native_id..'.jsonl','w'))
history:write(vim.json.encode({type='user',sessionId=native_id,cwd=repo_a,timestamp='2026-10-07T00:00:00Z'}),'\n')
history:write(vim.json.encode({type='ai-title',sessionId=native_id,aiTitle='Offline fixture'}),'\n');history:close()
input_responses[#input_responses+1]='Offline linked task'
press('n')
local offline_rows=assert(tasks.list_tasks({scope='repo',repo=repo_a}))
local offline_id=offline_rows[#offline_rows].task.id
local before_bind_starts=starts
select_responses[#select_responses+1]=function(items,opts)
  for _,row in ipairs(items) do if row.conversation and row.conversation.session_id==native_id then
    contains(opts.format_item(row),'Offline fixture');contains(opts.format_item(row),'offline');contains(opts.format_item(row),'2026-10-07')
    return row
  end end
  error('offline Claude session missing from picker')
end
press('b')
assert(vim.wait(10000,function() return task_from(repo_a,offline_id).conversation~=vim.NIL end),'offline picker binding')
eq(starts,before_bind_starts,'picker binds without launching')
board.refresh();vim.wait(50)
contains(lines(board_buf),'claude · offline')
local real_open=api.open_agent
local open_requests=0
api.open_agent=function(ref,cb,opts) open_requests=open_requests+1;assert(ref.id==offline_id);cb(true) end
press('<CR>');press('a')
eq(open_requests,2,'Enter and a open the linked conversation')
api.open_agent=real_open
local helped=false
select_responses[#select_responses+1]=function(items)
 local text=table.concat(items,'\n');contains(text,'resume');contains(text,'Ctrl-');contains(text,'history');helped=true
end
press('?');assert(helped,'board-local help missing')
board.close()
local owner=vim.api.nvim_get_current_tabpage()
vim.cmd('tabnew')
local other=vim.api.nvim_get_current_tabpage()
local closed,closed_error=terminal.open('wrong-tab',existing_identity,{tabpage=owner,label='Fixture'})
assert(not closed and closed_error.code=='owner_unavailable','async open must not use unrelated tab')
vim.api.nvim_set_current_tabpage(owner)
vim.cmd('tabclose')
assert(vim.api.nvim_get_current_tabpage()==other)
local invalid,invalid_error=terminal.open('closed-owner',existing_identity,{tabpage=owner})
assert(not invalid and invalid_error.code=='owner_unavailable','closed owner rejected')
vim.fn.delete(root, 'rf')
print('agent-board ui e2e passed')
