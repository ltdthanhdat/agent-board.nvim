local project_root = vim.fn.getcwd()
package.path = project_root .. '/lua/?.lua;' .. project_root .. '/lua/?/init.lua;' .. package.path

local root = vim.fn.tempname() .. '-board-highlights'
local function repo(name)
  local path = root .. '/' .. name
  assert(vim.fn.mkdir(path, 'p') == 1)
  assert(vim.system({ 'git', 'init', '-q', path }):wait().code == 0)
  return path
end
local a, b = repo('alpha'), repo('beta')
local storage = require('agent-board.storage')
storage.registry_path = function() return root .. '/registry.json' end
local tasks = require('agent-board.tasks')
local board = require('agent-board.board')
require('agent-board.herdr').list = function(callback) callback({}) end
local function seed(path, title, status)
  local task = assert(tasks.create_task({ repo = path, title = title }))
  assert(tasks.move_task({ repo = path, id = task.id }, status))
end
seed(a, 'Todo sibling', 'todo')
seed(a, 'Doing 日本語', 'doing')
seed(a, 'Second doing', 'doing')
seed(a, 'Done sibling', 'done')
seed(b, 'Other project', 'todo')

vim.o.columns = 160
vim.o.cursorline = true
vim.o.cursorcolumn = true
vim.o.colorcolumn = '20,60'
local buf = assert(board.open({ repo = a }))
local win = vim.api.nvim_get_current_win()
assert(not vim.wo[win].cursorline, 'board must not highlight the full cursor row')
assert(not vim.wo[win].cursorcolumn, 'board must not highlight the full cursor column')
assert(vim.wo[win].colorcolumn == '', 'board must not inherit editing column guides')

local function press(key)
  vim.api.nvim_feedkeys(key, 'xt', false)
  vim.wait(20)
end
local function verify(lane, title)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local marks = vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces().AgentBoard, 0, -1, { details = true })
  local selected, focused = {}, {}
  for _, mark in ipairs(marks) do
    local row, first, details = mark[2], mark[3], mark[4]
    if details.hl_group == 'AgentBoardSelected' then
      local text = lines[row + 1]:sub(first + 1, details.end_col)
      assert(not text:find('│', 1, true), 'selected task background must stay inside the lane border')
      selected[#selected + 1] = text
    elseif details.hl_group == 'AgentBoardLaneFocus' then
      focused[#focused + 1] = mark
    end
  end
  if title then
    assert(#selected == 1, 'only the selected task row is highlighted; details stay outside selection')
    assert(selected[1]:find(title, 1, true), 'highlight follows the selected task')
  else
    assert(#selected == 0, 'empty lane must not select a task in another lane')
  end
  assert(#focused > 0, 'focused lane must have visible borders')
  local heading, left, right
  for _, mark in ipairs(focused) do
    local text = lines[mark[2] + 1]:sub(mark[3] + 1, mark[4].end_col)
    if text:find(lane .. ' (', 1, true) then
      heading = mark[2]
      left = vim.fn.strdisplaywidth(lines[heading + 1]:sub(1, mark[3]))
      right = vim.fn.strdisplaywidth(lines[heading + 1]:sub(1, mark[4].end_col - #'│'))
    end
  end
  assert(heading, 'only the active project lane gets a focused heading')
  local bottom
  for row = heading + 1, #lines - 1 do
    for col in lines[row + 1]:gmatch('()╰') do
      if vim.fn.strdisplaywidth(lines[row + 1]:sub(1, col - 1)) == left then bottom = row; break end
    end
    if bottom then break end
  end
  assert(bottom, 'lane has a bottom border')
  for row = heading + 2, bottom - 1 do
    for _, col in ipairs({ left, right }) do
      local found = false
      for _, mark in ipairs(focused) do
        if mark[2] == row then
          local start = vim.fn.strdisplaywidth(lines[row + 1]:sub(1, mark[3]))
          local finish = vim.fn.strdisplaywidth(lines[row + 1]:sub(1, mark[4].end_col))
          if start <= col and finish > col then found = true end
        end
      end
      assert(found, 'focused lane side borders must stay visible on every card row')
    end
  end
  local focus_style = vim.api.nvim_get_hl(0, { name = 'AgentBoardLaneFocus', link = false })
  assert(focus_style.fg and not focus_style.bg, 'lane focus needs an accent without a background fill')
  local idle_style = vim.api.nvim_get_hl(0, { name = 'AgentBoardLaneBorder', link = false })
  assert(idle_style.fg and idle_style.fg ~= focus_style.fg, 'focused and idle borders must be distinguishable')
end

verify('Todo', 'Todo sibling')
local initial_text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
assert(initial_text:find('Task details', 1, true), 'board needs a details area like the supplied reference')
assert(initial_text:find('Enter  Start session', 1, true), 'unlinked task must show its contextual Enter action')
press('l')
verify('Doing', 'Doing 日本語')
press(vim.api.nvim_replace_termcodes('<Down>', true, false, true))
verify('Doing', 'Second doing')
vim.fn.winrestview({ leftcol = 5 })
board.refresh()
vim.wait(20)
assert(vim.fn.winsaveview().leftcol == 0, 'refresh must reset stale horizontal scrolling so the lane borders stay visible')
verify('Doing', 'Second doing')
press('k')
verify('Doing', 'Doing 日本語')
press('l')
verify('Done', 'Done sibling')
assert(tasks.add_lane(a, 'Review'))
board.refresh()
press('l')
verify('Review')
local review_text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
assert(review_text:find('Enter  New task', 1, true), 'empty lane must show its contextual Enter action')
press(vim.api.nvim_replace_termcodes('<S-Tab>', true, false, true))
verify('Done', 'Done sibling')
press(vim.api.nvim_replace_termcodes('<Tab>', true, false, true))
verify('Review')
for _, columns in ipairs({ 50, 64, 160 }) do
  vim.o.columns = columns
  vim.api.nvim_exec_autocmds('VimResized', {})
  vim.wait(20)
  verify('Review')
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    assert(vim.fn.strdisplaywidth(line) <= columns, 'board layout must fit the window')
  end
end
vim.cmd('belowright vsplit')
local split = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_width(split, 42)
vim.api.nvim_set_current_win(win)
vim.api.nvim_exec_autocmds('WinResized', {})
vim.wait(20)
verify('Review')
for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
  assert(vim.fn.strdisplaywidth(line) <= vim.api.nvim_win_get_width(win), 'board layout must fit a split window')
end
vim.api.nvim_win_close(split, true)
vim.api.nvim_exec_autocmds('WinResized', {})
vim.wait(20)
board.open({ scope = 'global' })
verify('Review')
press(']')
verify('Todo', 'Other project')
local markers = 0
for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
  for _ in line:gmatch('▸') do markers = markers + 1 end
end
assert(markers == 1, 'global board must mark only one focused project lane')
vim.cmd('colorscheme default')
verify('Todo', 'Other project')
press(vim.api.nvim_replace_termcodes('<Tab>', true, false, true))
verify('Doing')
vim.ui.input = function(_, callback) callback('Created with Enter') end
press(vim.api.nvim_replace_termcodes('<CR>', true, false, true))
verify('Doing', 'Created with Enter')
local rows = assert(tasks.list_tasks({ scope = 'repo', repo = b }))
local created = rows[#rows].task
assert(created.title == 'Created with Enter' and created.status == 'doing', 'Enter creates in the focused empty lane, not the first lane')
vim.ui.select = function(actions, opts, callback)
  local labels = {}
  for _, action in ipairs(actions) do labels[#labels + 1] = opts.format_item(action) end
  local text = table.concat(labels, '\n')
  assert(text:find('Start session', 1, true) and text:find('Link existing session', 1, true), 'unlinked task actions must offer starting and linking')
  assert(not text:find('Stop runtime', 1, true), 'unlinked task must not offer stopping a runtime')
  for _, action in ipairs(actions) do
    if opts.format_item(action) == 'Rename task' then return callback(action) end
  end
  error('rename task action missing')
end
vim.ui.input = function(_, callback) callback('Renamed from actions') end
press(' ')
verify('Doing', 'Renamed from actions')
assert(tasks.get_task({ repo = b, id = created.id }).title == 'Renamed from actions', 'Space menu must execute the selected action')
local before_cancel = vim.deepcopy(tasks.list_tasks({ scope = 'repo', repo = b }))
vim.ui.select = function(_, _, callback) callback(nil) end
press(' ')
assert(vim.deep_equal(tasks.list_tasks({ scope = 'repo', repo = b }), before_cancel), 'canceling actions must not mutate tasks')
seed(b, 'Another doing task', 'doing')
board.refresh()
vim.wait(20)
local held_menu, rename_action
vim.ui.select = function(actions, opts, callback)
  held_menu = callback
  for _, action in ipairs(actions) do
    if opts.format_item(action) == 'Rename task' then rename_action = action end
  end
end
press(' ')
assert(held_menu and rename_action)
assert(tasks.delete_task({ repo = b, id = created.id }))
board.refresh()
vim.wait(20)
verify('Doing', 'Another doing task')
local rename_prompts = 0
vim.ui.input = function(_, callback) rename_prompts = rename_prompts + 1; callback('Wrong target') end
local saved_notify = vim.notify
vim.notify = function() end
held_menu(rename_action)
vim.notify = saved_notify
assert(rename_prompts == 0, 'a stale actions menu must not target the task selected by refresh')
verify('Doing', 'Another doing task')
press('?')
press(vim.api.nvim_replace_termcodes('<Esc>', true, false, true))
assert(vim.api.nvim_buf_is_valid(buf), 'Esc closes help before closing the board')
press(vim.api.nvim_replace_termcodes('<Esc>', true, false, true))
assert(not vim.api.nvim_buf_is_valid(buf), 'Esc returns from the board when no overlay is open')
assert(vim.o.cursorline and vim.o.cursorcolumn and vim.o.colorcolumn == '20,60', 'board must preserve editor options in other windows')
print('board highlight checks passed')
