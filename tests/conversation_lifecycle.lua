package.path='./lua/?.lua;./lua/?/init.lua;'..package.path
local tmp=vim.fn.tempname()
local repo=tmp..'/repo'
vim.fn.mkdir(repo,'p')
assert(vim.system({'git','init',repo}):wait().code==0)
local config=tmp..'/claude'
vim.fn.mkdir(config..'/projects/repo','p')
vim.env.CLAUDE_CONFIG_DIR=config
vim.env.HERDR_SESSION='agent-board-fixture'
local id='12345678-1234-4234-8234-123456789abc'
local function history(uuid)
 local f=assert(io.open(config..'/projects/repo/'..uuid..'.jsonl','w'))
 f:write(vim.json.encode({type='user',sessionId=uuid,cwd=repo,timestamp='2026-10-07T00:00:00Z'}),'\n');f:close()
end
history(id)
local storage=require('agent-board.storage')
storage.registry_path=function() return tmp..'/registry.json' end
local api=require('agent-board')
local herdr=require('agent-board.herdr')
local terminal=require('agent-board.terminal')
local agents,starts={},0
local list_error,hold,start_error,held
herdr.list=function(cb) vim.schedule(function() cb(vim.deepcopy(agents),list_error) end) end
herdr.resolve=function(identity,cb)
 for _,a in ipairs(agents) do if a.identity.terminal_id==identity.terminal_id then
  if identity.session_id and identity.session_id~=a.identity.session_id then return cb(nil,{code='identity_mismatch',message='changed native ID'}) end
  return cb(vim.deepcopy(a))
 end end
 cb(nil,{code='offline',message='offline'})
end
herdr.start=function(cwd,provider,name,cb,opts)
 starts=starts+1
 if opts then assert(opts.expected_session_id and opts.agent_args[2]==opts.expected_session_id,'exact native UUID passed') end
 local function finish()
  if start_error then return cb(nil,start_error) end
  local identity={provider=provider,runtime='herdr',server=herdr.server_key(),terminal_id='term-'..starts,pane_id='pane-'..starts,name=name,session_id=opts and opts.expected_session_id or 'ffffffff-ffff-4fff-8fff-ffffffffffff'}
  agents[#agents+1]={identity=identity,cwd=cwd,state='idle'}
  cb({identity=identity,host={pane_id=identity.pane_id}})
 end
 if hold then held=finish else vim.schedule(finish) end
end
herdr.stop=function(identity,cb) for n,a in ipairs(agents) do if a.identity.terminal_id==identity.terminal_id then table.remove(agents,n);break end end;cb(true) end
herdr.send=function(_,_,cb) cb(true) end
local opened=0
terminal.open=function(_,_,opts) opened=opened+1;return true end
local function await(fn)
 local done,value,err,calls=false,nil,nil,0
 fn(function(v,e) calls=calls+1;value,err,done=v,e,true end)
 assert(vim.wait(10000,function()return done end),'callback timeout')
 assert(calls==1,'callback once')
 return value,err
end
assert(type(api.bind_conversation)=='function','durable conversation binding is missing')
local sessions=require('agent-board.sessions')
local task=assert(api.create_task({repo=repo,title='Saved task'}))
local ref={repo=repo,id=task.id}
local conversation={provider='claude',session_id=id,cwd=repo}
local bound=assert(await(function(cb)api.bind_conversation(ref,conversation,cb)end))
assert(bound.agent==vim.NIL and bound.conversation.session_id==id and starts==0,'offline_bind_reload_open')
assert(api.get_task(ref).conversation.session_id==id,'durable reload')
local offline_prompt,offline_prompt_error=await(function(cb)api.send(ref,'hello',cb)end)
assert(not offline_prompt and offline_prompt_error.code=='offline','offline linked conversation prompt asks user to open first')

local duplicate=assert(api.create_task({repo=repo,title='Duplicate'}))
local bad,err=await(function(cb)api.bind_conversation({repo=repo,id=duplicate.id},conversation,cb)end)
assert(not bad and err.code=='already_bound','unique conversation')
assert(await(function(cb)api.open_agent(ref,cb)end))
assert(starts==1 and opened==1,'offline open resumes')
local discovery=assert(await(function(cb)api.list_sessions(ref,cb)end))
assert(#discovery.sessions==1 and discovery.sessions[1].state=='running','merge_running_offline')
assert(await(function(cb)api.open_agent(ref,cb)end));assert(starts==1,'live reuse')
assert(await(function(cb)api.stop_agent(ref,cb)end))
assert(api.get_task(ref).conversation.session_id==id and api.get_task(ref).status=='todo','stop keeps link and column')
local reopened_by_start=assert(await(function(cb)api.start_agent(ref,{provider='claude'},cb)end));assert(starts==2 and opened==3 and reopened_by_start.identity.session_id==id,'start on linked Claude task opens the same conversation')
local original=agents[1].identity.session_id
agents[1].identity.session_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
local changed,change_error=await(function(cb)api.open_agent(ref,cb)end)
assert(not changed and change_error.code=='identity_mismatch' and starts==2,'changed_native_session')
agents[1].identity.session_id=original
agents={}
list_error={code='runtime_unavailable',message='unavailable'}
local unknown,unknown_error=await(function(cb)api.open_agent(ref,cb)end)
assert(not unknown and unknown_error and starts==2,'query failure must not start')
list_error=nil
agents={{identity={provider='claude',runtime='herdr',server=herdr.server_key(),terminal_id='unknown',pane_id='unknown'},cwd=repo,state='unknown'}}
local unverified,unverified_error=await(function(cb)api.open_agent(ref,cb)end)
assert(not unverified and unverified_error.code=='runtime_unknown' and starts==2,'missing native evidence cannot prove offline')
agents={}
hold=true
local first_done=false
api.open_agent(ref,function(v,e)assert(v and not e);first_done=true end)
assert(vim.wait(10000,function() return held~=nil end))
local concurrent,concurrent_error=await(function(cb)api.open_agent(ref,cb)end)
assert(not concurrent and concurrent_error.code=='locked','double Enter blocked')
held();held=nil;hold=false
assert(vim.wait(10000,function()return first_done end));assert(starts==3)
assert(await(function(cb)api.stop_agent(ref,cb)end))
local prompt,prompt_error=await(function(cb)api.send(ref,'hello',cb)end)
assert(not prompt and prompt_error.code=='offline','offline prompt requires open')
local fresh=assert(api.create_task({repo=repo,title='New'}))
local fresh_ref={repo=repo,id=fresh.id}
local fresh_started=assert(await(function(cb)api.start_agent(fresh_ref,{provider='claude'},cb)end))
assert(fresh_started.conversation.session_id~=id and fresh_started.status=='todo','new explicit UUID keeps its lane')
local fresh_id=fresh_started.conversation.session_id
history(fresh_id)
assert(await(function(cb)api.stop_agent(fresh_ref,cb)end))
assert(await(function(cb)api.open_agent(fresh_ref,cb)end))
assert(api.get_task(fresh_ref).conversation.session_id==fresh_id,'new_exit_resume')
assert(api.get_task(fresh_ref).status=='todo','offline resume keeps the task lane')
local reopened_new=assert(await(function(cb)api.start_agent(fresh_ref,{provider='claude'},cb)end))
assert(reopened_new and api.get_task(fresh_ref).status=='todo','starting a linked Claude task keeps its lane')
assert(api.delete_task(fresh_ref));assert(vim.uv.fs_stat(config..'/projects/repo/'..fresh_id..'.jsonl'),'delete preserves history')
agents={}
local legacy=assert(api.create_task({repo=repo,title='Legacy'}))
local legacy_ref={repo=repo,id=legacy.id}
local legacy_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
history(legacy_id)
local legacy_identity={provider='claude',runtime='herdr',server=herdr.server_key(),terminal_id='legacy',pane_id='legacy',name='legacy',session_id=legacy_id}
agents={{identity=legacy_identity,cwd=repo,state='idle'}}
local legacy_bound=assert(await(function(cb)api.bind_agent(legacy_ref,legacy_identity,cb)end))
assert(legacy_bound.conversation~=vim.NIL and legacy_bound.conversation.session_id==legacy_id,'legacy_native_promotion')
-- A pre-existing v1 link is promoted only when opening verifies native metadata.
local board_file=repo..'/.agent-board.json'
local doc=assert(storage.read(board_file,'board'))
for _,t in ipairs(doc.tasks) do if t.id==legacy.id then t.conversation=nil end end
doc.version=1
local f=assert(io.open(board_file,'w'));f:write(vim.json.encode(doc));f:close()
assert(await(function(cb)api.open_agent(legacy_ref,cb)end))
assert(api.get_task(legacy_ref).conversation~=vim.NIL,'v1_native_promotion_on_open')

agents={}
local empty=assert(api.create_task({repo=repo,title='No transcript'}))
local empty_ref={repo=repo,id=empty.id}
assert(await(function(cb)api.start_agent(empty_ref,{provider='claude'},cb)end))
assert(await(function(cb)api.stop_agent(empty_ref,cb)end))
local before_empty=starts
local unavailable,unavailable_error=await(function(cb)api.open_agent(empty_ref,cb)end)
assert(not unavailable and unavailable_error.code=='unavailable' and starts==before_empty,'empty new history cannot create fresh session')
local duplicate_live={identity={provider='claude',runtime='herdr',server=herdr.server_key(),terminal_id='dup1',pane_id='dup1',session_id=id},cwd=repo,state='idle'}
agents={duplicate_live,vim.deepcopy(duplicate_live)}
agents[2].identity.terminal_id='dup2';agents[2].identity.pane_id='dup2'
local ambiguous,ambiguous_error=await(function(cb)sessions.resolve(conversation,cb)end)
assert(not ambiguous and ambiguous_error.code=='ambiguous_runtime','multiple native matches')
agents={}
local _,_,snapshots=api.list_tasks({scope='repo',repo=repo})
assert(api.update_task({repo=repo,id=duplicate.id},{title='Changed'}))
local stale,stale_error=await(function(cb)api.bind_conversation({repo=repo,id=duplicate.id},conversation,snapshots[repo],cb)end)
assert(not stale and stale_error.code=='conflict','stale snapshot')
local saved_write=storage.write_locked
local writes=0
storage.write_locked=function(path,document,snapshot)
 if path==repo..'/.agent-board.json' then writes=writes+1;if writes==2 then return nil,'disk failure' end end
 return saved_write(path,document,snapshot)
end
local save_failed,save_error=await(function(cb)api.open_agent(ref,cb)end)
storage.write_locked=saved_write
assert(not save_failed and save_error.code=='save_failed' and save_error.agent,'save failure recovery')
assert(api.get_task(ref).conversation.session_id==id,'save failure preserves linked history')
-- A timeout carries a host; retry must not create another process.
agents={}
local timeout_task=assert(api.create_task({repo=repo,title='Timeout'}))
local timeout_ref={repo=repo,id=timeout_task.id}
start_error={code='runtime_unavailable',message='timeout',host={pane_id='pending'}}
local timed,timed_error=await(function(cb)api.start_agent(timeout_ref,{provider='claude'},cb)end)
assert(not timed and timed_error.host)
local before_retry=starts
local retry,retry_error=await(function(cb)api.start_agent(timeout_ref,{provider='claude'},cb)end)
assert(not retry and retry_error.code=='runtime_unknown' and starts==before_retry,'unknown start outcome')
package.loaded['agent-board.tasks']=nil
local reloaded=require('agent-board.tasks')
local restarted,restarted_error=await(function(cb)reloaded.start_agent(timeout_ref,{provider='claude'},cb)end)
assert(not restarted and restarted_error.code=='runtime_unknown' and starts==before_retry,'unknown outcome survives module restart')
start_error=nil
local repo2=tmp..'/other'
vim.fn.mkdir(repo2,'p');assert(vim.system({'git','init',repo2}):wait().code==0)
local cross_task=assert(api.create_task({repo=repo2,title='Cross repo'}))
-- The same Git repository through another registered worktree must still share uniqueness.
assert(vim.system({'git','-C',repo,'-c','user.name=Fixture','-c','user.email=fixture@example.test','commit','--allow-empty','-m','fixture'}):wait().code==0)
local worktree=tmp..'/worktree'
assert(vim.system({'git','-C',repo,'worktree','add','-b','fixture',worktree}):wait().code==0)
local cross=assert(api.create_task({repo=worktree,title='Cross worktree duplicate'}))
local cross_bound,cross_error=await(function(cb)api.bind_conversation({repo=worktree,id=cross.id},conversation,cb)end)
assert(not cross_bound and cross_error.code=='already_bound','cross registered repos uniqueness')
local unbound_id='cccccccc-cccc-4ccc-8ccc-cccccccccccc'
history(unbound_id)
local corrupt=assert(io.open(repo2..'/.agent-board.json','w'));corrupt:write('{broken');corrupt:close()
local blocked,blocked_error=await(function(cb)api.bind_conversation({repo=repo,id=duplicate.id},{provider='claude',session_id=unbound_id,cwd=repo},cb)end)
assert(not blocked and blocked_error.code=='board_unavailable','unreadable registered board cannot bypass uniqueness')
vim.fn.delete(repo2..'/.agent-board.json')
-- Offline v1 Claude links with verified metadata resume the same native UUID.
local legacy_offline_id='dddddddd-dddd-4ddd-8ddd-dddddddddddd'
history(legacy_offline_id)
local legacy_offline=assert(api.create_task({repo=repo,title='V1 offline Claude'}))
local legacy_ref={repo=repo,id=legacy_offline.id}
local legacy_board=assert(storage.read(repo..'/.agent-board.json','board'))
for _,row in ipairs(legacy_board.tasks)do if row.id==legacy_offline.id then
 row.agent={provider='claude',runtime='herdr',server=herdr.server_key(),terminal_id='legacy-offline-terminal',pane_id='legacy-offline-pane',name='legacy-offline',session_id=legacy_offline_id}
 row.conversation=nil
end end
legacy_board.version=1
local legacy_file=assert(io.open(repo..'/.agent-board.json','w'));legacy_file:write(vim.json.encode(legacy_board));legacy_file:close()
local legacy_before=starts
local legacy_open,legacy_open_error=await(function(cb)api.open_agent(legacy_ref,cb)end)
assert(legacy_open and not legacy_open_error and starts==legacy_before+1,'legacy v1 offline link resumes exact UUID: '..vim.inspect({legacy_open,legacy_open_error,starts,legacy_before}))
assert(api.get_task(legacy_ref).conversation.session_id==legacy_offline_id,'legacy promotion preserves native UUID')
assert(agents[#agents].identity.session_id==legacy_offline_id,'legacy resume keeps session identity')
-- Unverified legacy IDs cannot become implicit fresh Claude sessions.
local legacy_unverified=assert(api.create_task({repo=repo,title='Legacy without native UUID'}))
local unverified_ref={repo=repo,id=legacy_unverified.id}
local legacy_doc=assert(storage.read(repo..'/.agent-board.json','board'))
for _,row in ipairs(legacy_doc.tasks)do if row.id==legacy_unverified.id then
 row.agent={provider='claude',runtime='herdr',server=herdr.server_key(),terminal_id='legacy-no-id-terminal',pane_id='legacy-no-id-pane',name='legacy-no-id',session_id='not-a-uuid'}
end end
local legacy_file2=assert(io.open(repo..'/.agent-board.json','w'));legacy_file2:write(vim.json.encode(legacy_doc));legacy_file2:close()
local before_legacy_unverified=starts
local legacy_unverified_value,legacy_unverified_error=await(function(cb)api.start_agent(unverified_ref,{provider='claude'},cb)end)
assert(not legacy_unverified_value and legacy_unverified_error.code=='unavailable' and starts==before_legacy_unverified,'legacy without native ID must not spawn a replacement')
-- A live session can be bound before its first transcript record is written.
local live_only_id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
local live_only=assert(api.create_task({repo=repo,title='Live without transcript'}))
local live_ref={repo=repo,id=live_only.id}
local live_identity={provider='claude',runtime='herdr',server=herdr.server_key(),terminal_id='live-only-terminal',pane_id='live-only-pane',name='live-only',session_id=live_only_id}
agents={{identity=live_identity,cwd=repo,state='idle'}}
local live_discovery=assert(await(function(cb)api.list_sessions(live_ref,cb)end))
local live_row
for _,row in ipairs(live_discovery.sessions)do if row.conversation and row.conversation.session_id==live_only_id then live_row=row end end
assert(live_row and live_row.state=='running','live native session appears without transcript')
local live_bound=assert(await(function(cb)api.bind_conversation(live_ref,live_row.conversation,cb)end))
assert(live_bound.conversation.session_id==live_only_id and live_bound.agent.session_id==live_only_id,'live bind persists verified runtime identity')
local starts_before_change=starts
agents[1].identity.session_id='ffffffff-ffff-4fff-8fff-ffffffffffff'
local changed_live,changed_live_error=await(function(cb)api.open_agent(live_ref,cb)end)
assert(not changed_live and changed_live_error.code=='identity_mismatch' and starts==starts_before_change,'bound runtime identity change cannot spawn replacement')
agents={}
-- A runtime query failure does not prevent saving an already verified offline metadata link.
local bind_while_unknown_id='abababab-abab-4bab-8bab-abababababab'
history(bind_while_unknown_id)
local bind_while_unknown=assert(api.create_task({repo=repo,title='Bind while runtime unavailable'}))
list_error={code='runtime_unavailable',message='temporarily down'}
local unknown_discovery=assert(await(function(cb)api.list_sessions({repo=repo,id=bind_while_unknown.id},cb)end))
local unknown_row
for _,row in ipairs(unknown_discovery.sessions)do if row.conversation and row.conversation.session_id==bind_while_unknown_id then unknown_row=row end end
assert(unknown_row and unknown_row.state=='unknown','runtime failure is visible as unknown')
local unknown_bound=assert(await(function(cb)api.bind_conversation({repo=repo,id=bind_while_unknown.id},unknown_row.conversation,cb)end))
assert(unknown_bound.conversation.session_id==bind_while_unknown_id,'metadata can be bound while runtime state is unknown')
list_error=nil
-- Herdr failure before it returns a host is a definitive pre-launch failure and clears reservation.
local custom_lane=assert(api.add_lane(repo,'Review'))
local custom_task=assert(api.create_task({repo=repo,title='Custom lane Claude'}))
local custom_ref={repo=repo,id=custom_task.id}
assert(api.move_task(custom_ref,custom_lane.id))
local custom_started=assert(await(function(cb)api.start_agent(custom_ref,{provider='claude'},cb)end))
assert(custom_started.status==custom_lane.id,'new Claude start keeps a custom lane')
local custom_id=custom_started.conversation.session_id
history(custom_id)
assert(await(function(cb)api.stop_agent(custom_ref,cb)end))
assert(await(function(cb)api.open_agent(custom_ref,cb)end))
assert(api.get_task(custom_ref).status==custom_lane.id,'Claude resume keeps a custom lane')
local retry_task=assert(api.create_task({repo=repo,title='Prelaunch failure'}))
local retry_ref={repo=repo,id=retry_task.id}
assert(api.move_task(retry_ref,custom_lane.id))
start_error={code='runtime_unavailable',message='workspace list failed'}
local failed_prelaunch,prelaunch_error=await(function(cb)api.start_agent(retry_ref,{provider='claude'},cb)end)
assert(not failed_prelaunch and prelaunch_error.code=='runtime_unavailable','prelaunch failure returned')
assert(api.get_task(retry_ref).pending_start==nil and api.get_task(retry_ref).conversation==vim.NIL,'prelaunch failure releases reservation')
assert(api.get_task(retry_ref).status==custom_lane.id,'failed start keeps the custom lane')
start_error=nil
local retried=assert(await(function(cb)api.start_agent(retry_ref,{provider='claude'},cb)end))
assert(retried.status==custom_lane.id,'retry after confirmed prelaunch failure keeps the custom lane')
await(function(cb)api.stop_agent(retry_ref,cb)end)
vim.fn.delete(tmp,'rf')
print('conversation lifecycle checks passed')
vim.cmd('qa!')
