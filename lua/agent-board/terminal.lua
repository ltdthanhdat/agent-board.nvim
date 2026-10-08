local herdr = require('agent-board.herdr')
local M = {}
local entries = {}

function M.spawn_term(argv, on_exit)
  return vim.fn.termopen(argv, { on_exit = on_exit })
end

function M.job_running(job)
  return job and vim.fn.jobwait({ job }, 0)[1] == -1
end

function M.stop_term(job)
  if job then vim.fn.jobstop(job) end
end

local function same_identity(left, right)
  return left.provider == right.provider
    and left.runtime == right.runtime
    and left.server == right.server
    and left.terminal_id == right.terminal_id
    and left.pane_id == right.pane_id
    and left.name == right.name
    and left.session_id == right.session_id
end

local function close_window(entry)
  if entry.win and vim.api.nvim_win_is_valid(entry.win) then
    pcall(vim.api.nvim_win_close, entry.win, true)
  end
  entry.win = nil
end

local function cleanup(key, entry)
  close_window(entry)
  if vim.api.nvim_buf_is_valid(entry.buf) then
    pcall(vim.api.nvim_buf_delete, entry.buf, { force = true })
  end
  if entries[key] == entry then entries[key] = nil end
end

local function has_controller_conflict(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return false end
  local line_count = vim.api.nvim_buf_line_count(buf)
  local output = table.concat(vim.api.nvim_buf_get_lines(buf, math.max(0, line_count - 100), line_count, false), ''):gsub('%s+', '')
  return output:find('alreadyhasanattachedclient', 1, true) ~= nil
end

local function open_float(buf, opts)
  opts = opts or {}
  local width = math.max(1, math.min(vim.o.columns - 2, math.floor(vim.o.columns * 0.85)))
  local height = math.max(1, math.min(vim.o.lines - 2, math.floor(vim.o.lines * 0.80)))
  return vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    style = 'minimal',
    border = 'rounded',
    title = ' ' .. (opts.label or 'Agent terminal') .. ' ',
    title_pos = 'center',
    footer = ' Ctrl-\\ Ctrl-n · q hide ',
    footer_pos = 'center',
  })
end

local function focus(entry)
  if entry.win and vim.api.nvim_win_is_valid(entry.win) then
    vim.api.nvim_set_current_win(entry.win)
  else
    entry.win = open_float(entry.buf, entry.opts)
  end
  vim.cmd('startinsert')
end

function M.open(key, identity, opts)
  opts = opts or {}
  local owner = opts.tabpage or vim.api.nvim_get_current_tabpage()
  if not vim.api.nvim_tabpage_is_valid(owner) or vim.api.nvim_get_current_tabpage() ~= owner then
    return nil, {code='owner_unavailable',message='Return to the board tab and open the agent again'}
  end
  local argv, argv_error = herdr.attach_argv(identity)
  if not argv then return nil, argv_error end
  local current = entries[key]
  if current and same_identity(current.identity, identity) and M.job_running(current.job) then
    current.opts = opts
    if current.win and vim.api.nvim_win_is_valid(current.win) and vim.api.nvim_win_get_tabpage(current.win) ~= owner then close_window(current) end
    focus(current)
    return current
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  local entry = { buf = buf, identity = vim.deepcopy(identity), opts = opts }
  local ok, win = pcall(open_float, buf, opts)
  if not ok then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return nil, { code = 'terminal_error', message = tostring(win) }
  end
  entry.win = win
  entries[key] = entry

  if current then
    close_window(current)
    if M.job_running(current.job) then
      M.stop_term(current.job)
    else
      cleanup(key, current)
    end
  end

  vim.keymap.set('n', 'q', function() M.hide(key) end, { buffer = buf, silent = true, nowait = true })
  local started, job = pcall(M.spawn_term, argv, function(job_id, code, event)
    vim.schedule(function()
      local was_current = entries[key] == entry
      local controller_conflict = was_current and has_controller_conflict(entry.buf)
      cleanup(key, entry)
      if controller_conflict then
        vim.notify('agent-board: Herdr terminal already has an attached client. Close the other controller and reopen; the agent is still running.', vim.log.levels.WARN)
      elseif code ~= 0 and was_current then
        vim.notify('agent-board: Herdr attach failed (exit ' .. tostring(code) .. '). Check the terminal controller and reopen; the agent runtime is kept.', vim.log.levels.WARN)
      end
    end)
  end)
  if not started or type(job) ~= 'number' or job <= 0 then
    cleanup(key, entry)
    return nil, { code = 'terminal_error', message = started and 'could not start Herdr attach client' or tostring(job) }
  end
  entry.job = job
  vim.cmd('startinsert')
  return entry
end

function M.hide(key)
  local entry = entries[key]
  if entry then
    close_window(entry)
  end
end

function M.is_open(key)
  local entry = entries[key]
  return entry ~= nil and entry.win ~= nil and vim.api.nvim_win_is_valid(entry.win)
end

return M
