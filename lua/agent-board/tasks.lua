local uv = vim.uv
local storage = require('agent-board.storage')
local M = {}
local id_counter = 0

local function error_result(message)
  return nil, message
end

local function trim(value)
  return (value:gsub('^%s+', ''):gsub('%s+$', ''))
end

function M.resolve_repo(path)
  if type(path) ~= 'string' or path == '' then
    return error_result('a repo path is required')
  end
  local real_path, path_error = uv.fs_realpath(path)
  if not real_path then
    return error_result('repo path is unavailable: ' .. tostring(path_error))
  end
  local result = vim.system({ 'git', '-C', real_path, 'rev-parse', '--show-toplevel' }, { text = true }):wait()
  if result.code ~= 0 then
    return error_result('path is not inside a Git repo: ' .. trim(result.stderr or ''))
  end
  local root = trim(result.stdout or '')
  local real_root, root_error = uv.fs_realpath(root)
  if not real_root then
    return error_result('cannot resolve Git repo root: ' .. tostring(root_error))
  end
  return vim.fs.normalize(real_root)
end

local function board_path(repo)
  return vim.fs.joinpath(repo, '.agent-board.json')
end

local function release_all(releases)
  for index = #releases, 1, -1 do
    releases[index]()
  end
end

local function acquire(paths)
  local releases = {}
  for _, path in ipairs(paths) do
    local release, lock_error = storage.lock(path)
    if not release then
      release_all(releases)
      return error_result(lock_error)
    end
    releases[#releases + 1] = release
  end
  return releases
end

local function registered(registry, repo)
  for _, path in ipairs(registry.repos) do
    if path == repo then
      return true
    end
  end
  return false
end

local function load_registry()
  return storage.read(storage.registry_path(), 'registry')
end

local function save_registry(document, snapshot)
  document.revision = snapshot.revision + 1
  return storage.write_locked(storage.registry_path(), document, snapshot)
end

local function with_repo_lock(repo, callback)
  local root, root_error = M.resolve_repo(repo)
  if not root then
    return error_result(root_error)
  end

  local registry_file = storage.registry_path()
  local path = board_path(root)
  local releases, lock_error = acquire({ registry_file, path })
  if not releases then
    return error_result(lock_error)
  end

  local ok, result, extra = pcall(function()
    local registry, registry_snapshot = load_registry()
    if not registry then
      return error_result(registry_snapshot)
    end
    local document, snapshot = storage.read(path, 'board')
    if not document then
      return error_result(snapshot)
    end
    return callback(root, registry, registry_snapshot, document, snapshot)
  end)
  release_all(releases)
  if not ok then
    return error_result(tostring(result))
  end
  return result, extra
end

local function register_in_document(registry, root)
  if registered(registry, root) then
    return false
  end
  registry.repos[#registry.repos + 1] = root
  table.sort(registry.repos)
  return true
end

local function save_changes(root, registry, registry_snapshot, document, snapshot, registry_changed)
  if registry_changed then
    local saved_registry, registry_error = save_registry(registry, registry_snapshot)
    if not saved_registry then
      return error_result(registry_error)
    end
  end
  document.revision = snapshot.revision + 1
  local saved_snapshot, save_error = storage.write_locked(board_path(root), document, snapshot)
  if not saved_snapshot then
    return error_result(save_error)
  end
  return saved_snapshot
end

local function new_id(tasks)
  local used = {}
  for _, task in ipairs(tasks) do
    used[task.id] = true
  end
  repeat
    id_counter = id_counter + 1
    local seed = table.concat({ uv.os_getpid(), uv.hrtime(), id_counter, math.random() }, ':')
    local id = vim.fn.sha256(seed):sub(1, 16)
    if not used[id] then
      return id
    end
  until false
end

local function task_ref(ref)
  if type(ref) ~= 'table' or type(ref.repo) ~= 'string' or ref.repo == '' or type(ref.id) ~= 'string' or ref.id == '' then
    return nil, 'task ref must contain repo and id'
  end
  return ref
end

local function find_task(document, id)
  for index, task in ipairs(document.tasks) do
    if task.id == id then
      return index, task
    end
  end
  return nil
end

local function stale(expected, actual)
  return expected ~= nil and (type(expected) ~= 'table' or expected.data ~= actual.data)
end

function M.register_repo(path)
  local root, root_error = M.resolve_repo(path)
  if not root then
    return error_result(root_error)
  end
  local registry_file = storage.registry_path()
  local releases, lock_error = acquire({ registry_file })
  if not releases then
    return error_result(lock_error)
  end
  local registry, snapshot = load_registry()
  if not registry then
    release_all(releases)
    return error_result(snapshot)
  end
  if register_in_document(registry, root) then
    local saved, save_error = save_registry(registry, snapshot)
    if not saved then
      release_all(releases)
      return error_result(save_error)
    end
  end
  release_all(releases)
  return root
end

function M.list_tasks(opts)
  if type(opts) ~= 'table' then
    return error_result('scope must be repo or global')
  end
  if opts.scope == 'repo' then
    local root, root_error = M.resolve_repo(opts.repo)
    if not root then
      return error_result(root_error)
    end
    local document, snapshot = storage.read(board_path(root), 'board')
    if not document then
      return error_result(snapshot)
    end
    local result = {}
    for _, task in ipairs(document.tasks) do
      result[#result + 1] = { repo = root, task = task }
    end
    return result, {}, { [root] = snapshot }
  end
  if opts.scope ~= 'global' then
    return error_result('scope must be repo or global')
  end

  local registry, registry_error = load_registry()
  if not registry then
    return error_result(registry_error)
  end
  local result, warnings, snapshots = {}, {}, {}
  for _, registered_root in ipairs(registry.repos) do
    local root, root_error = M.resolve_repo(registered_root)
    if not root then
      warnings[#warnings + 1] = { repo = registered_root, error = root_error }
    elseif root ~= registered_root then
      warnings[#warnings + 1] = { repo = registered_root, error = 'repo root changed; re-register it' }
    else
      local document, snapshot = storage.read(board_path(root), 'board')
      if not document then
        return error_result(snapshot)
      end
      snapshots[root] = snapshot
      for _, task in ipairs(document.tasks) do
        result[#result + 1] = { repo = root, task = task }
      end
    end
  end
  return result, warnings, snapshots
end

function M.get_task(ref)
  local valid_ref, ref_error = task_ref(ref)
  if not valid_ref then
    return error_result(ref_error)
  end
  local root, root_error = M.resolve_repo(ref.repo)
  if not root then
    return error_result(root_error)
  end
  local document, read_error = storage.read(board_path(root), 'board')
  if not document then
    return error_result(read_error)
  end
  local _, task = find_task(document, ref.id)
  if not task then
    return error_result('task not found: ' .. ref.id)
  end
  return vim.deepcopy(task)
end

function M.create_task(opts, expected_snapshot)
  if type(opts) ~= 'table' or type(opts.title) ~= 'string' or trim(opts.title) == '' then
    return error_result('task title must be a non-empty string')
  end
  local status = opts.status or 'todo'
  if status ~= 'todo' and status ~= 'doing' and status ~= 'done' then
    return error_result('task status must be todo, doing, or done')
  end
  return with_repo_lock(opts.repo, function(root, registry, registry_snapshot, document, snapshot)
    if stale(expected_snapshot, snapshot) then
      return error_result('board changed; reload before saving')
    end
    local registry_changed = register_in_document(registry, root)
    local created = { id = new_id(document.tasks), title = trim(opts.title), status = status, agent = vim.NIL }
    document.tasks[#document.tasks + 1] = created
    local saved, save_error = save_changes(root, registry, registry_snapshot, document, snapshot, registry_changed)
    if not saved then
      return error_result(save_error)
    end
    return vim.deepcopy(created)
  end)
end

function M.update_task(ref, patch, expected_snapshot)
  local valid_ref, ref_error = task_ref(ref)
  if not valid_ref then
    return error_result(ref_error)
  end
  if type(patch) ~= 'table' or vim.tbl_isempty(patch) then
    return error_result('a non-empty patch is required')
  end
  for key, value in pairs(patch) do
    if key ~= 'title' or type(value) ~= 'string' or trim(value) == '' then
      return error_result('only a non-empty title can be updated')
    end
  end
  return with_repo_lock(ref.repo, function(root, registry, registry_snapshot, document, snapshot)
    if stale(expected_snapshot, snapshot) then
      return error_result('board changed; reload before saving')
    end
    local index, task = find_task(document, ref.id)
    if not index then
      return error_result('task not found: ' .. ref.id)
    end
    task.title = trim(patch.title)
    local saved, save_error = save_changes(root, registry, registry_snapshot, document, snapshot, false)
    if not saved then
      return error_result(save_error)
    end
    return vim.deepcopy(task)
  end)
end

function M.move_task(ref, status, expected_snapshot)
  local valid_ref, ref_error = task_ref(ref)
  if not valid_ref then
    return error_result(ref_error)
  end
  if status ~= 'todo' and status ~= 'doing' and status ~= 'done' then
    return error_result('task status must be todo, doing, or done')
  end
  return with_repo_lock(ref.repo, function(root, registry, registry_snapshot, document, snapshot)
    if stale(expected_snapshot, snapshot) then
      return error_result('board changed; reload before saving')
    end
    local index, task = find_task(document, ref.id)
    if not index then
      return error_result('task not found: ' .. ref.id)
    end
    task.status = status
    local saved, save_error = save_changes(root, registry, registry_snapshot, document, snapshot, false)
    if not saved then
      return error_result(save_error)
    end
    return vim.deepcopy(task)
  end)
end

function M.delete_task(ref, expected_snapshot)
  local valid_ref, ref_error = task_ref(ref)
  if not valid_ref then
    return error_result(ref_error)
  end
  return with_repo_lock(ref.repo, function(root, registry, registry_snapshot, document, snapshot)
    if stale(expected_snapshot, snapshot) then
      return error_result('board changed; reload before saving')
    end
    local index = find_task(document, ref.id)
    if not index then
      return error_result('task not found: ' .. ref.id)
    end
    table.remove(document.tasks, index)
    local saved, save_error = save_changes(root, registry, registry_snapshot, document, snapshot, false)
    if not saved then
      return error_result(save_error)
    end
    return true
  end)
end

return M
