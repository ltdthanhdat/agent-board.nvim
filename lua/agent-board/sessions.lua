local M={}
local claude=require('agent-board.claude')
local herdr=require('agent-board.herdr')
local function failure(code,message) return {code=code,message=message} end
function M.list(repo,callback)
  claude.list(repo,function(records,warnings)
    claude.repo_identity(repo,function(target,target_error)
      if not target then return callback(nil,target_error) end
      herdr.list(function(agents,runtime_error)
        local discovery={sessions={},warnings=warnings,runtime_error=runtime_error}
        local by_id={}
        for _,record in ipairs(records) do
          local row={conversation=record.conversation,title=record.title,updated_at=record.updated_at,state=runtime_error and 'unknown' or (record.resumable and 'offline' or 'unavailable'),reason=record.reason}
          by_id[record.conversation.session_id]=row
          discovery.sessions[#discovery.sessions+1]=row
        end
        local cursor=0
        local function next_agent()
          cursor=cursor+1
          local live=(agents or {})[cursor]
          if not live then return callback(discovery) end
          claude.repo_identity(live.cwd,function(identity)
            local relevant=identity and (identity.root==target.root or identity.common_dir==target.common_dir)
            if not identity and live.identity.provider=='claude' then discovery.unknown_runtime=true end
            if relevant then
              local id=live.identity.session_id
              if live.identity.provider=='claude' and claude.valid_id(id) then
                local row=by_id[id]
                if not row then row={conversation={provider='claude',session_id=id,cwd=live.cwd},title=id,state='running'};by_id[id]=row;discovery.sessions[#discovery.sessions+1]=row end
                if row.agent then row.state='unknown';row.ambiguous=true;row.reason='Multiple live runtimes for this conversation'
                else row.agent=live;row.state='running' end
              else
                discovery.sessions[#discovery.sessions+1]={agent=live,title=live.identity.name or live.identity.pane_id,state='running',reason=live.identity.provider=='claude' and 'Session ID unavailable' or nil}
                if live.identity.provider=='claude' then discovery.unknown_runtime=true end
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
function M.resolve(conversation,callback)
  if type(conversation)~='table' or conversation.provider~='claude' or not claude.valid_id(conversation.session_id) then return vim.schedule(function()callback(nil,failure('unavailable','Invalid Claude conversation'))end) end
  M.list(conversation.cwd,function(discovery,err)
    if not discovery then return callback(nil,err) end
    if discovery.runtime_error then return callback(nil,discovery.runtime_error) end
    for _,row in ipairs(discovery.sessions) do
      if row.conversation and row.conversation.session_id==conversation.session_id then
        if row.ambiguous then return callback(nil,failure('ambiguous_runtime',row.reason)) end
        if row.state=='running' then return callback(row) end
        if discovery.unknown_runtime then return callback(nil,failure('runtime_unknown','A live Claude agent has no verified native session ID')) end
        if row.state=='unavailable' then return callback(nil,failure('unavailable',row.reason)) end
        if row.conversation.cwd~=conversation.cwd then return callback(nil,failure('identity_mismatch','The saved conversation cwd has changed')) end
        return callback(row)
      end
    end
    if discovery.unknown_runtime then return callback(nil,failure('runtime_unknown','A live Claude agent has no verified native session ID')) end
    callback(nil,failure('unavailable','Claude conversation has no saved transcript; it cannot be resumed yet'))
  end)
end
return M
