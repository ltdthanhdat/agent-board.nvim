local uv = vim.uv
local M = {}

local function failure(message)
  return nil, message
end

local function document_template(kind)
  if kind == 'board' then
    return { version = 1, revision = 0, tasks = {} }
  end
  if kind == 'registry' then
    return { version = 1, revision = 0, repos = {} }
  end
  return nil
end

local function valid_string(value)
  return type(value) == 'string' and value ~= ''
end

local function valid_revision(value)
  return type(value) == 'number' and value >= 0 and value % 1 == 0
end

local function validate_agent(agent)
  if agent == nil or agent == vim.NIL then
    return true
  end
  if type(agent) ~= 'table' then
    return false, 'agent must be an object or null'
  end
  if agent.provider ~= 'claude' and agent.provider ~= 'codex' and agent.provider ~= 'pi' then
    return false, 'agent provider must be claude, codex, or pi'
  end
  if agent.runtime ~= 'herdr' then
    return false, 'agent runtime must be herdr'
  end
  if not valid_string(agent.server) or not valid_string(agent.terminal_id) or not valid_string(agent.pane_id) then
    return false, 'agent server, terminal_id, and pane_id must be non-empty strings'
  end
  if agent.name ~= nil and agent.name ~= vim.NIL and not valid_string(agent.name) then
    return false, 'agent name must be a non-empty string or null'
  end
  if agent.session_id ~= nil and agent.session_id ~= vim.NIL and type(agent.session_id) ~= 'string' then
    return false, 'agent session_id must be a string or null'
  end
  return true
end

local function validate(document, kind)
  if type(document) ~= 'table' or not valid_revision(document.revision) or document.version ~= 1 then
    return false, 'document version or revision is invalid'
  end

  if kind == 'board' then
    if type(document.tasks) ~= 'table' or not vim.islist(document.tasks) then
      return false, 'tasks must be an array'
    end
    local ids = {}
    for _, task in ipairs(document.tasks) do
      if type(task) ~= 'table' or not valid_string(task.id) or not valid_string(task.title) then
        return false, 'each task needs a non-empty id and title'
      end
      if ids[task.id] then
        return false, 'task IDs must be unique'
      end
      ids[task.id] = true
      if task.status ~= 'todo' and task.status ~= 'doing' and task.status ~= 'done' then
        return false, 'task status must be todo, doing, or done'
      end
      local agent_ok, agent_error = validate_agent(task.agent)
      if not agent_ok then
        return false, agent_error
      end
    end
    return true
  end

  if kind == 'registry' then
    if type(document.repos) ~= 'table' or not vim.islist(document.repos) then
      return false, 'repos must be an array'
    end
    for _, repo in ipairs(document.repos) do
      if not valid_string(repo) then
        return false, 'repo paths must be non-empty strings'
      end
    end
    return true
  end
  return false, 'kind must be board or registry'
end

local function read_raw(path)
  local stat, stat_error, code = uv.fs_stat(path)
  if not stat then
    if code == 'ENOENT' then
      return nil, true
    end
    return nil, false, stat_error
  end
  if stat.type ~= 'file' then
    return nil, false, 'path is not a regular file: ' .. path
  end

  local file, open_error = io.open(path, 'rb')
  if not file then
    return nil, false, open_error
  end
  local data, read_error = file:read('*a')
  local closed, close_error = file:close()
  if not data then
    return nil, false, read_error
  end
  if not closed then
    return nil, false, close_error
  end
  return data, false
end

function M.read(path, kind)
  local template = document_template(kind)
  if not template then
    return failure('kind must be board or registry')
  end

  local data, missing, read_error = read_raw(path)
  if read_error then
    return failure(read_error)
  end
  if missing then
    return template, { data = nil, kind = kind, revision = 0 }
  end

  local ok, document = pcall(vim.json.decode, data)
  if not ok then
    return failure('invalid JSON in ' .. path .. ': ' .. tostring(document))
  end
  local valid, validation_error = validate(document, kind)
  if not valid then
    return failure('invalid ' .. kind .. ' in ' .. path .. ': ' .. validation_error)
  end
  return document, { data = data, kind = kind, revision = document.revision }
end

local function parent_directory(path)
  return vim.fn.fnamemodify(path, ':h')
end

function M.lock(path)
  local parent = parent_directory(path)
  if vim.fn.mkdir(parent, 'p') == 0 and not uv.fs_stat(parent) then
    return failure('cannot create lock directory: ' .. parent)
  end

  local lock_path = path .. '.lock'
  local fd, open_error = uv.fs_open(lock_path, 'wx', 384)
  if not fd then
    return failure('cannot acquire lock ' .. lock_path .. ': ' .. tostring(open_error))
  end
  local payload = tostring(uv.os_getpid()) .. '\n'
  local written, write_error = uv.fs_write(fd, payload, 0)
  local closed, close_error = uv.fs_close(fd)
  if not written or not closed then
    uv.fs_unlink(lock_path)
    return failure('cannot initialize lock: ' .. tostring(write_error or close_error))
  end

  local released = false
  return function()
    if released then
      return
    end
    released = true
    local ok_unlink, unlink_error = uv.fs_unlink(lock_path)
    if not ok_unlink then
      vim.notify('agent-board: cannot release lock ' .. lock_path .. ': ' .. tostring(unlink_error), vim.log.levels.ERROR)
    end
  end
end

local function snapshots_match(path, snapshot)
  local current, missing, read_error = read_raw(path)
  if read_error then
    return false, read_error
  end
  if missing then
    return snapshot.data == nil
  end
  return current == snapshot.data
end

local function write_all(fd, data)
  local offset = 0
  while offset < #data do
    local written, write_error = uv.fs_write(fd, data:sub(offset + 1), offset)
    if not written or written == 0 then
      return false, write_error or 'write made no progress'
    end
    offset = offset + written
  end
  return true
end

function M.write_locked(path, document, snapshot)
  if type(snapshot) ~= 'table' or not document_template(snapshot.kind) then
    return failure('a snapshot from storage.read is required')
  end
  local valid, validation_error = validate(document, snapshot.kind)
  if not valid then
    return failure(validation_error)
  end
  if document.revision ~= snapshot.revision + 1 then
    return failure('revision must increase by one')
  end

  local matches, compare_error = snapshots_match(path, snapshot)
  if not matches then
    return failure(compare_error or 'file changed; reload before saving')
  end

  local ok_encode, data = pcall(vim.json.encode, document)
  if not ok_encode then
    return failure('cannot encode document: ' .. tostring(data))
  end

  local temp_path = ('%s.tmp.%d.%d'):format(path, uv.os_getpid(), uv.hrtime())
  local fd, open_error = uv.fs_open(temp_path, 'wx', 384)
  if not fd then
    return failure('cannot create temporary file: ' .. tostring(open_error))
  end

  local ok_write, write_error = write_all(fd, data)
  local closed, close_error = uv.fs_close(fd)
  if not ok_write or not closed then
    uv.fs_unlink(temp_path)
    return failure('cannot write temporary file: ' .. tostring(write_error or close_error))
  end

  local renamed, rename_error = uv.fs_rename(temp_path, path)
  if not renamed then
    uv.fs_unlink(temp_path)
    return failure('cannot replace document: ' .. tostring(rename_error))
  end
  return { data = data, kind = snapshot.kind, revision = document.revision }
end

function M.registry_path()
  return vim.fs.joinpath(vim.fn.stdpath('data'), 'agent-board', 'repos.json')
end

return M
