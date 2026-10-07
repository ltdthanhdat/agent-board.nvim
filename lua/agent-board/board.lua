local api = require('agent-board')
local tasks = require('agent-board.tasks')
local herdr = require('agent-board.herdr')
local uv = vim.uv
local M = {}

local statuses = { 'todo', 'doing', 'done' }
local status_labels = { todo = 'Todo', doing = 'Doing', done = 'Done' }
local active

local function notify(message, level)
  vim.notify('agent-board: ' .. tostring(message), level or vim.log.levels.WARN)
end

local function has_agent(agent)
  return type(agent) == 'table' and agent ~= vim.NIL
end

local function ref_key(repo, id)
  return repo .. '\0' .. id
end

local function current(state)
  return active == state and not state.closed and vim.api.nvim_buf_is_valid(state.buf)
end

local function stop_timer(state)
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
end

local function visible(state)
  return current(state)
    and vim.api.nvim_win_is_valid(state.win)
    and vim.api.nvim_tabpage_is_valid(state.tab)
    and vim.api.nvim_get_current_tabpage() == state.tab
end

local function start_timer(state)
  if not current(state) or state.timer then return end
  state.timer = uv.new_timer()
  state.timer:start(2000, 2000, vim.schedule_wrap(function()
    if visible(state) then
      M.refresh()
    else
      stop_timer(state)
    end
  end))
end

local function close_state(state)
  if state.closed then return end
  state.closed = true
  stop_timer(state)
  if active == state then active = nil end
end

local function display_width(text)
  return vim.fn.strdisplaywidth(text)
end

local function fit(text, width)
  text = tostring(text or '')
  local result = ''
  local count = vim.fn.strchars(text)
  for index = 0, count - 1 do
    local char = vim.fn.strcharpart(text, index, 1)
    if display_width(result .. char) > width then
      if width > 0 then
        while result ~= '' and display_width(result .. '…') > width do
          result = vim.fn.strcharpart(result, 0, vim.fn.strchars(result) - 1)
        end
        if display_width(result .. '…') <= width then result = result .. '…' end
      end
      break
    end
    result = result .. char
  end
  return result .. string.rep(' ', math.max(0, width - display_width(result)))
end

local function repo_labels(rows)
  local counts, labels = {}, {}
  for _, row in ipairs(rows) do
    local name = vim.fn.fnamemodify(row.repo, ':t')
    counts[name] = (counts[name] or 0) + 1
  end
  for _, row in ipairs(rows) do
    local name = vim.fn.fnamemodify(row.repo, ':t')
    labels[row.repo] = counts[name] > 1
      and (vim.fn.fnamemodify(row.repo, ':h:t') .. '/' .. name)
      or name
  end
  return labels
end

local function agent_state(state, agent)
  if not has_agent(agent) then return nil end
  if state.runtime_error then return 'runtime unavailable' end
  local key = agent.server .. '\0' .. agent.terminal_id
  if state.checked then return state.agent_states[key] or 'offline' end
  return 'checking'
end

local function item_detail(state, item)
  local agent = item.task.agent
  local conversation = item.task.conversation
  if has_agent(conversation) then
    local label = state.runtime_error and 'runtime unknown' or
      (item.task.pending_start and 'start unverified' or (state.native_states and state.native_states[conversation.session_id]) or (state.native_unknown and 'runtime unknown' or (state.checked and 'offline' or 'checking')))
    return 'claude · ' .. label
  end
  if not has_agent(agent) then return '' end
  return agent.provider .. ' · ' .. (agent_state(state, agent) or 'unknown') .. (agent.provider == 'claude' and ' · resume unavailable' or '')
end

local function columns_for(rows)
  local columns = { {}, {}, {} }
  for _, row in ipairs(rows) do
    local index = row.task.status == 'todo' and 1 or row.task.status == 'doing' and 2 or 3
    columns[index][#columns[index] + 1] = row
  end
  return columns
end

local function join_cells(cells)
  local offsets, parts, bytes = {}, {}, 0
  for column = 1, 3 do
    offsets[column] = bytes
    parts[#parts + 1] = cells[column]
    bytes = bytes + #cells[column]
    if column < 3 then
      parts[#parts + 1] = ' │ '
      bytes = bytes + #' │ '
    end
  end
  return table.concat(parts), offsets
end

local function find_selection(state)
  if state.selected then
    for column, rows in ipairs(state.columns) do
      for index, row in ipairs(rows) do
        if ref_key(row.repo, row.task.id) == state.selected then
          state.focus_column, state.focus_index = column, index
          return
        end
      end
    end
  end
  for column, rows in ipairs(state.columns) do
    if #rows > 0 then
      state.focus_column, state.focus_index = column, 1
      state.selected = ref_key(rows[1].repo, rows[1].task.id)
      return
    end
  end
  state.focus_column = math.min(state.focus_column or 1, 3)
  state.focus_index = 0
  state.selected = nil
end

local function render(state)
  if not current(state) then return end
  state.columns = columns_for(state.rows)
  find_selection(state)
  local width = math.max(12, math.floor((vim.o.columns - 6) / 3))
  local labels = repo_labels(state.rows)
  local lines, line_map, row_offsets, card_lines = {}, {}, {}, { {}, {}, {} }
  local scope_label = state.scope == 'global' and 'global' or ('repo ' .. state.repo)
  lines[#lines + 1] = 'AgentBoard · ' .. scope_label
  if state.error then lines[#lines + 1] = 'Error: ' .. state.error end
  if state.runtime_error then lines[#lines + 1] = 'Herdr runtime unavailable' end
  for _, warning in ipairs(state.warnings or {}) do
    lines[#lines + 1] = 'Warning: ' .. warning.repo .. ' · ' .. warning.error
  end
  local heading_row = #lines + 1
  local headings = {}
  for index, label in ipairs({ 'Todo', 'Doing', 'Done' }) do headings[index] = fit(label, width) end
  lines[#lines + 1], row_offsets[heading_row] = join_cells(headings)

  local count = math.max(#state.columns[1], #state.columns[2], #state.columns[3])
  if count == 0 then
    lines[#lines + 1] = table.concat({ fit('(empty)', width), fit('(empty)', width), fit('(empty)', width) }, ' │ ')
  end
  for index = 1, count do
    local title_cells, detail_cells = {}, {}
    for column = 1, 3 do
      local item = state.columns[column][index]
      if item then
        local title = item.task.title
        if state.scope == 'global' then title = '[' .. labels[item.repo] .. '] ' .. title end
        title_cells[column] = fit(title, width)
        detail_cells[column] = fit(item_detail(state, item), width)
      else
        title_cells[column], detail_cells[column] = string.rep(' ', width), string.rep(' ', width)
      end
    end
    local title_line, title_offsets = join_cells(title_cells)
    lines[#lines + 1] = title_line
    local title_row = #lines
    row_offsets[title_row] = title_offsets
    local detail_line, detail_offsets = join_cells(detail_cells)
    lines[#lines + 1] = detail_line
    local detail_row = #lines
    row_offsets[detail_row] = detail_offsets
    for column = 1, 3 do
      local item = state.columns[column][index]
      if item then
        line_map[title_row] = line_map[title_row] or {}
        line_map[detail_row] = line_map[detail_row] or {}
        line_map[title_row][column], line_map[detail_row][column] = item, item
        card_lines[column][index] = title_row
      end
    end
  end

  state.line_map, state.row_offsets, state.card_lines, state.heading_row = line_map, row_offsets, card_lines, heading_row
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  if vim.api.nvim_win_is_valid(state.win) then
    local row = card_lines[state.focus_column][state.focus_index] or heading_row
    vim.api.nvim_win_set_cursor(state.win, { row, (row_offsets[row] or {})[state.focus_column] or 0 })
  end
end

local function show_error(err)
  if type(err) == 'table' then
    if err.code == 'save_failed' and err.agent then
      return ('%s; agent is still running (terminal %s)'):format(err.message, err.agent.terminal_id)
    end
    return err.message or err.code or vim.inspect(err)
  end
  return err
end

local function reload_rows(state)
  local rows, warnings, snapshots = api.list_tasks({ scope = state.scope, repo = state.repo })
  if not rows then
    state.error = show_error(warnings)
    render(state)
    return nil, warnings
  end
  state.error = nil
  state.rows, state.warnings, state.snapshots = rows, warnings, snapshots
  render(state)
  return true
end

local function current_item(state)
  if not current(state) or not vim.api.nvim_win_is_valid(state.win) then return nil end
  local cursor = vim.api.nvim_win_get_cursor(state.win)
  local row, column = cursor[1], 1
  for index, offset in ipairs(state.row_offsets[row] or {}) do
    if cursor[2] >= offset then column = index end
  end
  local item = (state.line_map[row] or {})[column]
  if item then state.selected = ref_key(item.repo, item.task.id) end
  return item
end

local function selected_ref(state)
  local item = current_item(state)
  if not item then return nil end
  return { repo = item.repo, id = item.task.id }, item
end

local function choose(items, prompt, callback, formatter)
  if #items == 0 then return notify('nothing to select') end
  vim.ui.select(items, {
    prompt = prompt,
    format_item = formatter or function(item) return tostring(item) end,
  }, callback)
end

local function prompt_title(callback, title)
  vim.ui.input({ prompt = title and 'Rename task: ' or 'New task: ', default = title }, callback)
end

local function refresh_after(state, value, err)
  if err then return notify(show_error(err)) end
  if value and current(state) then M.refresh() end
end

local function create_task(state, repo)
  prompt_title(function(title)
    if not title or title:match('^%s*$') then return end
    local created, err = api.create_task({ repo = repo, title = title }, state.snapshots[repo])
    if not created then return notify(show_error(err)) end
    state.selected = ref_key(repo, created.id)
    M.refresh()
  end)
end

local function choose_repo(state, callback)
  local repos = vim.tbl_keys(state.snapshots or {})
  table.sort(repos)
  choose(repos, 'Choose repository:', callback)
end

local function action_create(state)
  if state.scope == 'repo' then return create_task(state, state.repo) end
  choose_repo(state, function(repo)
    if repo then create_task(state, repo) end
  end)
end

local function action_rename(state)
  local ref, item = selected_ref(state)
  if not item then return end
  prompt_title(function(title)
    if not title or title:match('^%s*$') then return end
    local updated, err = api.update_task(ref, { title = title }, state.snapshots[ref.repo])
    if not updated then return notify(show_error(err)) end
    state.selected = ref_key(ref.repo, ref.id)
    M.refresh()
  end, item.task.title)
end

local function action_move(state, status)
  local ref = selected_ref(state)
  if not ref then return end
  local moved, err = api.move_task(ref, status, state.snapshots[ref.repo])
  if not moved then return notify(show_error(err)) end
  state.selected = ref_key(ref.repo, ref.id)
  M.refresh()
end

local function action_choose_status(state)
  choose(statuses, 'Move task to:', function(status)
    if status then action_move(state, status) end
  end, function(status) return status_labels[status] end)
end

local function action_start(state)
  local ref, item = selected_ref(state)
  if not ref then return end
  if has_agent(item.task.conversation) then
    return api.open_agent(ref, function(value, err) refresh_after(state, value, err) end, {tabpage=state.tab,label=item.task.title})
  end
  choose({ 'claude', 'codex', 'pi' }, 'Start agent with:', function(provider)
    if not provider then return end
    api.start_agent(ref, { provider = provider, expected_snapshot = state.snapshots[ref.repo], terminal_opts = {tabpage=state.tab,label=item.task.title} }, function(value, err)
      refresh_after(state, value, err)
    end)
  end)
end

local function action_bind(state)
  local ref, item = selected_ref(state)
  if not ref then return end
  if has_agent(item.task.agent) or has_agent(item.task.conversation) then return notify('task already has a linked session') end
  api.list_sessions(ref, function(discovery, err)
    if not current(state) then return end
    if not discovery then return notify(show_error(err)) end
    for _, warning in ipairs(discovery.warnings) do notify(warning) end
    if discovery.runtime_error then notify('Herdr runtime unknown; opening requires a successful runtime check') end
    choose(discovery.sessions, 'Link session:', function(session)
      if not session or not current(state) then return end
      if session.bound then return notify('this session is already linked to a task') end
      if session.state == 'unavailable' or session.ambiguous then return notify(session.reason or 'Session unavailable') end
      local callback = function(value, bind_error) refresh_after(state, value, bind_error) end
      if session.conversation then
        api.bind_conversation(ref, session.conversation, state.snapshots[ref.repo], callback)
      elseif session.agent then
        api.bind_agent(ref, session.agent.identity, state.snapshots[ref.repo], callback)
      end
    end, function(session)
      local provider = session.conversation and 'claude' or session.agent.identity.provider
      return table.concat({provider, session.title, session.updated_at or '', session.state,
        session.bound and ('already linked: ' .. session.bound_title) or (session.reason or '')}, ' · ')
    end)
  end)
end

local function action_open(state)
  local ref, item = selected_ref(state)
  if not item or not (has_agent(item.task.agent) or has_agent(item.task.conversation)) then return end
  api.open_agent(ref, function(_, err)
    if err then notify(show_error(err)) end
  end, {tabpage=state.tab,label=item.task.title})
end

local function action_send(state)
  local ref, item = selected_ref(state)
  if not item or not (has_agent(item.task.agent) or has_agent(item.task.conversation)) then return end
  vim.ui.input({ prompt = 'Prompt: ' }, function(message)
    if not message or message == '' then return end
    api.send(ref, message, function(_, err)
      if err then notify(show_error(err)) end
    end)
  end)
end

local function confirm(state, prompt, label, callback)
  choose({ label, 'Cancel' }, prompt, function(choice)
    if choice == label then callback() end
  end)
end

local function action_delete(state)
  local ref, item = selected_ref(state)
  if not item then return end
  confirm(state, 'Delete task and link? Claude history and running agent are kept.', 'Delete', function()
    local deleted, err = api.delete_task(ref, state.snapshots[ref.repo])
    if not deleted then return notify(show_error(err)) end
    state.selected = nil
    M.refresh()
  end)
end

local function action_stop(state)
  local ref, item = selected_ref(state)
  if not item or not (has_agent(item.task.agent) or has_agent(item.task.conversation)) then return end
  confirm(state, 'Stop runtime? Conversation history and task status are kept.', 'Stop', function()
    api.stop_agent(ref, function(_, err)
      if err then return notify(show_error(err)) end
      M.refresh()
    end)
  end)
end

local function switch_view(state, scope, repo)
  state.scope, state.repo = scope, repo
  state.selected = nil
  reload_rows(state)
  M.refresh()
end

local function action_scope(state)
  local item = current_item(state)
  if state.scope == 'repo' then return switch_view(state, 'global') end
  if item then return switch_view(state, 'repo', item.repo) end
  choose_repo(state, function(repo)
    if repo then switch_view(state, 'repo', repo) end
  end)
end

local function set_cursor(state)
  if not current(state) or not vim.api.nvim_win_is_valid(state.win) then return end
  local row = state.card_lines[state.focus_column][state.focus_index] or state.heading_row
  vim.api.nvim_win_set_cursor(state.win, { row, (state.row_offsets[row] or {})[state.focus_column] or 0 })
end

local function sync_focus(state)
  local item = current_item(state)
  if not item then return end
  for column, rows in ipairs(state.columns) do
    for index, row in ipairs(rows) do
      if row.repo == item.repo and row.task.id == item.task.id then
        state.focus_column, state.focus_index = column, index
        return
      end
    end
  end
end

local function move_column(state, delta)
  sync_focus(state)
  state.focus_column = math.max(1, math.min(3, (state.focus_column or 1) + delta))
  local count = #state.columns[state.focus_column]
  state.focus_index = count == 0 and 0 or math.min(math.max(state.focus_index or 1, 1), count)
  local item = state.columns[state.focus_column][state.focus_index]
  if item then state.selected = ref_key(item.repo, item.task.id) end
  set_cursor(state)
end

local function move_card(state, delta)
  sync_focus(state)
  local count = #state.columns[state.focus_column]
  if count == 0 then state.focus_index = 0; return set_cursor(state) end
  state.focus_index = math.max(1, math.min(count, (state.focus_index or 1) + delta))
  local item = state.columns[state.focus_column][state.focus_index]
  state.selected = ref_key(item.repo, item.task.id)
  set_cursor(state)
end

local function map(state, key, callback)
  vim.keymap.set('n', key, function()
    if current(state) then callback(state) end
  end, { buffer = state.buf, silent = true, nowait = true })
end

local function install_mappings(state)
  map(state, 'n', action_create)
  map(state, 'r', action_rename)
  map(state, 'm', action_choose_status)
  map(state, 'd', function(s) action_move(s, 'done') end)
  map(state, 'a', action_start)
  map(state, 'b', action_bind)
  map(state, '<CR>', action_open)
  map(state, 'p', action_send)
  map(state, 'x', action_delete)
  map(state, 's', action_stop)
  map(state, 'h', function(s) move_column(s, -1) end)
  map(state, 'l', function(s) move_column(s, 1) end)
  map(state, 'j', function(s) move_card(s, 1) end)
  map(state, 'k', function(s) move_card(s, -1) end)
  map(state, 'g', action_scope)
  map(state, '?', function()
    choose({
      'n new task · r rename · m move · d done',
      'a start new Claude session, or open/resume the linked conversation',
      'b link a running or saved Claude session; selection does not launch it',
      'Enter attach running agent or resume the same saved Claude UUID',
      'Ctrl-\\ Ctrl-n then q hides the terminal; its runtime keeps running',
      's stop runtime, keep conversation history and task status',
      'x delete task/link, keep history and running runtime',
      'h/l columns · j/k tasks · g scope · p prompt · q close board',
    }, 'AgentBoard keys:', function() end)
  end)
  map(state, 'q', function() M.close() end)
end

local function configure_buffer(state)
  local buf, win = state.buf, state.win
  vim.b[buf].agent_board = true
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].signcolumn = 'no'
  install_mappings(state)
end

local function install_autocmds(state)
  state.group = vim.api.nvim_create_augroup('AgentBoard' .. state.buf, { clear = true })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = state.group,
    buffer = state.buf,
    once = true,
    callback = function() close_state(state) end,
  })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = state.group,
    pattern = tostring(state.win),
    once = true,
    callback = function()
      close_state(state)
      if state.group then pcall(vim.api.nvim_del_augroup_by_id, state.group); state.group = nil end
    end,
  })
  vim.api.nvim_create_autocmd('TabLeave', {
    group = state.group,
    callback = function() if vim.api.nvim_get_current_tabpage() == state.tab then stop_timer(state) end end,
  })
  vim.api.nvim_create_autocmd('TabEnter', {
    group = state.group,
    callback = function()
      if vim.api.nvim_get_current_tabpage() == state.tab then
        start_timer(state)
        M.refresh()
      end
    end,
  })
end

function M.refresh()
  local state = active
  if not state or not current(state) then return nil, 'board is not open' end
  local loaded, load_error = reload_rows(state)
  if not loaded then return nil, load_error end
  if state.pending then return true end
  state.pending = true
  local ok, call_error = pcall(herdr.list, function(agents, err)
    vim.schedule(function()
      if not current(state) then return end
      state.pending = false
      state.checked = not err
      state.runtime_error = err ~= nil
      state.agent_states = {}
      state.native_states = {}
      state.native_unknown = false
      if not err then
        for _, agent in ipairs(agents) do
          state.agent_states[agent.identity.server .. '\0' .. agent.identity.terminal_id] = agent.state
          if agent.identity.provider == 'claude' then
            if require('agent-board.claude').valid_id(agent.identity.session_id) then state.native_states[agent.identity.session_id] = 'running'
            else state.native_unknown = true end
          end
        end
      end
      render(state)
    end)
  end)
  if not ok then
    state.pending = false
    state.runtime_error = true
    render(state)
    return nil, call_error
  end
  return true
end

function M.open(opts)
  opts = opts or {}
  local scope = opts.scope or 'repo'
  if scope ~= 'repo' and scope ~= 'global' then return nil, 'scope must be repo or global' end
  local repo
  if scope == 'repo' then
    local root, root_error = api.resolve_repo(opts.repo or vim.fn.getcwd())
    if not root then return nil, root_error .. '; use :AgentBoard global outside a Git repo' end
    repo = root
    local registered, register_error = tasks.register_repo(root)
    if not registered then return nil, register_error end
  end

  if active and current(active) then
    local state = active
    if vim.api.nvim_tabpage_is_valid(state.tab) then vim.api.nvim_set_current_tabpage(state.tab) end
    state.scope, state.repo = scope, repo
    state.selected = nil
    reload_rows(state)
    start_timer(state)
    M.refresh()
    return state.buf
  end

  vim.cmd('tabnew')
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local state = {
    buf = buf,
    win = win,
    tab = vim.api.nvim_get_current_tabpage(),
    scope = scope,
    repo = repo,
    rows = {},
    snapshots = {},
    warnings = {},
    agent_states = {},
    focus_column = 1,
    focus_index = 0,
  }
  active = state
  configure_buffer(state)
  install_autocmds(state)
  reload_rows(state)
  start_timer(state)
  M.refresh()
  return buf
end

function M.close()
  local state = active
  if not state then return false end
  local win = state.win
  close_state(state)
  if win and vim.api.nvim_win_is_valid(win) then
    local ok, close_error = pcall(vim.api.nvim_win_close, win, true)
    if not ok then return nil, tostring(close_error) end
  end
  if state.group then pcall(vim.api.nvim_del_augroup_by_id, state.group); state.group = nil end
  return true
end

return M
