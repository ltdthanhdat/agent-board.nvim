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
local live_agents, starts, prompts, stops, start_options = {}, 0, {}, 0, {}
local function identity(pane, terminal_id, name)
  return { provider = 'codex', runtime = 'herdr', server = server, pane_id = pane, terminal_id = terminal_id, name = name, session_id = 'session-' .. pane:gsub('[^%w._%-]', '-') }
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
herdr.start = function(repo, provider, name, callback, opts)
  starts = starts + 1
  start_options[starts] = opts and vim.deepcopy(opts) or nil
  local agent_identity = identity('started:pane:' .. starts, 'term-started-' .. starts, name)
  agent_identity.provider = provider
  if opts and opts.expected_session_id then agent_identity.session_id = opts.expected_session_id end
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
      if type(item) == 'table' and (item.repo == value or item.root == value or item.name == value or item.id == value or item.identity and item.identity.pane_id == value or item.agent and item.agent.identity.pane_id == value) then
        return item
      end
    end
    error('selection not found: ' .. tostring(value))
  end
end

local function contains(value, needle)
  assert(value:find(needle, 1, true), ('missing %q in:\n%s'):format(needle, value))
end

local function count_lines(value, needle)
  local count = 0
  for line in value:gmatch('[^\n]+') do
    if line:find(needle, 1, true) then count = count + 1 end
  end
  return count
end

local function count_text(value, needle)
  local count, start = 0, 1
  while true do
    local found = value:find(needle, start, true)
    if not found then return count end
    count, start = count + 1, found + #needle
  end
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

local function picker_windows()
  local list_win, preview_win
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.b[buf].agent_board_session_picker then list_win = win end
    if vim.b[buf].agent_board_session_preview then preview_win = win end
  end
  return list_win, preview_win
end

local function wait_for_picker()
  return vim.wait(10000, function() return picker_windows() ~= nil end)
end

local function accept_picker(index)
  for _ = 2, index do press('j') end
  press('<CR>')
end

local function accept_named_session(title)
  local list_win = assert(picker_windows())
  local picker_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(list_win), 0, -1, false)
  for index, line in ipairs(picker_lines) do
    if line:find(title, 1, true) then return accept_picker(index) end
  end
  error('session not found in picker: ' .. title)
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

local regular_input, held_input_callback = vim.ui.input, nil
vim.ui.input = function(_, callback) held_input_callback = callback end
press('r')
assert(held_input_callback, 'rename prompt stays open for the stale snapshot case')
assert(tasks.update_task({ repo = repo_a, id = first_id }, { title = 'External rename' }))
board.refresh()
vim.wait(20)
local regular_notify, stale_notice = vim.notify, nil
vim.notify = function(message) stale_notice = message end
held_input_callback('Stale UI rename')
vim.notify = regular_notify
vim.ui.input = regular_input
eq(task_from(repo_a, first_id).title, 'External rename', 'a poll while rename prompt is open cannot bypass the snapshot conflict')
contains(stale_notice, 'board changed; reload before saving')

select_responses[#select_responses + 1] = choose('doing')
press('m')
eq(task_from(repo_a, first_id).status, 'doing')
select_responses[#select_responses + 1] = choose('done')
press('m')
eq(task_from(repo_a, first_id).status, 'done')
input_responses[#input_responses + 1] = 'Finished'
press('R')
local renamed_done = assert(api.list_lanes(repo_a))
eq(vim.tbl_filter(function(lane) return lane.id == 'done' end, renamed_done)[1].name, 'Finished', 'R can rename the built-in Done lane')
press('d')
eq(task_from(repo_a, first_id).status, 'done', 'd still targets the built-in done ID after its display name changes')

input_responses[#input_responses + 1] = 'Agent task'
press('n')
local repo_rows = assert(tasks.list_tasks({ scope = 'repo', repo = repo_a }))
local agent_task_id = repo_rows[#repo_rows].task.id
select_responses[#select_responses + 1] = function() return nil end
press('<CR>')
eq(starts, 0, 'canceling the Enter provider picker must not launch an agent')
eq(task_from(repo_a, agent_task_id).agent, vim.NIL, 'canceling the provider picker keeps the task unlinked')
select_responses[#select_responses + 1] = choose('codex')
press('<CR>')
assert(vim.wait(10000, function() return terminal.is_open(table.concat({ repo_a, agent_task_id, 'herdr' }, '\0')) end), 'Enter must create and enter the new session in one action')
local started_task = task_from(repo_a, agent_task_id)
eq(started_task.status, 'todo', 'starting an agent keeps the task in its current lane')
assert(started_task.agent ~= vim.NIL and starts == 1)
press('<Esc>')
press('q')
select_responses[#select_responses + 1] = function(items, opts)
  local labels = {}
  for _, action in ipairs(items) do labels[#labels + 1] = opts.format_item(action) end
  local text = table.concat(labels, '\n')
  contains(text, 'Open / resume session')
  contains(text, 'Send prompt')
  contains(text, 'Stop runtime')
  assert(not text:find('Start session', 1, true), 'linked task must not offer a second session start')
  return nil
end
press(' ')

local starts_before_open = starts

press('<CR>')
assert(vim.wait(10000, function() return terminal.is_open(table.concat({ repo_a, agent_task_id, 'herdr' }, '\0')) end))
eq(starts, starts_before_open, 'Enter on a linked task opens its session without starting another agent')
local float_win=vim.api.nvim_get_current_win()
local float_config=vim.api.nvim_win_get_config(float_win)
assert(float_config.relative=='editor' and float_config.title and float_config.footer,'float label and hide hint')
assert(vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_list_wins(0)[1])==board_buf,'board below float')
press('<Esc>')
press('q')
assert(not terminal.is_open(table.concat({ repo_a, agent_task_id, 'herdr' }, '\0')), 'q hides the floating terminal')
press('<CR>')
assert(vim.wait(10000, function() return terminal.is_open(table.concat({ repo_a, agent_task_id, 'herdr' }, '\0')) end))
eq(spawn_count, 1, 'reopen reuses the attach client')
press('<Esc>')
press('q')
press('<CR>')
assert(vim.wait(10000, function() return terminal.is_open(table.concat({ repo_a, agent_task_id, 'herdr' }, '\0')) end))
local conflict_buf=vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(conflict_buf,0,-1,false,{'{"type":"terminal.closed","reason":"terminal attach failed: terminal term-existing already has an attached client; retry with --takeover"}'})
local conflict_notifications={}
local original_notify=vim.notify
vim.notify=function(message)conflict_notifications[#conflict_notifications+1]=tostring(message)end
exits[1](1,0,'exit')
assert(vim.wait(1000,function()return not terminal.is_open(table.concat({repo_a,agent_task_id,'herdr'},'\0'))end),'conflict attach cleanup')
vim.notify=original_notify
contains(table.concat(conflict_notifications,'\n'),'already has an attached client')

local regular_send, selected_send_identity = api.send, nil
api.send = function(ref, message, expected_agent, callback)
  selected_send_identity = expected_agent
  return regular_send(ref, message, expected_agent, callback)
end
input_responses[#input_responses + 1] = 'Reply with only OK'
select_responses[#select_responses + 1] = function(items, opts)
  for _, action in ipairs(items) do if opts.format_item(action) == 'Send prompt' then return action end end
  error('send prompt action is missing')
end
press(' ')
api.send = regular_send
eq(selected_send_identity, started_task.agent, 'send is bound to the agent shown when its prompt opened')
assert(vim.wait(10000, function() return #prompts > 0 end), 'send prompt reaches the linked agent')
eq(prompts[#prompts], { pane_id = started_task.agent.pane_id, message = 'Reply with only OK' }, 'Space action sends the entered prompt')

select_responses[#select_responses + 1] = function() return nil end
press('<Delete>')
assert(task_from(repo_a, agent_task_id), 'canceling delete keeps the linked task')
eq(stops, 0, 'canceling delete does not stop the agent')
select_responses[#select_responses + 1] = choose('Delete')
press('<Delete>')
assert(not tasks.get_task({ repo = repo_a, id = agent_task_id }), 'deleting a task removes its persisted card')
eq(stops, 0, 'deleting a linked task does not stop its agent')

input_responses[#input_responses + 1] = 'Bind task'
press('n')
local bind_rows = assert(tasks.list_tasks({ scope = 'repo', repo = repo_a }))
local bind_task_id = bind_rows[#bind_rows].task.id
press('b')
assert(wait_for_picker(), 'live session picker timeout')
accept_named_session('existing-agent')
assert(vim.wait(10000,function() return task_from(repo_a,bind_task_id).agent~=vim.NIL end),'live picker bind timeout')
local bound_task = task_from(repo_a, bind_task_id)
eq(bound_task.agent.terminal_id, existing_identity.terminal_id, 'b links the selected existing agent')
eq(bound_task.status, 'todo', 'binding through the UI leaves the task in Todo')

input_responses[#input_responses + 1] = 'Duplicate binding task'
press('n')
local duplicate_bind_id = row_ids(repo_a)[3]
local saved_notify, notifications = vim.notify, {}
vim.notify = function(message) notifications[#notifications + 1] = tostring(message) end
press('b')
assert(wait_for_picker(), 'duplicate session picker timeout')
accept_named_session('existing-agent')
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
local regular_stop_agent, selected_stop_identity = api.stop_agent, nil
api.stop_agent = function(ref, expected_agent, callback)
  selected_stop_identity = expected_agent
  return regular_stop_agent(ref, expected_agent, callback)
end
press('s')
api.stop_agent = regular_stop_agent
assert(vim.wait(10000, function() return stops == 1 end), 'confirmed stop reaches Herdr')
eq(selected_stop_identity, bound_task.agent, 'stop is bound to the agent shown when its confirmation opened')
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
press('<Delete>')
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
assert(api.create_task({ repo = repo_a, title = 'Repo A sibling' }))
assert(api.focus_board({ scope = 'global' }))
press('j')
input_responses[#input_responses + 1] = 'Repo B selected'
press('r')
eq(task_from(repo_a, 'shared-id').title, 'Repo A shared', 'same task ID in another repo does not receive the rename')
eq(task_from(repo_b, 'shared-id').title, 'Repo B selected', 'cursor resolves the repo and task ID pair')
contains(lines(board_buf), 'Project · two/same-name')
contains(lines(board_buf), 'Repo B selected')

local review_a = assert(api.add_lane(repo_a, 'Review'))
local review_b = assert(api.add_lane(repo_b, 'Review'))
local repo_c = git_init(root .. '/three/same-name')
assert(tasks.register_repo(repo_c))
local review_c = assert(api.add_lane(repo_c, 'Review'))
assert(api.add_lane(repo_b, 'B Only'))
assert(api.add_lane(repo_c, 'C Only'))
assert(review_a.id ~= review_b.id and review_b.id ~= review_c.id, 'same-named project lanes have independent IDs')
assert(api.move_task({ repo = repo_b, id = 'shared-id' }, review_b.id))
board.refresh()
vim.wait(20)
local global_lines = lines(board_buf)
contains(global_lines, 'Project · one/same-name')
contains(global_lines, 'Project · two/same-name')
contains(global_lines, 'Project · three/same-name')
contains(global_lines, 'Review (1)')
local _, _, _, registered_projects = api.list_tasks({ scope = 'global' })
local project_indexes = {}
for index, project in ipairs(registered_projects) do project_indexes[project.repo] = index end
local focused_project_index = project_indexes[repo_b]
local function focus_project(repo)
  local target = assert(project_indexes[repo])
  while focused_project_index < target do press(']'); focused_project_index = focused_project_index + 1 end
  while focused_project_index > target do press('['); focused_project_index = focused_project_index - 1 end
end

vim.o.columns = 50
vim.api.nvim_exec_autocmds('VimResized', {})
vim.wait(20)
global_lines = lines(board_buf)
contains(global_lines, 'Project · two/same-name')
assert(not global_lines:find('Project · one/same-name', 1, true), 'narrow global board shows only the focused project')
contains(global_lines, 'Review (1)')
eq(count_lines(global_lines, ' ('), 1, 'narrow view shows one lane')
focus_project(repo_c)
global_lines = lines(board_buf)
contains(global_lines, 'Project · three/same-name')
assert(not global_lines:find('Project · two/same-name', 1, true), 'bracket navigation changes the focused project')
for _ = 1, 3 do press('l') end
contains(lines(board_buf), 'Review (0)')
focus_project(repo_a)
local focused_line = vim.api.nvim_buf_get_lines(board_buf, vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())[1] - 1, vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())[1], false)[1] or ''
contains(focused_line, 'Repo A shared')
press('j')
focused_line = vim.api.nvim_buf_get_lines(board_buf, vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())[1] - 1, vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())[1], false)[1] or ''
contains(focused_line, 'Repo A sibling', 'j moves within the focused project and lane')
press('k')
focused_line = vim.api.nvim_buf_get_lines(board_buf, vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())[1] - 1, vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())[1], false)[1] or ''
contains(focused_line, 'Repo A shared', 'k moves within the focused project and lane')
for _ = 1, 3 do press('l') end
contains(lines(board_buf), 'Review (0)')
focus_project(repo_b)
contains(lines(board_buf), 'Review (1)')
focus_project(repo_a)
for _ = 1, 3 do press('h') end

local move_lane_picker = false
select_responses[#select_responses + 1] = function(items, opts)
  local labels = {}
  for _, lane in ipairs(items) do labels[#labels + 1] = opts.format_item(lane) end
  move_lane_picker = table.concat(labels, '\n')
  contains(move_lane_picker, 'Review')
  assert(not move_lane_picker:find('B Only', 1, true) and not move_lane_picker:find('C Only', 1, true), 'move lists only the selected task repository lanes')
  return assert(vim.tbl_filter(function(lane) return lane.id == review_a.id end, items)[1])
end
press('m')
assert(move_lane_picker, 'move opens the selected repository lane picker')
eq(task_from(repo_a, 'shared-id').status, review_a.id, 'm moves a task to its repository-specific lane')

input_responses[#input_responses + 1] = 'Build'
press('+')
local added_lanes = assert(api.list_lanes(repo_a))
local added_lane = added_lanes[#added_lanes]
eq(added_lane.name, 'Build', '+ adds a lane to the focused project')
input_responses[#input_responses + 1] = 'Verify'
press('r')
local renamed_lanes = assert(api.list_lanes(repo_a))
eq(renamed_lanes[#renamed_lanes].id, added_lane.id, 'lane rename preserves its stable ID')
eq(renamed_lanes[#renamed_lanes].name, 'Verify', 'r renames the focused lane when no task is selected')
press('h')
contains(lines(board_buf), 'Review (1)')
board.refresh()
vim.wait(20)
local selected_cursor = vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())
contains(vim.api.nvim_buf_get_lines(board_buf, selected_cursor[1] - 1, selected_cursor[1], false)[1] or '', 'Repo A shared')
board.refresh()
vim.wait(20)
selected_cursor = vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())
contains(vim.api.nvim_buf_get_lines(board_buf, selected_cursor[1] - 1, selected_cursor[1], false)[1] or '', 'Repo A shared')
press('l')
contains(lines(board_buf), 'Verify (0)')
focus_project(repo_c)
contains(lines(board_buf), 'Project · three/same-name')
contains(lines(board_buf), 'No tasks · n', 'empty registered projects and lanes remain actionable')
focus_project(repo_b)
contains(lines(board_buf), 'Project · two/same-name')

vim.o.columns = 64
vim.api.nvim_exec_autocmds('VimResized', {})
vim.wait(20)
global_lines = lines(board_buf)
contains(global_lines, 'Project · one/same-name', '64 columns remains in the wide layout')
vim.o.columns = 63
vim.api.nvim_exec_autocmds('WinResized', {})
vim.wait(20)
eq(count_lines(lines(board_buf), ' ('), 1, 'WinResized immediately redraws the narrow single-lane view')
vim.o.columns = 140
vim.api.nvim_exec_autocmds('VimResized', {})
vim.wait(20)
global_lines = lines(board_buf)
local project_a_start = assert(global_lines:find('Project · one/same-name', 1, true))
local next_project_start = global_lines:find('\nProject · ', project_a_start + 1, true)
local project_a_lines = global_lines:sub(project_a_start, next_project_start and next_project_start - 1 or #global_lines)
eq(count_text(project_a_lines, ' ('), 3, 'wide project viewport shows at most three adjacent lanes')
contains(project_a_lines, 'Verify (0)')

local board_window = vim.api.nvim_get_current_win()
vim.cmd('vnew')
local auxiliary_window = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_width(board_window, 50)
vim.api.nvim_exec_autocmds('WinResized', {})
vim.wait(20)
eq(count_lines(lines(board_buf), ' ('), 1, 'board window resize redraws using its own narrow width')
vim.api.nvim_win_close(auxiliary_window, true)
vim.api.nvim_exec_autocmds('WinResized', {})
vim.wait(20)
assert(lines(board_buf):find('Project · three/same-name', 1, true), 'restoring the board window width redraws global projects')

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
history:write(vim.json.encode({type='user',sessionId=native_id,cwd=repo_a,timestamp='2026-10-07T00:00:00Z',message={content='Old session prompt preview'}}),'\n')
history:write(vim.json.encode({type='assistant',sessionId=native_id,cwd=repo_a,timestamp='2026-10-07T00:30:00Z',message={content={{type='text',text='Old assistant response preview'}}}}),'\n')
history:write(vim.json.encode({type='ai-title',sessionId=native_id,aiTitle='Offline fixture'}),'\n');history:close()
local newer_id='22345678-1234-4234-8234-123456789abc'
local newer=assert(io.open(root..'/claude/projects/repo/'..newer_id..'.jsonl','w'))
newer:write(vim.json.encode({type='user',sessionId=newer_id,cwd=repo_a,timestamp='2026-10-07T02:00:00Z',message={content='Newer session preview content'}}),'\n');newer:close()
input_responses[#input_responses+1]='Offline linked task'
press('n')
local offline_rows=assert(tasks.list_tasks({scope='repo',repo=repo_a}))
local offline_id=offline_rows[#offline_rows].task.id
local before_bind_starts=starts
press('b')
assert(wait_for_picker(), 'offline session picker timeout')
local picker_list_win, picker_preview_win = picker_windows()
assert(picker_list_win and picker_preview_win, 'session picker must show list and preview panes')
local picker_list_buf = vim.api.nvim_win_get_buf(picker_list_win)
local picker_preview_buf = vim.api.nvim_win_get_buf(picker_preview_win)
contains(table.concat(vim.api.nvim_buf_get_lines(picker_list_buf,0,-1,false),'\n'),'Offline fixture')
contains(table.concat(vim.api.nvim_buf_get_lines(picker_preview_buf,0,-1,false),'\n'),'Newer session preview content')
press('j')
contains(table.concat(vim.api.nvim_buf_get_lines(picker_preview_buf,0,-1,false),'\n'),'Old assistant response preview')
accept_picker(1)
assert(vim.wait(10000,function() return task_from(repo_a,offline_id).conversation~=vim.NIL end),'offline picker binding')
eq(starts,before_bind_starts,'picker binds without launching')
board.refresh();vim.wait(50)
contains(lines(board_buf),'claude · offline')
local real_terminal_open=terminal.open
local resumed_open
terminal.open=function(key,agent_identity,opts)
 resumed_open={key=key,identity=vim.deepcopy(agent_identity),opts=opts}
 return true
end
press('<CR>')
assert(vim.wait(10000,function() return resumed_open~=nil end),'Enter resumes the offline linked session')
terminal.open=real_terminal_open
eq(starts,before_bind_starts+1,'Enter starts exactly one runtime to resume the offline session')
eq(resumed_open.identity.session_id,native_id,'Enter opens the original native Claude session')
eq(start_options[starts].expected_session_id,native_id,'resume start verifies the saved Claude UUID')
eq(start_options[starts].agent_args,{'--resume',native_id},'resume start passes the existing transcript ID')
eq(task_from(repo_a,offline_id).agent.session_id,native_id,'resumed runtime is saved on the task')
local saved_input, create_cancel = vim.ui.input, nil
vim.ui.input = function(_, callback) create_cancel = callback end
press('a')
assert(create_cancel, 'a creates a task instead of opening the linked session')
create_cancel(nil)
vim.ui.input = saved_input
local help_select = vim.ui.select
vim.ui.select = function() error('help must not open a selector') end
press('?')
vim.ui.select = help_select
local help_win
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
 local config=vim.api.nvim_win_get_config(win)
 if config.relative=='editor' then help_win=win;assert(config.focusable==false,'help float is non-focusable');assert(type(config.border)=='table' and config.border[1]=='╭','help float has rounded border') end
end
assert(help_win and vim.api.nvim_win_is_valid(help_win),'board-local help float missing')
press('<Esc>')
assert(not vim.api.nvim_win_is_valid(help_win),'Esc dismisses help')
press('?')
local second_help_win
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do if vim.api.nvim_win_get_config(win).relative=='editor' then second_help_win=win end end
assert(second_help_win,'help can be reopened')
press('q')
assert(not vim.api.nvim_win_is_valid(second_help_win),'q dismisses help without closing the board')
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
