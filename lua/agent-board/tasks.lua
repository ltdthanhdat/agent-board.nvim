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

local function callback_once(callback)
  local called = false
  return function(...)
    if called then return end
    called = true
    local args = { ... }
    vim.schedule(function() callback(unpack(args)) end)
  end
end

local function runtime_failure(code, message, extra)
  local err = { code = code, message = message }
  for key, value in pairs(extra or {}) do err[key] = value end
  return err
end

local function guarded(tx, done, callback)
  return function(...)
    local args = { ... }
    local ok, callback_error = pcall(callback, unpack(args))
    if not ok then
      tx.release()
      done(nil, runtime_failure('runtime_error', tostring(callback_error)))
    end
  end
end

local function linked(agent)
  return type(agent) == 'table' and agent ~= vim.NIL
end

local function runtime_identity(agent)
  local identity = vim.deepcopy(agent)
  if identity.name == vim.NIL then identity.name = nil end
  if identity.session_id == vim.NIL then identity.session_id = nil end
  return identity
end

local function stored_identity(identity)
  return {
    provider = identity.provider,
    runtime = identity.runtime,
    server = identity.server,
    terminal_id = identity.terminal_id,
    pane_id = identity.pane_id,
    name = identity.name or vim.NIL,
    session_id = identity.session_id or vim.NIL,
  }
end

local function same_agent(left, right)
  return linked(left) and linked(right)
    and left.runtime == right.runtime
    and left.server == right.server
    and left.terminal_id == right.terminal_id
end

local function begin_transaction(ref, expected_snapshot)
  local valid_ref, ref_error = task_ref(ref)
  if not valid_ref then return nil, runtime_failure('invalid_input', ref_error) end
  local root, root_error = M.resolve_repo(ref.repo)
  if not root then return nil, runtime_failure('repo_unavailable', root_error) end

  local path = board_path(root)
  local registry_file = storage.registry_path()
  local releases, lock_error = acquire({ registry_file, path })
  if not releases then return nil, runtime_failure('locked', lock_error) end
  local function release()
    release_all(releases)
    releases = {}
  end

  local registry, registry_snapshot = load_registry()
  if not registry then
    release()
    return nil, runtime_failure('registry_unavailable', registry_snapshot)
  end
  local document, snapshot = storage.read(path, 'board')
  if not document then
    release()
    return nil, runtime_failure('board_unavailable', snapshot)
  end
  if stale(expected_snapshot, snapshot) then
    release()
    return nil, runtime_failure('conflict', 'board changed; reload before saving')
  end
  local index, task = find_task(document, ref.id)
  if not index then
    release()
    return nil, runtime_failure('task_not_found', 'task not found: ' .. ref.id)
  end
  local registry_changed = register_in_document(registry, root)
  return {
    root = root,
    registry = registry,
    registry_snapshot = registry_snapshot,
    registry_changed = registry_changed,
    document = document,
    snapshot = snapshot,
    task = task,
    release = release,
    commit = function()
      return save_changes(root, registry, registry_snapshot, document, snapshot, registry_changed)
    end,
  }
end

local function unique_agent(tx, identity)
  for _, registered_root in ipairs(tx.registry.repos) do
    local root, root_error = M.resolve_repo(registered_root)
    if not root then
      return nil, runtime_failure('board_unavailable', 'registered repo is unavailable: ' .. tostring(root_error))
    end
    if root ~= registered_root then
      return nil, runtime_failure('board_unavailable', 'registered repo root changed: ' .. registered_root)
    end
    local document
    if root == tx.root then
      document = tx.document
    else
      local read_error
      document, read_error = storage.read(board_path(root), 'board')
      if not document then
        return nil, runtime_failure('board_unavailable', tostring(read_error))
      end
    end
    for _, other in ipairs(document.tasks) do
      if (root ~= tx.root or other.id ~= tx.task.id) and same_agent(other.agent, identity) then
        return nil, runtime_failure('already_bound', 'this Herdr session is already linked to a task')
      end
    end
  end
  return true
end

local function terminal_key(repo, id)
  return table.concat({ repo, id, 'herdr' }, '\0')
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

function M.bind_agent(ref, identity, expected_snapshot, callback)
  if type(expected_snapshot) == 'function' then
    callback, expected_snapshot = expected_snapshot, nil
  end
  if type(callback) ~= 'function' then return nil, 'a callback is required' end
  local done = callback_once(callback)
  local tx, tx_error = begin_transaction(ref, expected_snapshot)
  if not tx then return done(nil, tx_error) end
  local herdr = require('agent-board.herdr')

  local on_candidate = guarded(tx, done, function(live, resolve_error)
    if not live then
      tx.release()
      return done(nil, resolve_error or runtime_failure('runtime_unavailable', 'could not verify Herdr agent'))
    end
    local unique, unique_error = unique_agent(tx, live.identity)
    if not unique then
      tx.release()
      return done(nil, unique_error)
    end
    tx.task.agent = stored_identity(live.identity)
    local saved, save_error = tx.commit()
    tx.release()
    if not saved then
      return done(nil, runtime_failure('save_failed', tostring(save_error)))
    end
    done(vim.deepcopy(tx.task))
  end)

  local function resolve_candidate()
    local ok, resolve_call_error = pcall(herdr.resolve, identity, on_candidate)
    if not ok then
      tx.release()
      done(nil, runtime_failure('runtime_error', tostring(resolve_call_error)))
    end
  end

  if not linked(tx.task.agent) then return resolve_candidate() end
  local on_existing = guarded(tx, done, function(existing, existing_error)
    if existing then
      tx.release()
      return done(nil, runtime_failure('already_linked', 'task already has a live linked agent'))
    end
    if not existing_error or existing_error.code ~= 'offline' then
      tx.release()
      return done(nil, existing_error or runtime_failure('runtime_unavailable', 'could not verify the existing Herdr agent'))
    end
    resolve_candidate()
  end)
  local ok, resolve_call_error = pcall(herdr.resolve, runtime_identity(tx.task.agent), on_existing)
  if not ok then
    tx.release()
    done(nil, runtime_failure('runtime_error', tostring(resolve_call_error)))
  end
end

function M.start_agent(ref, opts, callback)
  if type(callback) ~= 'function' then return nil, 'a callback is required' end
  if type(opts) ~= 'table' or (opts.provider ~= 'claude' and opts.provider ~= 'codex' and opts.provider ~= 'pi') then
    return callback_once(callback)(nil, runtime_failure('invalid_input', 'a supported provider is required'))
  end
  local done = callback_once(callback)
  local tx, tx_error = begin_transaction(ref, opts.expected_snapshot)
  if not tx then return done(nil, tx_error) end
  local herdr = require('agent-board.herdr')

  local function start_new()
    local name = 'ab-' .. vim.fn.sha256(tx.root .. '\0' .. tx.task.id):sub(1, 16)
    local on_started = guarded(tx, done, function(started, start_error)
      if not started then
        tx.release()
        return done(nil, start_error or runtime_failure('runtime_unavailable', 'Herdr could not start the agent'))
      end
      if type(started.identity) ~= 'table' then
        tx.release()
        return done(nil, runtime_failure('runtime_unavailable', 'Herdr start returned no agent identity', { host = started.host }))
      end
      local identity = stored_identity(started.identity)
      local unique, unique_error = unique_agent(tx, identity)
      if not unique then
        tx.release()
        unique_error.agent = identity
        unique_error.host = started.host
        return done(nil, unique_error)
      end
      tx.task.agent = identity
      tx.task.status = 'doing'
      local saved, save_error = tx.commit()
      tx.release()
      if not saved then
        return done(nil, runtime_failure('save_failed', tostring(save_error), { agent = identity, host = started.host }))
      end
      done(vim.deepcopy(tx.task))
    end)
    local ok, start_call_error = pcall(herdr.start, tx.root, opts.provider, name, on_started)
    if not ok then
      tx.release()
      done(nil, runtime_failure('runtime_error', tostring(start_call_error)))
    end
  end

  if not linked(tx.task.agent) then return start_new() end
  local on_resolved = guarded(tx, done, function(live, resolve_error)
    if live then
      tx.release()
      local existing = vim.deepcopy(tx.task)
      existing.existing = true
      return done(existing)
    end
    if resolve_error and resolve_error.code == 'offline' then
      return start_new()
    end
    tx.release()
    done(nil, resolve_error or runtime_failure('runtime_unavailable', 'could not verify linked Herdr agent'))
  end)
  local ok, resolve_call_error = pcall(herdr.resolve, runtime_identity(tx.task.agent), on_resolved)
  if not ok then
    tx.release()
    done(nil, runtime_failure('runtime_error', tostring(resolve_call_error)))
  end
end

local function get_linked_identity(ref, expected_agent)
  local task, task_error = M.get_task(ref)
  if not task then return nil, runtime_failure('task_not_found', task_error) end
  if not linked(task.agent) then return nil, runtime_failure('no_agent', 'task has no linked agent') end
  if expected_agent and not vim.deep_equal(task.agent, expected_agent) then
    return nil, runtime_failure('conflict', 'task agent link changed; reload before acting')
  end
  return task, runtime_identity(task.agent)
end

function M.open_agent(ref, expected_agent, callback)
  if type(expected_agent) == 'function' then callback, expected_agent = expected_agent, nil end
  if type(callback) ~= 'function' then return nil, 'a callback is required' end
  local done = callback_once(callback)
  local task, identity_or_error = get_linked_identity(ref, expected_agent)
  if not task then return done(nil, identity_or_error) end
  local herdr = require('agent-board.herdr')
  herdr.resolve(identity_or_error, function(live, resolve_error)
    if not live then return done(nil, resolve_error) end
    local root, root_error = M.resolve_repo(ref.repo)
    if not root then return done(nil, runtime_failure('repo_unavailable', root_error)) end
    local terminal = require('agent-board.terminal')
    local opened, open_error = terminal.open(terminal_key(root, task.id), live.identity)
    if not opened then return done(nil, open_error) end
    done(live)
  end)
end

function M.hide_agent(ref)
  local valid_ref, ref_error = task_ref(ref)
  if not valid_ref then return error_result(ref_error) end
  local root, root_error = M.resolve_repo(ref.repo)
  if not root then return error_result(root_error) end
  local terminal = require('agent-board.terminal')
  terminal.hide(terminal_key(root, ref.id))
  return true
end

function M.send(ref, message, expected_agent, callback)
  if type(expected_agent) == 'function' then callback, expected_agent = expected_agent, nil end
  if type(callback) ~= 'function' then return nil, 'a callback is required' end
  local done = callback_once(callback)
  local task, identity_or_error = get_linked_identity(ref, expected_agent)
  if not task then return done(nil, identity_or_error) end
  local herdr = require('agent-board.herdr')
  herdr.send(identity_or_error, message, function(value, err)
    done(value, err)
  end)
end

function M.stop_agent(ref, expected_agent, callback)
  if type(expected_agent) == 'function' then callback, expected_agent = expected_agent, nil end
  if type(callback) ~= 'function' then return nil, 'a callback is required' end
  local done = callback_once(callback)
  local task, identity_or_error = get_linked_identity(ref, expected_agent)
  if not task then return done(nil, identity_or_error) end
  local herdr = require('agent-board.herdr')
  herdr.stop(identity_or_error, function(value, err)
    done(value, err)
  end)
end

return M
