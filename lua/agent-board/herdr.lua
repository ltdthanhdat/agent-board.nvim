local M = {}

local QUERY_TIMEOUT_MS = 5000
local START_TIMEOUT_MS = 30000
local START_COMMAND_TIMEOUT_MS = 35000
local WORKSPACE_LABEL = 'agent-board.nvim'
local providers = { claude = true, codex = true, pi = true }
local states = { idle = true, working = true, blocked = true, done = true, unknown = true }

local function failure(code, message, extra)
  local err = { code = code, message = message }
  for key, value in pairs(extra or {}) do
    err[key] = value
  end
  return err
end

local function once(callback)
  local called = false
  return function(...)
    if called then
      return
    end
    called = true
    local args = { ... }
    vim.schedule(function()
      callback(unpack(args))
    end)
  end
end

function M.server_key()
  local socket = vim.env.HERDR_SOCKET_PATH
  if socket and socket ~= '' then
    return 'socket:' .. vim.fs.normalize(socket)
  end
  local session = vim.env.HERDR_SESSION
  if not session or session == '' then
    session = 'default'
  end
  return 'session:' .. session
end

function M.run(args, timeout_ms, callback)
  local done = once(callback)
  local command = { 'herdr' }
  vim.list_extend(command, args)
  local ok, process = pcall(vim.system, command, { text = true, timeout = timeout_ms }, function(result)
    done({ code = result.code, stdout = result.stdout or '', stderr = result.stderr or '' })
  end)
  if not ok then
    done({ code = 127, stdout = '', stderr = tostring(process) })
  end
end

local function request(args, timeout_ms, callback)
  local done = once(callback)
  M.run(args, timeout_ms, function(response)
    if type(response) ~= 'table' then
      return done(nil, failure('runtime_unavailable', 'Herdr returned no command result'))
    end
    local code = response.code
    local output = code == 0 and response.stdout or response.stderr
    if type(output) ~= 'string' then
      return done(nil, failure('runtime_unavailable', 'Herdr returned an invalid command result'))
    end
    local ok, decoded = pcall(vim.json.decode, output)
    if not ok or type(decoded) ~= 'table' then
      return done(nil, failure('runtime_unavailable', 'Herdr returned invalid JSON'))
    end
    if code ~= 0 or decoded.error then
      local body = decoded.error
      local message = type(body) == 'table' and body.message or 'Herdr command failed'
      local error_code = type(body) == 'table' and body.code or nil
      return done(nil, failure(error_code or 'runtime_unavailable', message))
    end
    if type(decoded.result) ~= 'table' then
      return done(nil, failure('runtime_unavailable', 'Herdr response has no result object'))
    end
    done(decoded.result)
  end)
end

local function normalize(info, server)
  if type(info) ~= 'table' then
    return nil, failure('runtime_unavailable', 'Herdr agent record is not an object')
  end
  local provider = info.agent
  if not providers[provider] then
    return false
  end
  if type(info.terminal_id) ~= 'string' or info.terminal_id == ''
    or type(info.pane_id) ~= 'string' or info.pane_id == '' then
    return nil, failure('runtime_unavailable', 'Herdr agent record has no terminal or pane identity')
  end
  if not states[info.agent_status] then
    return nil, failure('runtime_unavailable', 'Herdr agent record has an unknown state')
  end
  local name = type(info.name) == 'string' and info.name ~= '' and info.name or nil
  local session = type(info.agent_session) == 'table' and info.agent_session.value or nil
  if type(session) ~= 'string' or session == '' then
    session = nil
  end
  local identity = {
    provider = provider,
    runtime = 'herdr',
    server = server,
    terminal_id = info.terminal_id,
    pane_id = info.pane_id,
  }
  if name then
    identity.name = name
  end
  if session then
    identity.session_id = session
  end
  return {
    identity = identity,
    cwd = type(info.cwd) == 'string' and info.cwd or nil,
    state = info.agent_status,
  }
end

function M.list(callback)
  local server = M.server_key()
  request({ 'agent', 'list' }, QUERY_TIMEOUT_MS, function(result, err)
    if not result then
      return callback(nil, failure('runtime_unavailable', err.message))
    end
    if type(result.agents) ~= 'table' or not vim.islist(result.agents) then
      return callback(nil, failure('runtime_unavailable', 'Herdr agent list is malformed'))
    end
    local agents = {}
    for _, info in ipairs(result.agents) do
      local agent, normalize_error = normalize(info, server)
      if normalize_error then
        return callback(nil, normalize_error)
      end
      if agent then
        agents[#agents + 1] = agent
      end
    end
    callback(agents)
  end)
end

local function valid_identity(identity)
  return type(identity) == 'table'
    and identity.runtime == 'herdr'
    and providers[identity.provider]
    and type(identity.server) == 'string'
    and type(identity.terminal_id) == 'string'
    and type(identity.pane_id) == 'string'
end

local function has_session_identity(identity)
  return type(identity.session_id) == 'string' and identity.session_id ~= ''
end

function M.resolve(identity, callback)
  if not valid_identity(identity) then
    return callback(nil, failure('identity_mismatch', 'Herdr identity is incomplete'))
  end
  if not has_session_identity(identity) then
    return callback(nil, failure('identity_unverifiable', 'Herdr did not provide a provider session ID'))
  end
  if identity.server ~= M.server_key() then
    return callback(nil, failure('identity_mismatch', 'The active Herdr route has changed'))
  end
  request({ 'agent', 'get', identity.pane_id }, QUERY_TIMEOUT_MS, function(result, err)
    if not result then
      local code = err.code == 'agent_not_found' and 'offline' or 'runtime_unavailable'
      return callback(nil, failure(code, err.message))
    end
    local live, normalize_error = normalize(result.agent, M.server_key())
    if normalize_error or not live then
      return callback(nil, normalize_error or failure('identity_mismatch', 'Herdr target is no longer a supported agent'))
    end
    local current = live.identity
    if identity.server ~= current.server
      or identity.terminal_id ~= current.terminal_id
      or identity.pane_id ~= current.pane_id
      or identity.provider ~= current.provider
      or (identity.name and identity.name ~= current.name)
      or (identity.session_id and identity.session_id ~= current.session_id) then
      return callback(nil, failure('identity_mismatch', 'The Herdr pane now belongs to a different agent session'))
    end
    callback(live)
  end)
end

function M.attach_argv(identity)
  if not valid_identity(identity) or identity.server ~= M.server_key() then
    return nil, failure('identity_mismatch', 'The active Herdr route does not match this agent')
  end
  if not has_session_identity(identity) then
    return nil, failure('identity_unverifiable', 'Herdr did not provide a provider session ID')
  end
  return { 'herdr', 'terminal', 'attach', identity.terminal_id }
end

local function controlled_request(identity, args, callback)
  if not valid_identity(identity) then
    return callback(nil, failure('identity_mismatch', 'Herdr identity is incomplete'))
  end
  M.resolve(identity, function(live, resolve_error)
    if not live then
      return callback(nil, resolve_error)
    end
    request(args, QUERY_TIMEOUT_MS, function(_, err)
      if err then
        return callback(nil, failure('runtime_unavailable', err.message))
      end
      callback(true)
    end)
  end)
end

function M.send(identity, message, callback)
  if not valid_identity(identity) then
    return callback(nil, failure('identity_mismatch', 'Herdr identity is incomplete'))
  end
  if type(message) ~= 'string' or message == '' then
    return callback(nil, failure('invalid_input', 'A non-empty prompt is required'))
  end
  controlled_request(identity, { 'agent', 'prompt', identity.pane_id, message }, callback)
end

function M.stop(identity, callback)
  if not valid_identity(identity) then
    return callback(nil, failure('identity_mismatch', 'Herdr identity is incomplete'))
  end
  controlled_request(identity, { 'pane', 'close', identity.pane_id }, callback)
end

local function start_name(name)
  return type(name) == 'string' and #name <= 32 and name:match('^[a-z][a-z0-9_-]*$') ~= nil
end

function M.start(repo, provider, name, callback, opts)
  opts = opts or {}
  if opts.agent_args and (type(opts.agent_args) ~= 'table' or not vim.islist(opts.agent_args)) then
    return callback(nil, failure('invalid_input', 'agent_args must be an argv list'))
  end
  for _, arg in ipairs(opts.agent_args or {}) do
    if type(arg) ~= 'string' then return callback(nil, failure('invalid_input', 'agent arguments must be strings')) end
  end
  if type(repo) ~= 'string' or repo == '' or not providers[provider] or not start_name(name) then
    return callback(nil, failure('invalid_input', 'repo, provider, or Herdr agent name is invalid'))
  end
  local server = M.server_key()
  local function finish_host_error(err, host, agent)
    return callback(nil, failure(err.code, err.message, { host = host, agent = agent }))
  end

  request({ 'workspace', 'list' }, QUERY_TIMEOUT_MS, function(result, err)
    if not result then
      return callback(nil, err)
    end
    if type(result.workspaces) ~= 'table' then
      return callback(nil, failure('runtime_unavailable', 'Herdr workspace list is malformed'))
    end
    local workspace_id
    for _, workspace in ipairs(result.workspaces) do
      if workspace.label == WORKSPACE_LABEL then
        workspace_id = workspace.workspace_id
        break
      end
    end
    local function create_tab()
      if server ~= M.server_key() then
        return callback(nil, failure('identity_mismatch', 'The active Herdr route changed during start'))
      end
      request({ 'tab', 'create', '--cwd', repo, '--no-focus', '--workspace', workspace_id, '--label', name }, QUERY_TIMEOUT_MS, function(tab_result, tab_error)
        if not tab_result then
          return callback(nil, tab_error)
        end
        local tab = tab_result.tab
        local pane = tab_result.root_pane
        if type(tab) ~= 'table' or type(tab.tab_id) ~= 'string'
          or type(pane) ~= 'table' or type(pane.pane_id) ~= 'string' then
          return callback(nil, failure('runtime_unavailable', 'Herdr did not return the created tab and pane IDs'))
        end
        local host = { workspace_id = workspace_id, tab_id = tab.tab_id, pane_id = pane.pane_id }
        if server ~= M.server_key() then
          return finish_host_error(failure('identity_mismatch', 'The active Herdr route changed during start'), host)
        end
        local argv = { 'agent', 'start', name, '--kind', provider, '--pane', pane.pane_id, '--timeout', tostring(START_TIMEOUT_MS) }
        if opts.agent_args and #opts.agent_args > 0 then argv[#argv+1] = '--'; vim.list_extend(argv, opts.agent_args) end
        request(argv, START_COMMAND_TIMEOUT_MS, function(start_result, start_error)
          if not start_result then
            return finish_host_error(start_error, host)
          end
          local live, normalize_error = normalize(start_result.agent, server)
          if normalize_error or not live then
            return finish_host_error(normalize_error or failure('runtime_unavailable', 'Herdr start response has no agent'), host)
          end
          if not opts.expected_session_id and not has_session_identity(live.identity) then
            return finish_host_error(failure('identity_unverifiable', 'Herdr did not provide a provider session ID'), host, live.identity)
          end
          if live.identity.name ~= name or live.identity.provider ~= provider or live.identity.pane_id ~= pane.pane_id then
            return finish_host_error(failure('identity_mismatch', 'Herdr started an unexpected agent or pane'), host)
          end
          if server ~= M.server_key() then
            return callback(nil, failure('identity_mismatch', 'The active Herdr route changed during start', {host=host,agent=live.identity}))
          end
          if opts.expected_session_id and live.identity.session_id ~= opts.expected_session_id then
            local code = live.identity.session_id and 'identity_mismatch' or 'session_identity_unverified'
            return callback(nil, failure(code, 'Herdr could not verify the requested Claude session UUID', {host=host,agent=live.identity}))
          end
          callback({ identity = live.identity, host = host })
        end)
      end)
    end

    if workspace_id then
      return create_tab()
    end
    if server ~= M.server_key() then
      return callback(nil, failure('identity_mismatch', 'The active Herdr route changed during start'))
    end
    request({ 'workspace', 'create', '--no-focus', '--label', WORKSPACE_LABEL }, QUERY_TIMEOUT_MS, function(created, create_error)
      if not created then
        return callback(nil, create_error)
      end
      if type(created.workspace) ~= 'table' or type(created.workspace.workspace_id) ~= 'string' then
        return callback(nil, failure('runtime_unavailable', 'Herdr did not return the created workspace ID'))
      end
      workspace_id = created.workspace.workspace_id
      create_tab()
    end)
  end)
end

return M
