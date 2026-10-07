package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. '/config/projects/repo', 'p')
local repo = tmp .. '/repo'
vim.fn.mkdir(repo, 'p')
assert(vim.system({'git','init',repo}):wait().code == 0)
vim.env.CLAUDE_CONFIG_DIR = tmp .. '/config'
local id = '12345678-1234-4234-8234-123456789abc'
local path = tmp .. '/config/projects/repo/' .. id .. '.jsonl'
local function write(rows, suffix)
  local f = assert(io.open(path,'w'))
  for _, row in ipairs(rows) do f:write(vim.json.encode(row), '\n') end
  f:write(suffix or '') f:close()
end
local rows = {
  {type='user',sessionId=id,cwd=repo,timestamp='2026-10-07T00:00:00Z',message={content=string.rep('PRIVATE FIXTURE ',35000)}},
  {type='ai-title',sessionId=id,aiTitle='Saved task'},
  {type='assistant',sessionId=id,cwd=repo,timestamp='2026-10-07T01:00:00Z'},
  {type='user',sessionId='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',cwd=repo,isSidechain=true},
}
write(rows, '{broken')
local available, claude = pcall(require,'agent-board.claude')
assert(available, 'Claude metadata discovery is missing')
local function list()
  local result, warnings
  claude.list(repo,function(r,w) result,warnings=r,w end)
  assert(vim.wait(10000,function() return result ~= nil end), 'scan timeout')
  return result,warnings
end
local original_decode=vim.json.decode
local largest_decoded=0
vim.json.decode=function(raw,...)
  largest_decoded=math.max(largest_decoded,#raw)
  assert(#raw<4096,'transcript line must not be decoded as a full JSON object')
  return original_decode(raw,...)
end
local records = list()
vim.json.decode=original_decode
assert(largest_decoded<4096,'metadata-only decoding')
assert(#records == 1, 'metadata_scan: consolidate main session only')
assert(records[1].title == 'Saved task' and records[1].conversation.cwd == repo)
assert(records[1].updated_at == '2026-10-07T01:00:00Z' and records[1].resumable)
assert(records[1].conversation.session_id == id, 'partial_record: valid preceding records retained')
rows[#rows+1] = {type='ai-title',sessionId=id,aiTitle='Updated task'}
write(rows)
assert(list()[1].title == 'Updated task','cache_invalidation')
local other = tmp .. '/other/repo'
vim.fn.mkdir(other,'p')
assert(vim.system({'git','init',other}):wait().code == 0)
local out
claude.list(other,function(r) out=r end)
assert(vim.wait(10000,function() return out ~= nil end))
assert(#out == 0,'repo_membership: unrelated same-name repo excluded')
local seen={}
for _=1,100 do local uuid=claude.new_session_id(); assert(uuid:match('^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$') and not seen[uuid]);seen[uuid]=true end
-- Oversized and malformed lines must preserve useful metadata and yield a warning.
write(rows, '\n' .. string.rep('x',1024*1024+1) .. '\n')
local bounded,warnings=list()
assert(#bounded == 1 and #warnings > 0,'resource_bounds')
-- Git worktrees share history, independent clones do not.
assert(vim.system({'git','-C',repo,'-c','user.name=Fixture','-c','user.email=fixture@example.test','commit','--allow-empty','-m','fixture'}):wait().code == 0)
local worktree=tmp .. '/worktree'
assert(vim.system({'git','-C',repo,'worktree','add','-b','fixture',worktree}):wait().code == 0)
rows[1].cwd=worktree;rows[3].cwd=worktree
write(rows)
assert(list()[1].conversation.cwd==worktree,'repo_membership: worktree accepted with original cwd')
local missing=repo .. '/removed'
rows[1].cwd=missing;rows[3].cwd=missing
write(rows)
local unavailable=list()
assert(#unavailable==1 and not unavailable[1].resumable and unavailable[1].conversation.cwd==missing,'missing_cwd')
local no_cwd_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
write({{type='user',sessionId=no_cwd_id,timestamp='2026-10-07T02:00:00Z'}})
local no_cwd_records,no_cwd_warnings=list()
assert(#no_cwd_records==0 and #no_cwd_warnings>0,'missing_cwd cannot be assigned to a repo without evidence')
vim.env.CLAUDE_CONFIG_DIR=tmp .. '/empty'
assert(#list()==0,'config_override')
vim.env.CLAUDE_CONFIG_DIR=tmp .. '/config'
rows[1].cwd=repo;rows[3].cwd=repo
write(rows, '\n' .. string.rep('x',17*1024*1024))
local ticks=0
local timer=vim.uv.new_timer()
timer:start(0,1,vim.schedule_wrap(function() ticks=ticks+1 end))
local large,partial=list()
timer:stop();timer:close()
assert(#large==1 and #partial>0 and ticks>1,'scheduler responsiveness and streamed file bounds')
-- The file-count cap retains records and warns instead of exhausting resources.
for n=1,2050 do local f=assert(io.open(tmp..'/config/projects/repo/empty-'..n..'.jsonl','w'));f:close() end
local capped,cap_warnings=list()
assert(#cap_warnings>0,'top-level file bound')
vim.fn.delete(tmp,'rf')
print('claude session checks passed')
vim.cmd('qa!')
