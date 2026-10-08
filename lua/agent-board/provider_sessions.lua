local uv = vim.uv
local M = {}

local function base_dir(variable, fallback)
  local value = vim.env[variable]
  if not value or value == '' then value = vim.fn.expand(fallback) end
  return vim.fs.normalize(value)
end

local function worktree_roots(repo)
  local result = vim.system({ 'git', '-C', repo, 'worktree', 'list', '--porcelain' }, { text = true }):wait()
  local roots = { repo }
  if result.code == 0 then
    for path in (result.stdout or ''):gmatch('worktree ([^\n]+)') do
      roots[#roots + 1] = vim.fs.normalize(path)
    end
  end
  return roots
end

local function belongs_to(cwd, roots)
  if type(cwd) ~= 'string' or cwd:sub(1, 1) ~= '/' then return false end
  cwd = vim.fs.normalize(cwd)
  for _, root in ipairs(roots) do
    if cwd == root or cwd:sub(1, #root + 1) == root .. '/' then return true end
  end
  return false
end

local function files_under(path)
  local files = vim.fn.glob(path .. '/**/*.jsonl', false, true)
  if type(files) ~= 'table' then return {} end
  table.sort(files)
  return files
end

local function codex_titles(base)
  local titles = {}
  local file = io.open(base .. '/session_index.jsonl', 'r')
  if not file then return titles end
  for line in file:lines() do
    local ok, row = pcall(vim.json.decode, line)
    if ok and type(row) == 'table' and type(row.id) == 'string' then
      titles[row.id] = { title = row.thread_name, updated_at = row.updated_at }
    end
  end
  file:close()
  return titles
end

local function read_prefix(path, bytes)
  local file = io.open(path, 'r')
  if not file then return nil end
  local data = file:read(bytes or 65536)
  file:close()
  return data
end

local function first_line(data)
  return data and data:match('^([^\n]*)') or nil
end

local function codex_records(repo, roots)
  local base = base_dir('CODEX_HOME', '~/.codex')
  local titles = codex_titles(base)
  local result = {}
  local files = files_under(base .. '/sessions')
  for index, path in ipairs(files) do
    if index > 4096 then break end
    local line = first_line(read_prefix(path))
    if line then
      local ok, entry = pcall(vim.json.decode, line)
      local payload = ok and type(entry) == 'table' and entry.type == 'session_meta' and entry.payload
      if type(payload) == 'table' and type(payload.id) == 'string' and belongs_to(payload.cwd, roots) then
        local title = titles[payload.id] or {}
        result[#result + 1] = {
          conversation = { provider = 'codex', session_id = payload.id, cwd = payload.cwd },
          title = title.title or payload.id,
          updated_at = title.updated_at or payload.timestamp,
        }
      end
    end
  end
  return result, #files > 4096 and { 'Partial Codex session scan: file limit reached' } or {}
end

local function pi_records(repo, roots)
  local agent_dir = base_dir('PI_CODING_AGENT_DIR', '~/.pi/agent')
  local custom_dir = vim.env.PI_CODING_AGENT_SESSION_DIR
  local search = custom_dir and custom_dir ~= ''
    and vim.fs.normalize(custom_dir)
    or agent_dir .. '/sessions'
  local result, files = {}, files_under(search)
  for index, path in ipairs(files) do
    if index > 4096 then break end
    local data = read_prefix(path)
    local line = first_line(data)
    if line then
      local ok, header = pcall(vim.json.decode, line)
      if ok and type(header) == 'table' and header.type == 'session'
        and type(header.id) == 'string' and belongs_to(header.cwd, roots) then
        local title = header.id
        if data then
          local row_index = 0
          for metadata in data:gmatch('[^\n]+') do
            row_index = row_index + 1
            if row_index > 1 then
              local valid, entry = pcall(vim.json.decode, metadata)
              if valid and type(entry) == 'table' and entry.type == 'session_info'
                and type(entry.name) == 'string' and entry.name ~= '' then title = entry.name end
            end
            if row_index >= 32 then break end
          end
        end
        result[#result + 1] = {
          conversation = { provider = 'pi', session_id = header.id, cwd = header.cwd },
          title = title,
          updated_at = header.timestamp,
        }
      end
    end
  end
  return result, #files > 4096 and { 'Partial Pi session scan: file limit reached' } or {}
end

function M.list(repo)
  local roots = worktree_roots(repo)
  local codex, codex_warnings = codex_records(repo, roots)
  local pi, pi_warnings = pi_records(repo, roots)
  local records, warnings = {}, {}
  vim.list_extend(records, codex)
  vim.list_extend(records, pi)
  vim.list_extend(warnings, codex_warnings)
  vim.list_extend(warnings, pi_warnings)
  table.sort(records, function(left, right) return (left.updated_at or '') > (right.updated_at or '') end)
  return records, warnings
end

function M.resolve(conversation, callback)
  local records = M.list(conversation.cwd)
  for _, record in ipairs(records) do
    if record.conversation.provider == conversation.provider
      and record.conversation.session_id == conversation.session_id then
      return callback(record)
    end
  end
  callback(nil, { code = 'unavailable', message = conversation.provider .. ' session has no saved transcript in this repository' })
end

return M
