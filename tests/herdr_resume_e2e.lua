package.path='./lua/?.lua;./lua/?/init.lua;'..package.path
local project=vim.fn.getcwd()
local tmp='/tmp/ab-'..vim.uv.os_getpid()..'-'..tostring(vim.uv.hrtime()):sub(-5)
vim.fn.mkdir(tmp..'/bin','p')
vim.fn.mkdir(tmp..'/repo','p')
local function write(path,text)
 local f=assert(io.open(path,'w'));f:write(text);f:close()
end
assert(vim.system({'git','init',tmp..'/repo'}):wait().code==0)
local session='ab-'..vim.uv.os_getpid()
vim.env.HERDR_SESSION=session
local socket=tmp..'/config/herdr/sessions/'..session..'/herdr.sock'
vim.env.HERDR_SOCKET_PATH=socket
vim.env.HERDR_CONFIG_PATH=tmp..'/config.toml'
vim.env.CLAUDE_CONFIG_DIR=tmp..'/claude'
vim.env.XDG_STATE_HOME=tmp..'/state'
vim.env.XDG_DATA_HOME=tmp..'/data'
vim.env.XDG_CONFIG_HOME=tmp..'/config'
vim.env.AGENT_BOARD_FIXTURE=tmp
vim.env.PATH=tmp..'/bin:'..vim.env.PATH
vim.fn.mkdir(tmp..'/claude/projects/repo','p')
write(tmp..'/config.toml', 'onboarding = false\n[terminal]\ndefault_shell = "/bin/bash"\nshell_mode = "non_login"\n[update]\nversion_check = false\nmanifest_check = false\n[experimental]\nallow_nested = true\n')
write(tmp..'/bin/claude', [[#!/usr/bin/python3
import os,sys,json,subprocess
root=os.environ['AGENT_BOARD_FIXTURE']
args=sys.argv[1:]
mode=next((x for x in args if x in ('--session-id','--resume')),None)
if not mode: sys.exit(3)
uuid=args[args.index(mode)+1]
with open(root+'/argv.jsonl','a') as f: f.write(json.dumps(args)+'\n')
path=os.environ['CLAUDE_CONFIG_DIR']+'/projects/repo/'+uuid+'.jsonl'
with open(path,'a') as f: f.write(json.dumps({'type':'user','sessionId':uuid,'cwd':os.getcwd(),'timestamp':'2026-10-07T00:00:00Z'})+'\n')
pane=os.environ['HERDR_PANE_ID']
subprocess.run(['herdr','pane','report-agent',pane,'--source','herdr:claude','--agent','claude','--state','idle','--agent-session-id',uuid],check=True,stdout=subprocess.DEVNULL)
print('Claude fixture ready '+uuid,flush=True)
for line in sys.stdin:
 text=line.rstrip('\n')
 with open(root+'/input.jsonl','a') as f:f.write(json.dumps({'id':uuid,'text':text})+'\n')
 if text=='exit':break
 print('fixture received '+text,flush=True)
]])
vim.uv.fs_chmod(tmp..'/bin/claude',493)
local server_result
local server=vim.system({'herdr','--session',session,'server'},{text=true},function(result) server_result=result end)
local function command(args)
 local cmd={'herdr'};vim.list_extend(cmd,args)
 return vim.system(cmd,{text=true,timeout=5000}):wait()
end
local function request(args)
 local result=command(args)
 assert(result.code==0,result.stderr)
 return vim.json.decode(result.stdout).result
end
local ok,err=xpcall(function()
 assert(vim.wait(10000,function() return vim.uv.fs_stat(socket)~=nil end),'isolated server socket timeout: '..tmp..' '..vim.inspect(server_result))
 local storage=require('agent-board.storage')
 storage.registry_path=function()return tmp..'/registry.json'end
 local api=require('agent-board')
 local herdr=require('agent-board.herdr')
 local uuid='12345678-1234-4234-8234-123456789abc'
 write(tmp..'/claude/projects/repo/'..uuid..'.jsonl',vim.json.encode({type='user',sessionId=uuid,cwd=tmp..'/repo'})..'\n')
 local function await(fn)
  local done,value,failure=false,nil,nil
  fn(function(v,e)value,failure,done=v,e,true end)
  assert(vim.wait(45000,function()return done end),'operation timeout')
  assert(value,vim.inspect(failure))
  return value
 end
 local origin=request({'workspace','create','--cwd',tmp..'/repo','--label','fixture-origin'})
 local before=request({'api','snapshot'})
 write(project..'/docs/herdr-before.json',vim.json.encode(before))
 local task=assert(api.create_task({repo=tmp..'/repo',title='Fixture conversation'}))
 local ref={repo=tmp..'/repo',id=task.id}
 await(function(cb)api.bind_conversation(ref,{provider='claude',session_id=uuid,cwd=ref.repo},cb)end)
 assert(api.focus_board({scope='repo',repo=ref.repo}))
 local board_buf=vim.api.nvim_get_current_buf()
 local board_tab=vim.api.nvim_get_current_tabpage()
 local opened=await(function(cb)api.open_agent(ref,cb,{tabpage=board_tab,label=task.title})end)
 local config=vim.api.nvim_win_get_config(0)
 assert(config.relative=='editor' and config.title and config.footer,'real float ownership')
 assert(vim.api.nvim_buf_is_valid(board_buf),'board retained underneath')
 assert(api.get_task(ref).conversation.session_id==uuid)
 local buf=vim.api.nvim_get_current_buf()
 assert(vim.wait(10000,function()
   if not vim.api.nvim_buf_is_valid(buf) then return false end
   local text=table.concat(vim.api.nvim_buf_get_lines(buf,0,-1,false),'\n')
   return text:find('Claude fixture ready',1,true)~=nil
 end),'real attach frames missing')
 local entry_key=table.concat({ref.repo,ref.id,'herdr'},'\0')
 assert(require('agent-board.terminal').is_open(entry_key),'attach must stay live')
 local channel=vim.bo[buf].channel
 vim.api.nvim_chan_send(channel,'fixture-input\r')
 assert(vim.wait(10000,function()
   local f=io.open(tmp..'/input.jsonl','r');if not f then return false end
   local data=f:read('*a');f:close();return data:find('fixture-input',1,true)~=nil
 end),'typed terminal input not received')
 local conflict=command({'terminal','session','control',opened.identity.terminal_id})
 write(project..'/docs/herdr-controller-conflict.txt',vim.inspect(conflict))
 local conflict_event=vim.json.decode(conflict.stdout)
 assert(conflict_event.type=='terminal.closed' and conflict_event.reason:find('already has an attached client',1,true),'second controller must not take over')
 local duplicate_buf=vim.api.nvim_create_buf(false,true)
 local duplicate_done,duplicate_exit=false,nil
 vim.api.nvim_buf_call(duplicate_buf,function()
   vim.fn.termopen({'herdr','terminal','attach',opened.identity.terminal_id},{on_exit=function(_,code)duplicate_exit=code;duplicate_done=true end})
 end)
 assert(vim.wait(5000,function()return duplicate_done end),'second direct attach should be rejected')
 local duplicate_output=table.concat(vim.api.nvim_buf_get_lines(duplicate_buf,0,-1,false),'\n')
 write(project..'/docs/herdr-direct-attach-conflict.txt',duplicate_output..'\nexit='..tostring(duplicate_exit))
 local normalized_duplicate_output=duplicate_output:gsub('%s+','')
 assert(normalized_duplicate_output:find('alreadyhasanattachedclient',1,true),'direct attach conflict should be visible in terminal output: '..duplicate_output)
 vim.api.nvim_buf_delete(duplicate_buf,{force=true})
 assert(api.hide_agent(ref))
 assert(vim.api.nvim_buf_is_valid(buf),'hide retains attach buffer')
 await(function(cb)api.open_agent(ref,cb,{tabpage=board_tab,label=task.title})end)
 assert(vim.api.nvim_get_current_buf()==buf,'hide/reopen reuse actual attach job')
 write(project..'/docs/herdr-outside-terminal.txt',table.concat(vim.api.nvim_buf_get_lines(buf,0,-1,false),'\n'))
 vim.api.nvim_chan_send(channel,'exit\r')
 assert(vim.wait(10000,function()return #request({'agent','list'}).agents==0 end),'fixture Claude did not exit')
 local resumed=await(function(cb)api.open_agent(ref,cb,{tabpage=board_tab,label=task.title})end)
 assert(resumed.identity.terminal_id~=opened.identity.terminal_id,'exit/resume replaces runtime')
 assert(api.get_task(ref).conversation.session_id==uuid,'exit retains conversation')
 await(function(cb)api.stop_agent(ref,cb)end)
 local stopped_resume=await(function(cb)api.open_agent(ref,cb,{tabpage=board_tab,label=task.title})end)
 assert(stopped_resume.identity.terminal_id~=resumed.identity.terminal_id,'stop/resume replaces runtime')
 local after=request({'api','snapshot'})
 write(project..'/docs/herdr-after.json',vim.json.encode(after))
 for _,key in ipairs({'focused_workspace_id','focused_tab_id','focused_pane_id'}) do
   assert(before.snapshot[key]==after.snapshot[key],'direct attach changed outer Herdr focus: '..key)
 end
 -- End only this Neovim attach client, leaving the fixture runtime alive.
 local last_buf=vim.api.nvim_get_current_buf()
 vim.fn.jobstop(vim.bo[last_buf].channel)
 assert(vim.wait(10000,function()return not require('agent-board.terminal').is_open(entry_key)end))
 local child=tmp..'/child.lua'
 write(tmp..'/ref.json',vim.json.encode(ref))
 write(child,string.format([=[
package.path=%q..'/lua/?.lua;'..%q..'/lua/?/init.lua;'..package.path
local tmp=vim.env.AGENT_BOARD_FIXTURE
local storage=require('agent-board.storage')
storage.registry_path=function()return tmp..'/registry.json'end
local file=assert(io.open(tmp..'/ref.json','r'));local ref=vim.json.decode(file:read('*a'));file:close()
local api=require('agent-board')
local done,value,err=false,nil,nil
assert(api.focus_board({scope='repo',repo=ref.repo}))
local board_buf=vim.api.nvim_get_current_buf()
api.open_agent(ref,function(v,e)value,err,done=v,e,true end)
assert(vim.wait(10000,function()return done end), 'child attach timeout')
assert(value,vim.inspect(err))
local buf=vim.api.nvim_get_current_buf()
assert(vim.api.nvim_win_get_config(0).relative=='editor' and vim.api.nvim_buf_is_valid(board_buf),'child board float')
assert(vim.wait(10000,function()
 if not vim.api.nvim_buf_is_valid(buf) then return false end
 return table.concat(vim.api.nvim_buf_get_lines(buf,0,-1,false),'\n'):find('Claude fixture ready',1,true)~=nil
end),'child attach frames')
local f=assert(io.open(tmp..'/'..vim.env.AGENT_BOARD_CHILD_MODE..'.capture','w'))
f:write(table.concat(vim.api.nvim_buf_get_lines(buf,0,-1,false),'\n'));f:close()
local f=assert(io.open(tmp..'/'..vim.env.AGENT_BOARD_CHILD_MODE..'.done','w'));f:write(value.identity.terminal_id);f:close()
vim.cmd('qa!')
]=],project,project))
 vim.env.AGENT_BOARD_CHILD_MODE='restart'
 local child_result=vim.system({'nvim','--headless','-u','NONE','-l',child},{text=true,timeout=20000}):wait()
 assert(child_result.code==0,child_result.stderr)
 assert(vim.uv.fs_stat(tmp..'/restart.done'),'independent Neovim restart completion')
 vim.env.AGENT_BOARD_CHILD_MODE='inside'
 -- The origin shell inherits the fixture environment but not the newly set mode.
 local shell_command='AGENT_BOARD_CHILD_MODE=inside nvim -u NONE -c '..vim.fn.shellescape('lua dofile('..string.format('%q',child)..')')
 local run_result=command({'pane','run',origin.root_pane.pane_id,shell_command})
 assert(run_result.code==0,run_result.stderr)
 assert(vim.wait(20000,function()return vim.uv.fs_stat(tmp..'/inside.done')~=nil end),'Neovim inside Herdr failed')
 local capture=assert(io.open(tmp..'/inside.capture','r'));write(project..'/docs/herdr-inside-terminal.txt',capture:read('*a'));capture:close()
 local final_focus=request({'api','snapshot'}).snapshot
 assert(final_focus.focused_pane_id==before.snapshot.focused_pane_id,'inside attach switched outer focus')
 local argv=assert(io.open(tmp..'/argv.jsonl','r'));local calls={}
 for line in argv:lines()do calls[#calls+1]=vim.json.decode(line)end;argv:close()
 assert(#calls==3,'offline/exit/stop must create exactly three runtime starts')
 for _,args in ipairs(calls)do assert(args[1]=='--resume' and args[2]==uuid,'exact native resume UUID')end
 await(function(cb)api.stop_agent(ref,cb)end)
 local fresh=assert(api.create_task({repo=ref.repo,title='New fixture conversation'}))
 local fresh_ref={repo=ref.repo,id=fresh.id}
 local started_done,started_value,started_error=false,nil,nil
 api.start_agent(fresh_ref,{provider='claude'},function(v,e)started_value,started_error,started_done=v,e,true end)
 local duplicate_done,duplicate_error=false,nil
 api.start_agent(fresh_ref,{provider='claude'},function(v,e)assert(not v);duplicate_error=e;duplicate_done=true end)
 assert(vim.wait(10000,function()return duplicate_done end) and duplicate_error.code=='locked','real double start blocked')
 assert(vim.wait(45000,function()return started_done end) and started_value,vim.inspect(started_error))
 local fresh_uuid=started_value.conversation.session_id
 assert(fresh_uuid~=uuid and started_value.status=='todo','native new conversation stays in its current lane')
 await(function(cb)api.open_agent(fresh_ref,cb,{tabpage=board_tab,label=fresh.title})end)
 local fresh_buf=vim.api.nvim_get_current_buf()
 assert(vim.wait(10000,function()
   if not vim.api.nvim_buf_is_valid(fresh_buf)then return false end
   return table.concat(vim.api.nvim_buf_get_lines(fresh_buf,0,-1,false),'\n'):find('Claude fixture ready',1,true)~=nil
 end),'fresh attach frames')
 vim.api.nvim_chan_send(vim.bo[fresh_buf].channel,'exit\r')
 assert(vim.wait(10000,function()return #request({'agent','list'}).agents==0 end),'new fixture exit')
 await(function(cb)api.open_agent(fresh_ref,cb,{tabpage=board_tab,label=fresh.title})end)
 assert(api.get_task(fresh_ref).conversation.session_id==fresh_uuid,'new/exit/resume UUID preserved')
 await(function(cb)api.stop_agent(fresh_ref,cb)end)
 local all_args=assert(io.open(tmp..'/argv.jsonl','r'));local modes={}
 for line in all_args:lines()do modes[#modes+1]=vim.json.decode(line)end;all_args:close()
 assert(#modes==5 and modes[4][1]=='--session-id' and modes[4][2]==fresh_uuid and modes[5][1]=='--resume' and modes[5][2]==fresh_uuid,'actual new/resume argv and one-start concurrency')
 print('Herdr conversation resume acceptance passed')
end,debug.traceback)
pcall(function() require('agent-board.board').close() end)
command({'server','stop'})
server:wait(5000)
if not ok then error(err..'\nFixture: '..tmp) end
vim.fn.delete(tmp,'rf')
vim.cmd('qa!')
