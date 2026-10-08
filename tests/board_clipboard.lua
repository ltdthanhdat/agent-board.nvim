local project_root = vim.fn.getcwd()
package.path = project_root .. '/lua/?.lua;' .. project_root .. '/lua/?/init.lua;' .. package.path

local root = vim.fn.tempname() .. '-agent-board-clipboard'
assert(vim.fn.mkdir(root, 'p') == 1)
local repo = root .. '/repo'
assert(vim.fn.mkdir(repo, 'p') == 1)
assert(vim.system({ 'git', 'init', '-q', '--initial-branch=main', repo }):wait().code == 0)
repo = assert(vim.uv.fs_realpath(repo))
local other_repo = root .. '/other'
assert(vim.fn.mkdir(other_repo, 'p') == 1)
assert(vim.system({ 'git', 'init', '-q', '--initial-branch=main', other_repo }):wait().code == 0)
other_repo = assert(vim.uv.fs_realpath(other_repo))

local storage = require('agent-board.storage')
local tasks = require('agent-board.tasks')
local api = require('agent-board')
local board = require('agent-board.board')
storage.registry_path = function() return root .. '/registry.json' end
assert(tasks.register_repo(repo))
assert(tasks.register_repo(other_repo))

local herdr = require('agent-board.herdr')
local server = herdr.server_key()
local live_agents, starts, stops = {}, 0, 0
herdr.start = function(cwd, provider, name, callback)
  starts = starts + 1
  local identity = {
    provider = provider, runtime = 'herdr', server = server,
    terminal_id = 'term-' .. starts, pane_id = 'pane-' .. starts,
    name = name, session_id = 'session-' .. starts,
  }
  local live = { identity = vim.deepcopy(identity), cwd = cwd, state = 'idle' }
  live_agents[identity.pane_id] = live
  callback({ identity = identity, host = { pane_id = identity.pane_id } })
end
herdr.list = function(callback)
  local result = {}
  for _, live in pairs(live_agents) do result[#result + 1] = vim.deepcopy(live) end
  callback(result)
end
herdr.resolve = function(identity, callback)
  local live = live_agents[identity.pane_id]
  if live then callback(vim.deepcopy(live)) else callback(nil, { code = 'offline', message = 'offline' }) end
end
herdr.stop = function(identity, callback)
  stops = stops + 1
  live_agents[identity.pane_id] = nil
  callback(true)
end

local a = assert(api.create_task({ repo = repo, title = 'Linked task' }))
local b = assert(api.create_task({ repo = repo, title = 'Second task' }))
assert(api.create_task({ repo = other_repo, title = 'Other repository task' }))
local ref_a, ref_b = { repo = repo, id = a.id }, { repo = repo, id = b.id }
local started
tasks.start_agent(ref_a, { provider = 'codex' }, function(value, err) assert(not err); started = value end)
assert(vim.wait(10000, function() return started ~= nil end) and starts == 1, 'fixture session start')
local original_agent = vim.deepcopy(started.agent)
local original_conversation = vim.deepcopy(started.conversation)

local notifications = {}
vim.notify = function(message) notifications[#notifications + 1] = tostring(message) end
vim.ui.input = function() error('paste must not request a prompt') end
local select_calls = 0
vim.ui.select = function(_, _, callback) select_calls = select_calls + 1; callback(nil) end

local function press(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), 'xt', false)
  vim.wait(20)
end

local buf = assert(board.open({ scope = 'repo', repo = repo }))
local board_buf = vim.api.nvim_get_current_buf()
assert(board_buf == buf and vim.b[buf].agent_board)
local original_tab = vim.api.nvim_get_current_tabpage()

-- x marks a task without changing its stored lane or linked runtime.
press('x')
assert(tasks.get_task(ref_a).status == 'todo', 'cut keeps task in its lane until paste')
assert(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1]:find('clipboard', 1, true) == nil)
local initial_text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
assert(initial_text:find('cut', 1, true), 'cut state is visible on the board')
local marked_card = false
for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
  if line:find('▶ ✂ cut ·', 1, true) then marked_card = true end
end
assert(marked_card, 'the selected card itself keeps a visible cut marker')

-- A linked task keeps its session mapping when cut/pasted to another lane.
press('l')
press('p')
assert(tasks.get_task(ref_a).status == 'doing', 'paste moves linked A into the focused lane')
assert(vim.deep_equal(tasks.get_task(ref_a).agent, original_agent), 'paste preserves the linked runtime identity')
assert(vim.deep_equal(tasks.get_task(ref_a).conversation, original_conversation), 'paste preserves the native session mapping')
assert(starts == 1 and stops == 0, 'moving a linked task does not start or stop its runtime')
assert(api.move_task(ref_a, 'todo'), 'restore linked task lane for the remaining cases')
board.refresh()
vim.wait(20)

-- Replacing the clipboard target with the next task must make B the pasted task.
press('x')
press('j')
press('x')
press('l')
local before_stops = stops
press('p')
assert(tasks.get_task(ref_a).status == 'todo', 'replacing cut target leaves A in place')
assert(tasks.get_task(ref_b).status == 'doing', 'paste moves B into the focused lane')
assert(vim.deep_equal(tasks.get_task(ref_a).agent, original_agent), 'cut preserves the session identity')
assert(starts == 1 and stops == before_stops, 'cut and paste do not touch the runtime')

-- p without a cut target is a no-op and does not invoke prompt UI.
local prompt_count = select_calls
press('p')
assert(tasks.get_task(ref_b).status == 'doing' and select_calls == prompt_count)

-- Esc cancels a cut first, leaving the board open and task unchanged.
press('h')
press('x')
local status_before_cancel = tasks.get_task(ref_a).status
press('<Esc>')
assert(vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_get_current_tabpage() == original_tab, 'Esc cancels cut before closing board')
assert(tasks.get_task(ref_a).status == status_before_cancel)
assert(not table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'):find('cut', 1, true), 'Esc clears cut marker')

-- X also cancels. Closing with q discards only the in-memory cut marker.
press('x')
press('X')
assert(tasks.get_task(ref_a).status == 'todo', 'X cancel keeps task in place')
press('x')
press('q')
assert(not vim.api.nvim_buf_is_valid(buf), 'q closes the board')
buf = assert(board.open({ scope = 'repo', repo = repo }))
local reopened_text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
assert(not reopened_text:find('cut', 1, true), 'cut marker does not survive board close')
assert(tasks.get_task(ref_a).status == 'todo' and tasks.get_task(ref_b).status == 'doing', 'closing after cut loses no task')

-- A lane change in another project is rejected without changing the cut task.
assert(board.open({ scope = 'global' }))
buf = vim.api.nvim_get_current_buf()
press('x')
press(']')
press('p')
assert(tasks.get_task(ref_a).status == 'todo', 'cross-repository paste leaves the original lane unchanged')
assert(notifications[#notifications]:find('another repository', 1, true), 'cross-repository paste explains why it was rejected')
press('X')
press('q')

-- An external edit between cut and paste is rejected by the task snapshot.
buf = assert(board.open({ scope = 'repo', repo = repo }))
press('x')
assert(api.update_task(ref_a, { title = 'Edited outside the board' }))
board.refresh()
vim.wait(30)
local prior_status = tasks.get_task(ref_a).status
press('p')
assert(tasks.get_task(ref_a).status == prior_status, 'stale cut does not move an externally edited task')
assert(notifications[#notifications]:find('board changed', 1, true), 'stale cut asks the user to cancel and retry')
press('X')
press('q')

vim.fn.delete(root, 'rf')
print('board clipboard checks passed')
vim.cmd('qa!')
