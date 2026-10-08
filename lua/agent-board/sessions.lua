local M = {}
local claude = require('agent-board.claude')
local herdr = require('agent-board.herdr')

local function failure(code, message)
  return { code = code, message = message }
end

local function session_key(provider, session_id)
  return provider .. '\0' .. session_id
end

function M.list(repo, callback)
  claude.list(repo, function(claude_records, claude_warnings)
    claude.repo_identity(repo, function(target, target_error)
      if not target then return callback(nil, target_error) end
      local provider_records, provider_warnings = require('agent-board.provider_sessions').list(repo)
      herdr.list(function(agents, runtime_error)
        local discovery = {
          sessions = {},
          warnings = vim.list_extend(claude_warnings or {}, provider_warnings or {}),
          runtime_error = runtime_error,
        }
        local by_key = {}
        local function add_saved(record)
          local conversation = record.conversation
          local key = session_key(conversation.provider, conversation.session_id)
          local row = {
            conversation = conversation,
            title = record.title,
            updated_at = record.updated_at,
            state = runtime_error and 'unknown' or (record.resumable == false and 'unavailable' or 'offline'),
            reason = record.reason,
            preview = record.preview,
          }
          by_key[key] = row
          discovery.sessions[#discovery.sessions + 1] = row
        end
        for _, record in ipairs(claude_records or {}) do add_saved(record) end
        for _, record in ipairs(provider_records or {}) do add_saved(record) end
        local cursor = 0
        local function next_agent()
          cursor = cursor + 1
          local live = (agents or {})[cursor]
          if not live then
            table.sort(discovery.sessions, function(left, right)
              return (left.updated_at or '') > (right.updated_at or '')
            end)
            return callback(discovery)
          end
          claude.repo_identity(live.cwd, function(identity)
            local relevant = identity and (identity.root == target.root or identity.common_dir == target.common_dir)
            if not identity and live.identity.provider == 'claude' then discovery.unknown_runtime = true end
            if relevant then
              local provider, id = live.identity.provider, live.identity.session_id
              local verified_id = type(id) == 'string' and id ~= ''
                and (provider ~= 'claude' or claude.valid_id(id))
              if verified_id then
                local key = session_key(provider, id)
                local row = by_key[key]
                if not row then
                  row = {
                    conversation = { provider = provider, session_id = id, cwd = live.cwd },
                    title = live.identity.name or id,
                    state = 'running',
                  }
                  by_key[key] = row
                  discovery.sessions[#discovery.sessions + 1] = row
                end
                if row.agent then
                  row.state = 'unknown'
                  row.ambiguous = true
                  row.reason = 'Multiple live runtimes for this session'
                else
                  row.agent = live
                  row.state = 'running'
                end
              else
                discovery.sessions[#discovery.sessions + 1] = {
                  agent = live,
                  title = live.identity.name or live.identity.pane_id,
                  state = 'running',
                  reason = provider == 'claude' and 'Session ID unavailable' or nil,
                }
                if provider == 'claude' then discovery.unknown_runtime = true end
              end
            end
            next_agent()
          end)
        end
        next_agent()
      end)
    end)
  end)
end

function M.resolve(conversation, callback)
  if type(conversation) ~= 'table'
    or (conversation.provider ~= 'claude' and conversation.provider ~= 'codex' and conversation.provider ~= 'pi')
    or type(conversation.session_id) ~= 'string' or conversation.session_id == '' then
    return vim.schedule(function() callback(nil, failure('unavailable', 'Invalid provider session')) end)
  end
  if conversation.provider == 'claude' and not claude.valid_id(conversation.session_id) then
    return vim.schedule(function() callback(nil, failure('unavailable', 'Invalid Claude conversation')) end)
  end
  M.list(conversation.cwd, function(discovery, err)
    if not discovery then return callback(nil, err) end
    if discovery.runtime_error then return callback(nil, discovery.runtime_error) end
    for _, row in ipairs(discovery.sessions) do
      local saved = row.conversation
      if saved and saved.provider == conversation.provider and saved.session_id == conversation.session_id then
        if saved.cwd ~= conversation.cwd then return callback(nil, failure('identity_mismatch', 'The saved session cwd has changed')) end
        if row.agent and row.agent.cwd ~= conversation.cwd then
          return callback(nil, failure('identity_mismatch', 'The running session is in a different directory'))
        end
        if row.ambiguous then return callback(nil, failure('ambiguous_runtime', row.reason)) end
        if row.state == 'running' then return callback(row) end
        if discovery.unknown_runtime then return callback(nil, failure('runtime_unknown', 'A live Claude agent has no verified native session ID')) end
        if row.state == 'unavailable' then return callback(nil, failure('unavailable', row.reason)) end
        return callback(row)
      end
    end
    if discovery.unknown_runtime then return callback(nil, failure('runtime_unknown', 'A live Claude agent has no verified native session ID')) end
    callback(nil, failure('unavailable', conversation.provider .. ' session has no saved transcript in this repository'))
  end)
end

return M
