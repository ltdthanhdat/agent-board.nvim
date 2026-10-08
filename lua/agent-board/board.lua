local api = require('agent-board')
local tasks = require('agent-board.tasks')
local herdr = require('agent-board.herdr')
local session_picker = require('agent-board.session_picker')
local uv = vim.uv
local M = {}
local active
local close_help

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
  if close_help then close_help(state) end
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

local function repo_labels(projects)
  local counts, labels = {}, {}
  for _, project in ipairs(projects) do
    local name = vim.fn.fnamemodify(project.repo, ':t')
    counts[name] = (counts[name] or 0) + 1
  end
  for _, project in ipairs(projects) do
    local name = vim.fn.fnamemodify(project.repo, ':t')
    labels[project.repo] = counts[name] > 1
      and (vim.fn.fnamemodify(project.repo, ':h:t') .. '/' .. name)
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
    local key = conversation.provider .. '\0' .. conversation.session_id
    local label = state.runtime_error and 'runtime unknown' or
      (item.task.pending_start and 'start unverified' or (state.native_states and state.native_states[key]) or (state.native_unknown and 'runtime unknown' or (state.checked and 'offline' or 'checking')))
    return conversation.provider .. ' · ' .. label
  end
  if not has_agent(agent) then return '' end
  return agent.provider .. ' · ' .. (agent_state(state, agent) or 'unknown')
end

local function join_panels(cells)
  local offsets, sizes, parts, bytes = {}, {}, {}, 0
  for column, cell in ipairs(cells) do
    offsets[column], sizes[column] = bytes, #cell
    parts[#parts + 1] = cell
    bytes = bytes + #cell
    if column < #cells then
      parts[#parts + 1] = '  '
      bytes = bytes + 2
    end
  end
  return table.concat(parts), offsets, sizes
end

local function join_cells(cells, width)
  local panels = {}
  for column, cell in ipairs(cells) do
    panels[column] = '│ ' .. fit(cell, width) .. ' │'
  end
  local line, offsets, sizes = join_panels(panels)
  local content_offsets = {}
  for column, offset in ipairs(offsets) do content_offsets[column] = offset + #'│ ' end
  return line, offsets, content_offsets, sizes
end

local function panel_border(width, left, right)
  return left .. string.rep('─', math.max(0, width - 2)) .. right
end

local function join_borders(count, width, left, right)
  local cells = {}
  for column = 1, count do cells[column] = panel_border(width, left, right) end
  return join_panels(cells)
end

local function build_project_views(state)
  local views = {}
  for _, project in ipairs(state.projects or {}) do
    local view = { project = project, lanes = {} }
    for lane_index, lane in ipairs(project.lanes) do
      view.lanes[lane_index] = { lane = lane, rows = {} }
    end
    for _, row in ipairs(state.rows) do
      if row.repo == project.repo then
        for _, lane in ipairs(view.lanes) do
          if lane.lane.id == row.task.status then
            lane.rows[#lane.rows + 1] = row
            break
          end
        end
      end
    end
    views[#views + 1] = view
  end
  state.project_views = views
end

local function find_selection(state)
  if state.selected then
    for project_index, project in ipairs(state.project_views) do
      for lane_index, lane in ipairs(project.lanes) do
        for item_index, row in ipairs(lane.rows) do
          if ref_key(row.repo, row.task.id) == state.selected then
            state.focus_project = project_index
            state.lane_focus[project.project.repo] = lane_index
            state.focus_index = item_index
            return
          end
        end
      end
    end
  end

  state.selected = nil
  state.focus_project = math.max(1, math.min(state.focus_project or 1, #state.project_views))
  local project = state.project_views[state.focus_project]
  if not project then state.focus_index = 0; return end
  local lane_index = math.max(1, math.min(state.lane_focus[project.project.repo] or 1, #project.lanes))
  state.lane_focus[project.project.repo] = lane_index
  local rows = project.lanes[lane_index] and project.lanes[lane_index].rows or {}
  state.focus_index = #rows > 0 and 1 or 0
  if rows[1] then state.selected = ref_key(rows[1].repo, rows[1].task.id) end
end

local function task_details(state, width, compact)
  local project = state.project_views[state.focus_project]
  local lane = project and project.lanes[state.lane_focus[project.project.repo] or 1]
  local item = lane and lane.rows[state.focus_index]
  local lines, groups = {}, {}
  local function add(text, group)
    local part = ''
    for index = 0, vim.fn.strchars(text) - 1 do
      local char = vim.fn.strcharpart(text, index, 1)
      if display_width(part .. char) > width then
        lines[#lines + 1], groups[#lines + 1] = part, group
        part = ''
      end
      part = part .. char
    end
    lines[#lines + 1], groups[#lines + 1] = part, group
  end
  add('Task details', 'AgentBoardTitle')
  add('')
  add(item and item.task.title or 'No task selected', 'AgentBoardCard')
  add(item and (item_detail(state, item) ~= '' and item_detail(state, item) or 'No linked session') or 'Empty lane', 'Comment')
  if project then
    add('')
    if compact then
      add('Project · ' .. vim.fn.fnamemodify(project.project.repo, ':t'), 'Comment')
    else
      add('Project', 'Comment')
      add(vim.fn.fnamemodify(project.project.repo, ':~'))
    end
    add('Lane · ' .. lane.lane.name, 'Comment')
  end
  if item then
    local conversation = item.task.conversation
    local agent = item.task.agent
    local id = has_agent(conversation) and conversation.session_id or (has_agent(agent) and agent.session_id)
    if id and not compact then
      add('')
      add('Session', 'Comment')
      add(id)
    end
  end
  add('')
  local linked = item and (has_agent(item.task.agent) or has_agent(item.task.conversation))
  add(item and (linked and 'Enter  Open / resume session' or 'Enter  Start session') or 'Enter  New task', 'AgentBoardLaneFocus')
  add('Space  Actions', 'Comment')
  return lines, groups
end

local function render(state)
  if not current(state) then return end
  build_project_views(state)
  find_selection(state)

  local window_width = vim.api.nvim_win_is_valid(state.win)
    and math.min(vim.o.columns, vim.api.nvim_win_get_width(state.win))
    or vim.o.columns
  local narrow = window_width < 64
  local visible_count = narrow and 1 or 3
  local sidebar_width = window_width >= 120 and math.min(38, math.floor(window_width * 0.25)) or 0
  local board_width = math.max(12, window_width - 2 - (sidebar_width > 0 and sidebar_width + 3 or 0))
  local panel_width = narrow and board_width or math.max(12, math.floor((board_width - 4) / 3))
  local width = math.max(8, panel_width - 4)
  local labels = repo_labels(state.projects or {})
  local lines, line_map, row_offsets, highlights, project_render = {}, {}, {}, {}, {}
  local line_groups = {}
  local function append(line, group)
    lines[#lines + 1] = line
    line_groups[#lines] = group
    return #lines
  end

  local scope_label = state.scope == 'global' and 'global' or ('repo ' .. (labels[state.repo] or vim.fn.fnamemodify(state.repo, ':t')))
  append(fit('AgentBoard · ' .. scope_label, board_width), 'AgentBoardTitle')
  local linked_count = 0
  for _, row in ipairs(state.rows) do
    if has_agent(row.task.agent) or has_agent(row.task.conversation) then linked_count = linked_count + 1 end
  end
  append(fit('Tasks ' .. #state.rows .. ' · Sessions ' .. linked_count .. ' · Tab lanes · ? help', board_width), 'Comment')
  if state.error then append(fit('Error: ' .. state.error, board_width), 'DiagnosticError') end
  if state.runtime_error then append(fit('Herdr runtime unavailable', board_width), 'DiagnosticWarn') end
  for _, warning in ipairs(state.warnings or {}) do
    append(fit('Warning: ' .. warning.repo .. ' · ' .. warning.error, board_width), 'DiagnosticWarn')
  end
  if #state.project_views == 0 then append(fit('No registered projects. Open a repository with :AgentBoard first.', board_width), 'Comment') end

  for project_index, project_view in ipairs(state.project_views) do
    if not narrow or project_index == state.focus_project then
      if #lines > 1 then append('') end
      local project = project_view.project
      append('Project · ' .. labels[project.repo], 'AgentBoardProject')
      local lane_count = #project_view.lanes
      local focus_lane = math.max(1, math.min(state.lane_focus[project.repo] or 1, lane_count))
      state.lane_focus[project.repo] = focus_lane
      local shown_count = math.min(visible_count, lane_count)
      local start_lane = narrow and focus_lane or math.max(1, math.min(focus_lane - math.floor(visible_count / 2), lane_count - shown_count + 1))
      local lane_cells, shown_lanes = {}, {}
      local function highlight_sides(row, offsets, sizes)
        for column, item in ipairs(shown_lanes) do
          local group = project_index == state.focus_project and item.index == focus_lane
            and 'AgentBoardLaneFocus' or 'AgentBoardLaneBorder'
          highlights[#highlights + 1] = { row = row, first = offsets[column], last = offsets[column] + #'│', group = group }
          highlights[#highlights + 1] = { row = row, first = offsets[column] + sizes[column] - #'│', last = offsets[column] + sizes[column], group = group }
        end
      end
      local project_task_count = 0
      for _, lane in ipairs(project_view.lanes) do project_task_count = project_task_count + #lane.rows end
      for column = 1, shown_count do
        local lane_index = start_lane + column - 1
        local lane_view = project_view.lanes[lane_index]
        shown_lanes[column] = { index = lane_index, view = lane_view }
        local marker = project_index == state.focus_project and lane_index == focus_lane and '▸ ' or '  '
        lane_cells[column] = marker .. lane_view.lane.name .. ' (' .. #lane_view.rows .. ')'
      end
      local top_line, top_offsets, top_sizes = join_borders(shown_count, panel_width, '╭', '╮')
      local top_row = append(top_line, 'AgentBoardLaneBorder')
      local heading_line, heading_cell_offsets, heading_offsets, heading_sizes = join_cells(lane_cells, width)
      local heading_row = append(heading_line, 'AgentBoardLane')
      highlight_sides(heading_row, heading_cell_offsets, heading_sizes)
      row_offsets[heading_row] = heading_offsets
      local lane_divider, lane_divider_offsets, lane_divider_sizes = join_borders(shown_count, panel_width, '├', '┤')
      local lane_divider_row = append(lane_divider, 'AgentBoardLaneBorder')
      for column, item in ipairs(shown_lanes) do
        if project_index == state.focus_project and item.index == focus_lane then
          highlights[#highlights + 1] = { row = top_row, first = top_offsets[column], last = top_offsets[column] + top_sizes[column], group = 'AgentBoardLaneFocus' }
          highlights[#highlights + 1] = { row = heading_row, first = heading_cell_offsets[column], last = heading_cell_offsets[column] + heading_sizes[column], group = 'AgentBoardLaneFocus' }
          highlights[#highlights + 1] = { row = lane_divider_row, first = lane_divider_offsets[column], last = lane_divider_offsets[column] + lane_divider_sizes[column], group = 'AgentBoardLaneFocus' }
        end
      end
      local card_lines = {}
      for column = 1, shown_count do card_lines[column] = {} end
      local card_count = 0
      for _, item in ipairs(shown_lanes) do card_count = math.max(card_count, #item.view.rows) end
      if card_count == 0 then
        local empty = {}
        for column = 1, shown_count do empty[column] = project_task_count == 0 and column == 1 and 'No tasks · n new · + lane' or '— empty —' end
        local empty_line_text, empty_offsets, _, empty_sizes = join_cells(empty, width)
        local empty_row = append(empty_line_text, 'Comment')
        highlight_sides(empty_row, empty_offsets, empty_sizes)
      end
      for index = 1, card_count do
        local title_cells, visible_items = {}, {}
        for column, item in ipairs(shown_lanes) do
          local row = item.view.rows[index]
          visible_items[column] = row
          if row then
            local selected = ref_key(row.repo, row.task.id) == state.selected
            local cut = state.cut and state.cut.ref.repo == row.repo and state.cut.ref.id == row.task.id
            local marker = cut and (selected and '▶ ✂ cut · ' or '✂ cut · ') or selected and '▶ ' or '  '
            title_cells[column] = marker .. row.task.title
          else
            title_cells[column] = index == 1 and '— empty —' or ''
          end
        end
        local title_line, title_cell_offsets, title_offsets, title_sizes = join_cells(title_cells, width)
        local title_row = append(title_line, 'AgentBoardCard')
        highlight_sides(title_row, title_cell_offsets, title_sizes)
        row_offsets[title_row] = title_offsets
        for column = 1, shown_count do
          local row = visible_items[column]
          if row then
            line_map[title_row] = line_map[title_row] or {}
            line_map[title_row][column] = row
            card_lines[column][index] = title_row
            if ref_key(row.repo, row.task.id) == state.selected then
              local first = title_offsets[column]
              local last = title_cell_offsets[column] + title_sizes[column] - #' │'
              highlights[#highlights + 1] = { row = title_row, first = first, last = last, group = 'AgentBoardSelected' }
            end
          end
        end
      end
      local bottom_line, bottom_offsets, bottom_sizes = join_borders(shown_count, panel_width, '╰', '╯')
      local bottom_row = append(bottom_line, 'AgentBoardLaneBorder')
      for column, item in ipairs(shown_lanes) do
        if project_index == state.focus_project and item.index == focus_lane then
          highlights[#highlights + 1] = { row = bottom_row, first = bottom_offsets[column], last = bottom_offsets[column] + bottom_sizes[column], group = 'AgentBoardLaneFocus' }
        end
      end
      project_render[project.repo] = {
        project_index = project_index,
        start_lane = start_lane,
        shown_lanes = shown_lanes,
        heading_row = heading_row,
        card_lines = card_lines,
      }
    end
  end

  local active_project = state.project_views[state.focus_project]
  local cursor_position
  if active_project then
    local rendered = project_render[active_project.project.repo]
    local lane_index = state.lane_focus[active_project.project.repo] or 1
    local column = rendered and lane_index - rendered.start_lane + 1 or 1
    local row = rendered and (rendered.card_lines[column] and rendered.card_lines[column][state.focus_index] or rendered.heading_row) or 1
    local col = (row_offsets[row] or {})[column] or 0
    state.heading_row = rendered and rendered.heading_row or 1
    cursor_position = { row, col }
  end

  local details, detail_groups = task_details(state, sidebar_width > 0 and sidebar_width or board_width, sidebar_width == 0)
  if sidebar_width > 0 then
    local count = math.max(#lines, #details)
    for row = 1, count do
      local main = fit(lines[row] or '', board_width)
      lines[row] = main .. ' │ ' .. fit(details[row] or '', sidebar_width)
      highlights[#highlights + 1] = { row = row, first = #main, last = #main + #' │ ', group = 'AgentBoardLaneBorder' }
      highlights[#highlights + 1] = { row = row, first = #main + #' │ ', last = #lines[row], group = detail_groups[row] or 'AgentBoardCard' }
    end
  else
    append('')
    for row, line in ipairs(details) do append(fit(line, board_width), detail_groups[row] or 'AgentBoardCard') end
  end
  append('')
  local footer = state.cut and ('cut: ' .. state.cut.title .. ' · p paste · X cancel')
    or (narrow and 'Enter open/new · Space actions · ? · Esc back'
      or 'Enter open/new · Space actions · a/n new · r rename · m move · Tab lanes · ↑/↓ tasks · ? help · Esc back')
  if state.scope == 'global' and not narrow then footer = footer .. ' · [/] projects' end
  append(fit(footer, math.max(12, window_width - 2)), 'AgentBoardFooter')
  state.line_map, state.row_offsets, state.project_render, state.highlights = line_map, row_offsets, project_render, highlights
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  if not state.ns then state.ns = vim.api.nvim_create_namespace('AgentBoard') end
  vim.api.nvim_buf_clear_namespace(state.buf, state.ns, 0, -1)
  for line, group in pairs(line_groups) do
    vim.api.nvim_buf_add_highlight(state.buf, state.ns, group, line - 1, 0, -1)
  end
  for _, mark in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(state.buf, state.ns, mark.group, mark.row - 1, mark.first, mark.last)
  end
  if cursor_position and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_set_cursor(state.win, cursor_position)
    vim.api.nvim_win_call(state.win, function() vim.fn.winrestview({ leftcol = 0 }) end)
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
  local rows, warnings, snapshots, projects = api.list_tasks({ scope = state.scope, repo = state.repo })
  if not rows then
    state.error = show_error(warnings)
    render(state)
    return nil, warnings
  end
  state.error = nil
  state.rows, state.warnings, state.snapshots, state.projects = rows, warnings, snapshots, projects
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
  if not item then state.selected = nil end
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
    snacks = { win = { input = { keys = { ['<Esc>'] = { 'close', mode = { 'i', 'n' } } } } } },
  }, callback)
end

local function prompt_title(callback, title)
  vim.ui.input({ prompt = title and 'Rename task: ' or 'New task: ', default = title }, callback)
end

local function refresh_after(state, value, err)
  if err then return notify(show_error(err)) end
  if value and current(state) then M.refresh() end
end

local function create_task(state, repo, expected_snapshot, status)
  prompt_title(function(title)
    if not title or title:match('^%s*$') then return end
    local created, err = api.create_task({ repo = repo, title = title, status = status }, expected_snapshot)
    if not created then return notify(show_error(err)) end
    state.selected = ref_key(repo, created.id)
    M.refresh()
  end)
end

local function choose_repo(state, callback, snapshots)
  snapshots = snapshots or state.snapshots or {}
  local repos = vim.tbl_keys(snapshots)
  table.sort(repos)
  choose(repos, 'Choose repository:', callback)
end

local focused_project, focused_lane

local function action_create(state)
  local snapshots = state.snapshots or {}
  if state.scope == 'repo' then return create_task(state, state.repo, snapshots[state.repo]) end
  choose_repo(state, function(repo)
    if repo then create_task(state, repo, snapshots[repo]) end
  end, snapshots)
end

local function action_rename(state)
  local ref, item = selected_ref(state)
  if not item then return end
  local expected_snapshot = state.snapshots[ref.repo]
  prompt_title(function(title)
    if not title or title:match('^%s*$') then return end
    local updated, err = api.update_task(ref, { title = title }, expected_snapshot)
    if not updated then return notify(show_error(err)) end
    state.selected = ref_key(ref.repo, ref.id)
    M.refresh()
  end, item.task.title)
end

local function action_cut(state)
  local ref, item = selected_ref(state)
  if not ref then return end
  state.cut = {
    ref = ref,
    snapshot = vim.deepcopy(state.snapshots[ref.repo]),
    title = item.task.title,
  }
  M.refresh()
end

local function action_cancel_cut(state)
  if not state.cut then return end
  state.cut = nil
  M.refresh()
end

local function action_move(state, status, ref, expected_snapshot)
  if not ref then
    ref = selected_ref(state)
    if ref then expected_snapshot = state.snapshots[ref.repo] end
  end
  if not ref then return end
  local moved, err = api.move_task(ref, status, expected_snapshot)
  if not moved then return notify(show_error(err)) end
  state.selected = ref_key(ref.repo, ref.id)
  M.refresh()
end

local function action_paste(state)
  local cut = state.cut
  if not cut then return end
  local project, lane = focused_project(state), focused_lane(state)
  if not project or not lane then return end
  if project.repo ~= cut.ref.repo then return notify('cannot move a task to another repository') end
  if not vim.deep_equal(cut.snapshot, state.snapshots[cut.ref.repo]) then
    return notify('board changed; cancel cut and try again')
  end
  local task = api.get_task(cut.ref)
  if not task then return notify('task changed or no longer exists; cancel cut') end
  if task.status == lane.id then
    state.cut = nil
    state.selected = ref_key(cut.ref.repo, cut.ref.id)
    return M.refresh()
  end
  local moved, err = api.move_task(cut.ref, lane.id, cut.snapshot)
  if not moved then return notify(show_error(err)) end
  state.cut = nil
  state.selected = ref_key(cut.ref.repo, cut.ref.id)
  M.refresh()
end

local function action_choose_status(state)
  local ref = selected_ref(state)
  if not ref then return end
  local expected_snapshot = state.snapshots[ref.repo]
  local project
  for _, candidate in ipairs(state.projects or {}) do
    if candidate.repo == ref.repo then project = candidate; break end
  end
  if not project then return notify('repository lanes are unavailable') end
  choose(project.lanes, 'Move task to:', function(lane)
    if lane then action_move(state, lane.id, ref, expected_snapshot) end
  end, function(lane) return lane.name end)
end

focused_project = function(state)
  return state.projects and state.projects[state.focus_project]
end

focused_lane = function(state)
  local project = focused_project(state)
  if not project then return nil end
  return project.lanes[state.lane_focus[project.repo] or 1]
end

local function action_add_lane(state)
  local project = focused_project(state)
  if not project then return end
  vim.ui.input({ prompt = 'New lane: ' }, function(name)
    if not name or name:match('^%s*$') then return end
    local lane, err = api.add_lane(project.repo, name, state.snapshots[project.repo])
    if not lane then return notify(show_error(err)) end
    state.selected = nil
    state.lane_focus[project.repo] = #project.lanes + 1
    M.refresh()
  end)
end

local function action_rename_lane(state)
  local project, lane = focused_project(state), focused_lane(state)
  if not project or not lane then return end
  vim.ui.input({ prompt = 'Rename lane: ', default = lane.name }, function(name)
    if not name or name:match('^%s*$') then return end
    local renamed, err = api.rename_lane(project.repo, lane.id, name, state.snapshots[project.repo])
    if not renamed then return notify(show_error(err)) end
    M.refresh()
  end)
end

local function action_start(state)
  local ref, item = selected_ref(state)
  if not ref then return end
  local expected_snapshot = state.snapshots[ref.repo]
  if has_agent(item.task.conversation) then
    return api.open_agent(ref, function(value, err) refresh_after(state, value, err) end, {tabpage=state.tab,label=item.task.title})
  end
  choose({ 'claude', 'codex', 'pi' }, 'Start agent with:', function(provider)
    if not provider or not current(state) then return end
    api.start_agent(ref, { provider = provider, expected_snapshot = expected_snapshot, terminal_opts = {tabpage=state.tab,label=item.task.title} }, function(value, err)
      refresh_after(state, value, err)
      if value and not value.existing and has_agent(value.agent) and visible(state) then
        api.open_agent(ref, value.agent, function(_, open_error)
          if open_error then notify(show_error(open_error)) end
        end, {tabpage=state.tab,label=item.task.title})
      end
    end)
  end)
end

local function action_bind(state)
  local ref, item = selected_ref(state)
  if not ref then return end
  local expected_snapshot = state.snapshots[ref.repo]
  if has_agent(item.task.conversation) then return notify('task already has a linked session') end
  api.list_sessions(ref, function(discovery, err)
    if not current(state) then return end
    if not discovery then return notify(show_error(err)) end
    for _, warning in ipairs(discovery.warnings) do notify(warning) end
    if discovery.runtime_error then notify('Herdr runtime unknown; opening requires a successful runtime check') end
    if #discovery.sessions==0 then return notify('nothing to select') end
    session_picker.open(discovery.sessions, {prompt='Link session:',format_item=function(session)
      local provider = session.conversation and session.conversation.provider or session.agent.identity.provider
      return table.concat({provider, session.title, session.updated_at or '', session.state,
        session.bound and ('already linked: ' .. session.bound_title) or (session.reason or '')}, ' · ')
    end}, function(session)
      if not session or not current(state) then return end
      if session.bound then return notify('this session is already linked to a task') end
      if session.state == 'unavailable' or session.ambiguous then return notify(session.reason or 'Session unavailable') end
      local callback = function(value, bind_error) refresh_after(state, value, bind_error) end
      if session.conversation then
        api.bind_conversation(ref, session.conversation, expected_snapshot, callback)
      elseif session.agent then
        api.bind_agent(ref, session.agent.identity, expected_snapshot, callback)
      end
    end)
  end)
end

local function action_open(state)
  local ref, item = selected_ref(state)
  if not item then
    local project, lane = focused_project(state), focused_lane(state)
    if project and lane then return create_task(state, project.repo, state.snapshots[project.repo], lane.id) end
    return action_create(state)
  end
  if not (has_agent(item.task.agent) or has_agent(item.task.conversation)) then return action_start(state) end
  api.open_agent(ref, item.task.agent, function(_, err)
    if err then notify(show_error(err)) end
  end, {tabpage=state.tab,label=item.task.title})
end

local function action_send(state)
  local ref, item = selected_ref(state)
  if not item or not (has_agent(item.task.agent) or has_agent(item.task.conversation)) then return end
  vim.ui.input({ prompt = 'Prompt: ' }, function(message)
    if not message or message == '' then return end
    api.send(ref, message, item.task.agent, function(_, err)
      if err then notify(show_error(err)) end
    end)
  end)
end

local function confirm(state, prompt, label, callback)
  choose({ 'Cancel', label }, prompt, function(choice)
    if choice == label then callback() end
  end)
end

local function action_delete(state)
  local ref, item = selected_ref(state)
  if not item then return end
  local expected_snapshot = state.snapshots[ref.repo]
  confirm(state, 'Delete task and link? Claude history and running agent are kept.', 'Delete', function()
    local deleted, err = api.delete_task(ref, expected_snapshot)
    if not deleted then return notify(show_error(err)) end
    state.selected = nil
    M.refresh()
  end)
end

local function action_stop(state)
  local ref, item = selected_ref(state)
  if not item or not (has_agent(item.task.agent) or has_agent(item.task.conversation)) then return end
  confirm(state, 'Stop runtime? Conversation history and task status are kept.', 'Stop', function()
    api.stop_agent(ref, item.task.agent, function(_, err)
      if err then return notify(show_error(err)) end
      M.refresh()
    end)
  end)
end

local function action_menu(state)
  local _, item = selected_ref(state)
  local project, lane = focused_project(state), focused_lane(state)
  local selected = state.selected
  local snapshot = project and vim.deepcopy(state.snapshots[project.repo])
  local linked = item and (has_agent(item.task.agent) or has_agent(item.task.conversation))
  local actions = {
    { label = item and (linked and 'Open / resume session' or 'Start session') or 'New task in this lane', run = action_open },
  }
  if item then
    actions[#actions + 1] = { label = 'Cut task', run = action_cut }
    actions[#actions + 1] = { label = 'Rename task', run = action_rename }
    actions[#actions + 1] = { label = 'Move task', run = action_choose_status }
    if linked then
      actions[#actions + 1] = { label = 'Send prompt', run = action_send }
      actions[#actions + 1] = { label = 'Stop runtime…', run = action_stop }
    else
      actions[#actions + 1] = { label = 'Link existing session', run = action_bind }
    end
    actions[#actions + 1] = { label = 'Delete task…', run = action_delete }
  end
  actions[#actions + 1] = { label = 'Add lane', run = action_add_lane }
  actions[#actions + 1] = { label = 'Rename lane', run = action_rename_lane }
  choose(actions, 'Actions:', function(action)
    if not action or not current(state) then return end
    local current_project, current_lane = focused_project(state), focused_lane(state)
    if state.selected ~= selected or not project or not lane or not current_project or not current_lane
      or current_project.repo ~= project.repo or current_lane.id ~= lane.id
      or not vim.deep_equal(snapshot, state.snapshots[project.repo]) then
      return notify('board changed; reopen actions')
    end
    action.run(state)
  end, function(action) return action.label end)
end

local function switch_view(state, scope, repo)
  state.scope, state.repo = scope, repo
  if scope == 'repo' then state.focus_project = 1 end
  state.selected = nil
  state.focus_index = 0
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
  if current(state) then render(state) end
end

local function sync_focus(state)
  local item = current_item(state)
  if not item then return end
  for project_index, project in ipairs(state.project_views or {}) do
    if project.project.repo == item.repo then
      for lane_index, lane in ipairs(project.lanes) do
        for index, row in ipairs(lane.rows) do
          if row.task.id == item.task.id then
            state.focus_project = project_index
            state.lane_focus[item.repo] = lane_index
            state.focus_index = index
            return
          end
        end
      end
    end
  end
end

local function move_lane(state, delta)
  sync_focus(state)
  local project = state.project_views[state.focus_project]
  if not project then return end
  local lane_index = state.lane_focus[project.project.repo] or 1
  lane_index = math.max(1, math.min(#project.lanes, lane_index + delta))
  state.lane_focus[project.project.repo] = lane_index
  local rows = project.lanes[lane_index] and project.lanes[lane_index].rows or {}
  state.focus_index = #rows > 0 and 1 or 0
  state.selected = rows[1] and ref_key(rows[1].repo, rows[1].task.id) or nil
  set_cursor(state)
end

local function move_card(state, delta)
  sync_focus(state)
  local project = state.project_views[state.focus_project]
  if not project then return end
  local lane = project.lanes[state.lane_focus[project.project.repo] or 1]
  local rows = lane and lane.rows or {}
  local count = #rows
  if count == 0 then state.focus_index = 0; return set_cursor(state) end
  state.focus_index = math.max(1, math.min(count, (state.focus_index or 1) + delta))
  local item = rows[state.focus_index]
  state.selected = ref_key(item.repo, item.task.id)
  set_cursor(state)
end

local function move_project(state, delta)
  if state.scope ~= 'global' or #state.project_views == 0 then return end
  sync_focus(state)
  local project_index = math.max(1, math.min(#state.project_views, state.focus_project + delta))
  state.focus_project = project_index
  local project = state.project_views[project_index]
  local lane_index = math.max(1, math.min(#project.lanes, state.lane_focus[project.project.repo] or 1))
  state.lane_focus[project.project.repo] = lane_index
  local rows = project.lanes[lane_index] and project.lanes[lane_index].rows or {}
  state.focus_index = #rows > 0 and 1 or 0
  state.selected = rows[1] and ref_key(rows[1].repo, rows[1].task.id) or nil
  set_cursor(state)
end

close_help = function(state)
  if state.help_win and vim.api.nvim_win_is_valid(state.help_win) then
    pcall(vim.api.nvim_win_close, state.help_win, true)
  end
  state.help_win = nil
  state.help_buf = nil
end

local function help_layout()
  local help = {
    'AgentBoard shortcuts',
    'a / n  create task',
    'r  rename task         R  rename focused lane',
    '+  add lane',
    'm  move task            d  move to the built-in Done lane',
    'Tab / Shift-Tab or h/l / ←/→  move between lanes',
    'j/k or ↓/↑  move between tasks',
    '[/]  previous/next project in global view',
    'Enter  open or resume session; choose a provider when unlinked',
    'Enter on an empty lane  create a task in that lane',
    'Space  show actions for the selected task / lane',
    'b  link a running agent or saved provider session',
    'x  cut task              p  paste into the focused lane',
    'X / Esc  cancel cut      Delete  delete task',
    's  stop runtime          g  switch board scope',
    'Space actions also include send prompt and delete',
    'Ctrl-\\ Ctrl-n then q hides the terminal; runtime keeps running',
    'Starting or resuming an agent keeps the current lane.',
    'Esc closes help, then cancels cut, then closes the board.',
  }
  if vim.o.columns < 80 then
    help = {
      'a/n  create task; Enter  open or start session',
      'Enter on empty lane  create task',
      'r  rename task; R  rename lane; +  add lane',
      'm  move task; d  move to Done',
      'Tab/Shift-Tab, h/l, ←/→  move between lanes',
      'j/k, ↓/↑  move between tasks',
      '[/]  previous/next project; g  switch scope',
      'b  link a running agent or saved session',
      'x  cut; p  paste into focused lane; X  cancel',
      'Delete  delete task; s  stop runtime',
      'Space  actions; menu includes send prompt/delete',
      'Ctrl-\\ Ctrl-n, then q  hide terminal; runtime stays',
      'Starting or resuming keeps the current lane.',
      'Esc closes help, then cancels cut, then closes board.',
    }
  end
  local width = math.max(1, math.min(78, vim.o.columns - 2))
  local content_height = 0
  for _, line in ipairs(help) do
    content_height = content_height + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
  end
  local height = math.min(content_height, math.max(1, vim.o.lines - 4))
  return help, {
    relative = 'editor',
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
    width = width,
    height = height,
    border = 'rounded',
    title = ' AgentBoard help ',
    title_pos = 'center',
    style = 'minimal',
    focusable = false,
  }
end

local function configure_help_window(win)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].winblend = 0
  vim.wo[win].winhighlight = 'Normal:NormalFloat,FloatBorder:FloatBorder'
end

local function layout_help(state)
  if not state.help_win or not vim.api.nvim_win_is_valid(state.help_win)
    or not state.help_buf or not vim.api.nvim_buf_is_valid(state.help_buf) then
    return
  end
  local help, config = help_layout()
  vim.bo[state.help_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.help_buf, 0, -1, false, help)
  vim.bo[state.help_buf].modifiable = false
  vim.api.nvim_win_set_config(state.help_win, config)
  configure_help_window(state.help_win)
end

local function toggle_help(state)
  if state.help_win and vim.api.nvim_win_is_valid(state.help_win) then return close_help(state) end
  local help, config = help_layout()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, help)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].modifiable = false
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'agentboard-help'
  state.help_buf = buf
  state.help_win = vim.api.nvim_open_win(buf, false, config)
  configure_help_window(state.help_win)
end

local function map(state, key, callback)
  vim.keymap.set('n', key, function()
    if current(state) then callback(state) end
  end, { buffer = state.buf, silent = true, nowait = true })
end

local function install_mappings(state)
  map(state, 'n', action_create)
  map(state, '+', action_add_lane)
  map(state, 'r', function(s)
    if current_item(s) then action_rename(s) else action_rename_lane(s) end
  end)
  map(state, 'R', action_rename_lane)
  map(state, 'm', action_choose_status)
  map(state, 'd', function(s) action_move(s, 'done') end)
  map(state, 'a', action_create)
  map(state, 'b', action_bind)
  map(state, '<CR>', action_open)
  map(state, '<Space>', action_menu)
  map(state, 'p', action_paste)
  map(state, 'x', action_cut)
  map(state, 'X', action_cancel_cut)
  map(state, '<Delete>', action_delete)
  map(state, 's', action_stop)
  map(state, 'h', function(s) move_lane(s, -1) end)
  map(state, 'l', function(s) move_lane(s, 1) end)
  map(state, 'j', function(s) move_card(s, 1) end)
  map(state, 'k', function(s) move_card(s, -1) end)
  for key, delta in pairs({ ['<Left>'] = -1, ['<Right>'] = 1, ['<S-Tab>'] = -1, ['<Tab>'] = 1 }) do
    map(state, key, function(s) move_lane(s, delta) end)
  end
  for key, delta in pairs({ ['<Up>'] = -1, ['<Down>'] = 1 }) do
    map(state, key, function(s) move_card(s, delta) end)
  end
  map(state, '[', function(s) move_project(s, -1) end)
  map(state, ']', function(s) move_project(s, 1) end)
  map(state, 'g', action_scope)
  map(state, '?', toggle_help)
  map(state, '<Esc>', function(s)
    if s.help_win then close_help(s) elseif s.cut then action_cancel_cut(s) else M.close() end
  end)
  map(state, 'q', function(s) if s.help_win then close_help(s) else M.close() end end)
end

local function configure_buffer(state)
  local buf, win = state.buf, state.win
  vim.api.nvim_set_hl(0, 'AgentBoardTitle', { default = true, link = 'Title' })
  vim.api.nvim_set_hl(0, 'AgentBoardProject', { default = true, link = 'Directory' })
  vim.api.nvim_set_hl(0, 'AgentBoardLane', { default = true, link = 'Comment' })
  vim.api.nvim_set_hl(0, 'AgentBoardLaneBorder', { default = true, link = 'Comment' })
  vim.api.nvim_set_hl(0, 'AgentBoardLaneFocus', { default = true, link = 'DiagnosticInfo' })
  vim.api.nvim_set_hl(0, 'AgentBoardCard', { default = true, link = 'Normal' })
  vim.api.nvim_set_hl(0, 'AgentBoardSelected', { default = true, link = 'Visual' })
  vim.api.nvim_set_hl(0, 'AgentBoardFooter', { default = true, link = 'Comment' })
  vim.b[buf].agent_board = true
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false
  vim.wo[win].cursorcolumn = false
  vim.wo[win].colorcolumn = ''
  vim.wo[win].sidescrolloff = 0
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].fillchars = 'eob: '
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
  vim.api.nvim_create_autocmd({ 'VimResized', 'WinResized' }, {
    group = state.group,
    callback = function()
      layout_help(state)
      if visible(state) then M.refresh() end
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
          if agent.identity.provider == 'claude' and not require('agent-board.claude').valid_id(agent.identity.session_id) then
            state.native_unknown = true
          elseif type(agent.identity.session_id) == 'string' and agent.identity.session_id ~= '' then
            state.native_states[agent.identity.provider .. '\0' .. agent.identity.session_id] = 'running'
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
    focus_project = 1,
    lane_focus = {},
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
