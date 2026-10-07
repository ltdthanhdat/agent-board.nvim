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
      local saved, save_error = save_changes(root, registry, registry_snapshot, document, snapshot, registry_changed)
      if saved then
        snapshot = saved
        registry_changed = false
      end
      return saved, save_error
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
    return result, {}, { [root] = snapshot }, { { repo = root, lanes = vim.deepcopy(document.lanes) } }
  end
  if opts.scope ~= 'global' then
    return error_result('scope must be repo or global')
  end

  local registry, registry_error = load_registry()
  if not registry then
    return error_result(registry_error)
  end
  local result, warnings, snapshots, projects = {}, {}, {}, {}
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
      projects[#projects + 1] = { repo = root, lanes = vim.deepcopy(document.lanes) }
      for _, task in ipairs(document.tasks) do
        result[#result + 1] = { repo = root, task = task }
      end
    end
  end
  return result, warnings, snapshots, projects
end

function M.list_lanes(repo)
  local root, root_error = M.resolve_repo(repo)
  if not root then return error_result(root_error) end
  local document, read_error = storage.read(board_path(root), 'board')
  if not document then return error_result(read_error) end
  return vim.deepcopy(document.lanes)
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
  return with_repo_lock(opts.repo, function(root, registry, registry_snapshot, document, snapshot)
    if stale(expected_snapshot, snapshot) then
      return error_result('board changed; reload before saving')
    end
    local status = opts.status or document.lanes[1].id
    local valid_status = false
    for _, lane in ipairs(document.lanes) do
      if lane.id == status then valid_status = true; break end
    end
    if not valid_status then return error_result('task status must reference a lane in this repository') end
    local registry_changed = register_in_document(registry, root)
    local created = { id = new_id(document.tasks), title = trim(opts.title), status = status, agent = vim.NIL, conversation = vim.NIL }
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
  return with_repo_lock(ref.repo, function(root, registry, registry_snapshot, document, snapshot)
    if stale(expected_snapshot, snapshot) then
      return error_result('board changed; reload before saving')
    end
    local valid_status = false
    for _, lane in ipairs(document.lanes) do
      if lane.id == status then valid_status = true; break end
    end
    if not valid_status then return error_result('task status must reference a lane in this repository') end
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

function M.add_lane(repo, name, expected_snapshot)
  if type(name) ~= 'string' or trim(name) == '' then
    return error_result('lane name must be a non-empty string')
  end
  name = trim(name)
  return with_repo_lock(repo, function(root, registry, registry_snapshot, document, snapshot)
    if stale(expected_snapshot, snapshot) then
      return error_result('board changed; reload before saving')
    end
    for _, lane in ipairs(document.lanes) do
      if trim(lane.name) == name then return error_result('lane name already exists') end
    end
    local lane = { id = new_id(document.lanes), name = name }
    document.lanes[#document.lanes + 1] = lane
    local registry_changed = register_in_document(registry, root)
    local saved, save_error = save_changes(root, registry, registry_snapshot, document, snapshot, registry_changed)
    if not saved then return error_result(save_error) end
    return vim.deepcopy(lane)
  end)
end

function M.rename_lane(repo, lane_id, name, expected_snapshot)
  if type(lane_id) ~= 'string' or lane_id == '' then
    return error_result('lane ID must be a non-empty string')
  end
  if type(name) ~= 'string' or trim(name) == '' then
    return error_result('lane name must be a non-empty string')
  end
  name = trim(name)
  return with_repo_lock(repo, function(root, registry, registry_snapshot, document, snapshot)
    if stale(expected_snapshot, snapshot) then
      return error_result('board changed; reload before saving')
    end
    local selected
    for _, lane in ipairs(document.lanes) do
      if lane.id == lane_id then selected = lane; break end
    end
    if not selected then return error_result('lane not found: ' .. lane_id) end
    for _, lane in ipairs(document.lanes) do
      if lane.id ~= lane_id and trim(lane.name) == name then return error_result('lane name already exists') end
    end
    selected.name = name
    local registry_changed = register_in_document(registry, root)
    local saved, save_error = save_changes(root, registry, registry_snapshot, document, snapshot, registry_changed)
    if not saved then return error_result(save_error) end
    return vim.deepcopy(selected)
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

local unique_conversation

function M.bind_agent(ref, identity, expected_snapshot, callback)
  if type(expected_snapshot) == 'function' then
    callback, expected_snapshot = expected_snapshot, nil
  end
  if type(callback) ~= 'function' then return nil, 'a callback is required' end
  local done = callback_once(callback)
  local tx, tx_error = begin_transaction(ref, expected_snapshot)
  if not tx then return done(nil, tx_error) end
  if linked(tx.task.agent) or linked(tx.task.conversation) then
    tx.release()
    return done(nil, runtime_failure('already_linked', 'task already has a linked agent'))
  end

  local herdr = require('agent-board.herdr')
  local on_resolved = guarded(tx, done, function(live, resolve_error)
    if not live then
      tx.release()
      return done(nil, resolve_error or runtime_failure('runtime_unavailable', 'could not verify Herdr agent'))
    end
    local unique, unique_error = unique_agent(tx, live.identity)
    if not unique then
      tx.release()
      return done(nil, unique_error)
    end
    local function save_binding(conversation)
      if conversation then
        local available, duplicate_error = unique_conversation(tx, conversation)
        if not available then tx.release();return done(nil, duplicate_error) end
        tx.task.conversation = vim.deepcopy(conversation)
      end
      tx.task.agent = stored_identity(live.identity)
      local saved, save_error = tx.commit()
      tx.release()
      if not saved then return done(nil, runtime_failure('save_failed', tostring(save_error))) end
      done(vim.deepcopy(tx.task))
    end
    local claude = require('agent-board.claude')
    if live.identity.provider == 'claude' and claude.valid_id(live.identity.session_id) then
      return require('agent-board.sessions').list(tx.root,guarded(tx,done,function(discovery)
        for _,row in ipairs(discovery.sessions) do
          if row.conversation and row.conversation.session_id==live.identity.session_id and row.agent
            and row.agent.identity.terminal_id==live.identity.terminal_id then return save_binding(row.conversation) end
        end
        tx.release()
        done(nil,runtime_failure('session_identity_unverified','Herdr could not verify the live Claude session in this repository',{agent=live.identity}))
      end))
    end
    save_binding()
  end)
  local ok, resolve_call_error = pcall(herdr.resolve, identity, on_resolved)
  if not ok then
    tx.release()
    done(nil, runtime_failure('runtime_error', tostring(resolve_call_error)))
  end
end

local function promote_legacy_conversation(ref, task, callback)
  local claude=require('agent-board.claude')
  local identity=runtime_identity(task.agent)
  if identity.provider~='claude' or not claude.valid_id(identity.session_id) then
    return callback(nil,runtime_failure('unavailable','Legacy Claude link has no verified native session UUID'))
  end
  local function persist(conversation)
    local tx,tx_error=begin_transaction(ref)
    if not tx then return callback(nil,tx_error) end
    if not same_agent(tx.task.agent,identity) then tx.release();return callback(nil,runtime_failure('conflict','legacy Claude runtime changed')) end
    if linked(tx.task.conversation) then tx.release();return callback(vim.deepcopy(tx.task)) end
    local unique,unique_error=unique_conversation(tx,conversation)
    if not unique then tx.release();return callback(nil,unique_error) end
    tx.task.conversation=vim.deepcopy(conversation)
    local saved,save_error=tx.commit()
    tx.release()
    if not saved then return callback(nil,runtime_failure('save_failed',tostring(save_error))) end
    callback(vim.deepcopy(tx.task))
  end
  local function from_history()
    claude.get(ref.repo,identity.session_id,function(record,err)
      if not record then return callback(nil,err) end
      persist(record.conversation)
    end)
  end
  require('agent-board.herdr').resolve(identity,function(live,resolve_error)
    if not live then
      if resolve_error and resolve_error.code=='offline' then return from_history() end
      return callback(nil,resolve_error or runtime_failure('runtime_unavailable','Could not verify legacy Claude runtime'))
    end
    if live.identity.session_id~=identity.session_id then
      return callback(nil,runtime_failure('identity_mismatch','Claude changed its native conversation'))
    end
    require('agent-board.sessions').list(ref.repo,function(discovery,discovery_error)
      if not discovery then return callback(nil,discovery_error) end
      for _,row in ipairs(discovery.sessions) do
        if row.conversation and row.conversation.session_id==identity.session_id and row.agent
          and row.agent.identity.terminal_id==live.identity.terminal_id then
          return persist(row.conversation)
        end
      end
      callback(nil,runtime_failure('session_identity_unverified','Herdr could not verify the legacy Claude session in this repository',{agent=live.identity}))
    end)
  end)
end

function M.start_agent(ref, opts, callback)
  local existing = M.get_task(ref)
  if existing and linked(existing.conversation) then return M.open_conversation(ref, callback, opts and opts.terminal_opts, false) end
  if opts and opts.provider == 'claude' and existing and not linked(existing.agent) then return M.new_conversation(ref, opts, callback) end
  if opts and opts.provider=='claude' and existing and linked(existing.agent) and existing.agent.provider=='claude' then
    return promote_legacy_conversation(ref,existing,function(promoted,err)
      if not promoted then return callback(nil,err) end
      promoted.existing=true
      callback(promoted)
    end)
  end
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

local function get_linked_identity(ref)
  local task, task_error = M.get_task(ref)
  if not task then return nil, runtime_failure('task_not_found', task_error) end
  if not linked(task.agent) then return nil, runtime_failure('no_agent', 'task has no linked agent') end
  return task, runtime_identity(task.agent)
end

function M.open_agent(ref, callback, opts)
  opts = opts or {tabpage=vim.api.nvim_get_current_tabpage()}
  local current = M.get_task(ref)
  if current and linked(current.conversation) then return M.open_conversation(ref, callback, opts) end
  if current and linked(current.agent) and current.agent.provider=='claude'
    and require('agent-board.claude').valid_id(current.agent.session_id) then
    return promote_legacy_conversation(ref,current,function(promoted,err)
      if not promoted then return callback(nil,err) end
      M.open_conversation(ref,callback,opts)
    end)
  end
  if type(callback) ~= 'function' then return nil, 'a callback is required' end
  local done = callback_once(callback)
  local task, identity_or_error = get_linked_identity(ref)
  if not task then return done(nil, identity_or_error) end
  local herdr = require('agent-board.herdr')
  herdr.resolve(identity_or_error, function(live, resolve_error)
    if not live then return done(nil, resolve_error) end
    local root, root_error = M.resolve_repo(ref.repo)
    if not root then return done(nil, runtime_failure('repo_unavailable', root_error)) end
    local function attach()
      local terminal = require('agent-board.terminal')
      local opened, open_error = terminal.open(terminal_key(root, task.id), live.identity, opts)
      if not opened then return done(nil, open_error) end
      done(live)
    end
    local claude = require('agent-board.claude')
    if live.identity.provider == 'claude' and claude.valid_id(live.identity.session_id) then
      return claude.get(root, live.identity.session_id, function(record)
        if not record then return attach() end
        local tx, tx_error = begin_transaction(ref)
        if not tx then return done(nil, tx_error) end
        if not same_agent(tx.task.agent, live.identity) then tx.release();return done(nil,runtime_failure('conflict','task agent changed')) end
        local unique, duplicate_error = unique_conversation(tx, record.conversation)
        if not unique then tx.release();return done(nil, duplicate_error) end
        tx.task.conversation = vim.deepcopy(record.conversation)
        local saved, save_error = tx.commit()
        tx.release()
        if not saved then return done(nil,runtime_failure('save_failed',tostring(save_error))) end
        attach()
      end)
    end
    attach()
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

function M.send(ref, message, callback)
  if type(callback) ~= 'function' then return nil, 'a callback is required' end
  local done = callback_once(callback)
  local task, task_error = M.get_task(ref)
  if not task then return done(nil, runtime_failure('task_not_found', task_error)) end
  local herdr = require('agent-board.herdr')
  if linked(task.conversation) then
    return require('agent-board.sessions').resolve(task.conversation, function(session, err)
      if not session then return done(nil, err) end
      if session.state ~= 'running' then return done(nil, runtime_failure('offline', 'Open this conversation before sending a prompt')) end
      herdr.send(session.agent.identity, message, done)
    end)
  end
  if not linked(task.agent) then return done(nil,runtime_failure('no_agent','task has no linked agent')) end
  herdr.send(runtime_identity(task.agent), message, done)
end

function M.stop_agent(ref, callback)
  if type(callback) ~= 'function' then return nil, 'a callback is required' end
  local done = callback_once(callback)
  local task, task_error = M.get_task(ref)
  if not task then return done(nil, runtime_failure('task_not_found', task_error)) end
  local herdr = require('agent-board.herdr')
  if linked(task.conversation) then
    return require('agent-board.sessions').resolve(task.conversation, function(session, err)
      if not session then return done(nil, err) end
      if session.state ~= 'running' then return done(nil, runtime_failure('offline', 'Conversation is already offline')) end
      herdr.stop(session.agent.identity, done)
    end)
  end
  if not linked(task.agent) then return done(nil,runtime_failure('no_agent','task has no linked agent')) end
  herdr.stop(runtime_identity(task.agent), done)
end

unique_conversation = function(tx, conversation)
  for _, registered in ipairs(tx.registry.repos) do
    local root, root_error = M.resolve_repo(registered)
    if not root or root ~= registered then return nil, runtime_failure('board_unavailable', root_error or 'registered repository moved') end
    local document, read_error
    if root == tx.root then document = tx.document else document, read_error = storage.read(board_path(root), 'board') end
    if not document then return nil, runtime_failure('board_unavailable', tostring(read_error)) end
    for _, other in ipairs(document.tasks) do
      if (root ~= tx.root or other.id ~= tx.task.id) and
        ((linked(other.conversation) and other.conversation.session_id == conversation.session_id)
        or (linked(other.agent) and other.agent.provider == 'claude' and other.agent.session_id == conversation.session_id)) then
        return nil, runtime_failure('already_bound', 'this Claude conversation is already linked to a task')
      end
    end
  end
  return true
end

function M.bind_conversation(ref, conversation, expected_snapshot, callback)
  if type(expected_snapshot) == 'function' then callback, expected_snapshot = expected_snapshot, nil end
  if type(callback) ~= 'function' then return nil, 'a callback is required' end
  local done = callback_once(callback)
  local current, task_error = M.get_task(ref)
  if not current then return done(nil, runtime_failure('task_not_found', task_error)) end
  if linked(current.agent) or linked(current.conversation) then return done(nil, runtime_failure('already_linked', 'task already has a linked session')) end
  local claude = require('agent-board.claude')
  if type(conversation) ~= 'table' or conversation.provider ~= 'claude' or not claude.valid_id(conversation.session_id) then
    return done(nil, runtime_failure('unavailable', 'Invalid Claude conversation'))
  end
  require('agent-board.sessions').list(ref.repo,function(discovery,discovery_error)
    if not discovery then return done(nil,discovery_error) end
    local selected
    for _,row in ipairs(discovery.sessions) do
      if row.conversation and row.conversation.session_id==conversation.session_id then selected=row;break end
    end
    if not selected then return done(nil,runtime_failure('unavailable','Claude conversation has no local metadata or verified live runtime')) end
    if selected.conversation.cwd~=conversation.cwd then return done(nil,runtime_failure('identity_mismatch','Conversation cwd does not match local metadata or runtime')) end
    if selected.state=='unavailable' or (selected.state=='unknown' and not (discovery.runtime_error and not selected.agent and not selected.ambiguous)) then return done(nil,runtime_failure('runtime_unknown',selected.reason or 'Claude session state is unknown')) end
    local tx, tx_error = begin_transaction(ref, expected_snapshot)
    if not tx then return done(nil, tx_error) end
    if linked(tx.task.agent) or linked(tx.task.conversation) then tx.release();return done(nil, runtime_failure('already_linked', 'task already has a linked session')) end
    local unique, unique_error = unique_conversation(tx, selected.conversation)
    if not unique then tx.release();return done(nil, unique_error) end
    if selected.agent then
      local unique_live,live_error=unique_agent(tx,selected.agent.identity)
      if not unique_live then tx.release();return done(nil,live_error) end
      tx.task.agent=stored_identity(selected.agent.identity)
    end
    tx.task.conversation = vim.deepcopy(selected.conversation)
    local saved, save_error = tx.commit()
    tx.release()
    if not saved then return done(nil, runtime_failure('save_failed', tostring(save_error))) end
    done(vim.deepcopy(tx.task))
  end)
end

function M.list_sessions(ref, callback)
  local current, task_error = M.get_task(ref)
  if not current then return callback(nil, runtime_failure('task_not_found', task_error)) end
  require('agent-board.sessions').list(ref.repo, function(discovery, err)
    if not discovery then return callback(nil, err) end
    local rows, warnings = M.list_tasks({scope='global'})
    if not rows or #warnings > 0 then
      discovery.warnings[#discovery.warnings+1] = 'Some registered boards could not be checked; binding will verify them again'
    end
    for _, session in ipairs(discovery.sessions) do
      for _, row in ipairs(rows or {}) do
        if (session.conversation and linked(row.task.conversation) and session.conversation.session_id == row.task.conversation.session_id)
          or (session.agent and same_agent(row.task.agent, session.agent.identity)) then session.bound = true;session.bound_title = row.task.title end
      end
    end
    callback(discovery)
  end)
end

local uncertain = {}
local function launch_conversation(tx, conversation, mode, done, terminal_opts, return_task)
  local herdr = require('agent-board.herdr')
  local key = terminal_key(tx.root, tx.task.id)
  local name = 'ab-' .. vim.fn.sha256(tx.root .. '\0' .. tx.task.id):sub(1,16)
  tx.task.conversation = vim.deepcopy(conversation)
  tx.task.pending_start = true
  local reserved, reservation_error = tx.commit()
  if not reserved then tx.release();return done(nil,runtime_failure('save_failed',tostring(reservation_error))) end
  local on_started = guarded(tx, done, function(started, start_error)
    if not started then
      if start_error and start_error.host then
        uncertain[key] = {conversation=conversation,host=start_error.host}
      else
        tx.task.pending_start=nil
        if mode=='--session-id' then tx.task.conversation=vim.NIL end
        local cleared,clear_error=tx.commit()
        if not cleared then start_error=runtime_failure('save_failed','Herdr failed before launch and the reservation could not be cleared: '..tostring(clear_error)) end
      end
      tx.release()
      return done(nil, start_error or runtime_failure('runtime_unknown', 'Herdr start outcome is unknown'))
    end
    local unique, unique_error = unique_agent(tx, started.identity)
    if not unique then tx.release();unique_error.agent=started.identity;unique_error.host=started.host;return done(nil, unique_error) end
    tx.task.conversation = vim.deepcopy(conversation)
    tx.task.pending_start = nil
    tx.task.agent = stored_identity(started.identity)
    local saved, save_error = tx.commit()
    tx.release()
    if not saved then uncertain[key]={conversation=conversation,host=started.host};return done(nil, runtime_failure('save_failed', tostring(save_error), {agent=started.identity,host=started.host})) end
    uncertain[key]=nil
    if return_task then return done(vim.deepcopy(tx.task)) end
    local opened, open_error = require('agent-board.terminal').open(key, started.identity, terminal_opts)
    done(opened and {identity=started.identity} or nil, open_error)
  end)
  local ok, call_error = pcall(herdr.start, conversation.cwd, 'claude', name, on_started,
    {agent_args={mode,conversation.session_id},expected_session_id=conversation.session_id})
  if not ok then uncertain[key]={conversation=conversation};tx.release();done(nil,runtime_failure('runtime_unknown',tostring(call_error))) end
end

function M.new_conversation(ref, opts, callback)
  if type(callback) ~= 'function' then return nil, 'a callback is required' end
  local done = callback_once(callback)
  local tx, err = begin_transaction(ref, opts.expected_snapshot)
  if not tx then return done(nil, err) end
  if linked(tx.task.agent) or linked(tx.task.conversation) then tx.release();return done(nil,runtime_failure('already_linked','task already has a linked session')) end
  local key=terminal_key(tx.root,tx.task.id)
  if uncertain[key] then tx.release();return done(nil,runtime_failure('runtime_unknown','Previous start outcome is unknown; inspect the returned Herdr host before retrying',uncertain[key])) end
  local conversation={provider='claude',session_id=require('agent-board.claude').new_session_id(),cwd=tx.root}
  require('agent-board.herdr').list(guarded(tx,done,function(agents,list_error)
    if not agents then tx.release();return done(nil,list_error) end
    local name='ab-'..vim.fn.sha256(tx.root..'\0'..tx.task.id):sub(1,16)
    for _,live in ipairs(agents) do if live.identity.name==name then tx.release();return done(nil,runtime_failure('runtime_unknown','A previous task runtime needs recovery',{agent=live.identity})) end end
    launch_conversation(tx,conversation,'--session-id',done,opts.terminal_opts,true)
  end))
end

function M.open_conversation(ref, callback, opts, return_task)
  if type(callback) ~= 'function' then return nil, 'a callback is required' end
  local done = callback_once(callback)
  opts = opts or {tabpage=vim.api.nvim_get_current_tabpage()}
  local current, task_error = M.get_task(ref)
  if not current or not linked(current.conversation) then return done(nil,runtime_failure('no_agent',task_error or 'task has no conversation')) end
  local conversation=vim.deepcopy(current.conversation)
  local sessions=require('agent-board.sessions')
  local function discover()
    sessions.resolve(conversation,function(session,resolve_error)
      if not session then
        if current.pending_start and resolve_error and resolve_error.code == 'unavailable' then
          return done(nil,runtime_failure('runtime_unknown','Previous Claude start is unverified; recover its Herdr runtime before retrying'))
        end
        return done(nil,resolve_error)
      end
      local tx,tx_error=begin_transaction(ref)
      if not tx then return done(nil,tx_error) end
      if not vim.deep_equal(tx.task.conversation,conversation) then tx.release();return done(nil,runtime_failure('conflict','task conversation changed')) end
      local unique,unique_error=unique_conversation(tx,conversation)
      if not unique then tx.release();return done(nil,unique_error) end
      -- Re-query while holding the shared coordinator lock before creating a runtime.
      sessions.resolve(conversation,guarded(tx,done,function(verified,verify_error)
        if not verified then tx.release();return done(nil,verify_error) end
        if verified.state=='running' then
          if tx.task.pending_start or not same_agent(tx.task.agent,verified.agent.identity) then
            tx.task.pending_start = nil
            tx.task.agent=stored_identity(verified.agent.identity)
            local saved,save_error=tx.commit()
            if not saved then tx.release();return done(nil,runtime_failure('save_failed',tostring(save_error),{agent=verified.agent.identity})) end
          end
          tx.release()
          local opened,open_error=require('agent-board.terminal').open(terminal_key(tx.root,tx.task.id),verified.agent.identity,opts)
          if return_task and opened then return done(vim.deepcopy(tx.task)) end
          return done(opened and verified.agent or nil,open_error)
        end
        if tx.task.pending_start then tx.release();return done(nil,runtime_failure('runtime_unknown','Previous Claude start is unverified; recover its Herdr runtime before retrying')) end
        local recovery=uncertain[terminal_key(tx.root,tx.task.id)]
        if recovery then tx.release();return done(nil,runtime_failure('runtime_unknown','Previous start outcome is unknown; inspect its Herdr host',recovery)) end
        launch_conversation(tx,conversation,'--resume',done,opts,return_task)
      end))
    end)
  end
  if linked(current.agent) then
    require('agent-board.herdr').resolve(runtime_identity(current.agent),function(live,err)
      if live and live.identity.session_id~=conversation.session_id then return done(nil,runtime_failure('identity_mismatch','Claude changed its native conversation')) end
      if not live and err and err.code~='offline' then return done(nil,err) end
      discover()
    end)
  else discover() end
end

return M
