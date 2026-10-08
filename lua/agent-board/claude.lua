local M = {}
local uv = vim.uv
local cache = {}
local function error_value(code, message) return {code=code,message=message} end
function M.valid_id(id)
  return type(id)=='string' and id:match('^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$') ~= nil
end
function M.new_session_id()
  local bytes = assert(uv.random(16))
  local b = {bytes:byte(1,16)}
  b[7] = 64 + b[7]%16
  b[9] = 128 + b[9]%64
  local hex = {}
  for i,v in ipairs(b) do hex[i]=string.format('%02x',v) end
  return table.concat(hex,'',1,4)..'-'..table.concat(hex,'',5,6)..'-'..table.concat(hex,'',7,8)..'-'..table.concat(hex,'',9,10)..'-'..table.concat(hex,'',11,16)
end
function M.repo_identity(cwd, callback)
  if type(cwd) ~= 'string' or cwd:sub(1,1) ~= '/' then
    return vim.schedule(function() callback(nil,error_value('unavailable','Session cwd is unavailable')) end)
  end
  vim.system({'git','-C',cwd,'rev-parse','--show-toplevel','--git-common-dir'}, {text=true}, function(result)
    vim.schedule(function()
      local root,common = (result.stdout or ''):match('([^\n]+)\n([^\n]+)')
      if result.code ~= 0 or not root or not common then return callback(nil,error_value('unavailable','Session repository is unavailable')) end
      if common:sub(1,1) ~= '/' then common=cwd..'/'..common end
      root,common=uv.fs_realpath(root),uv.fs_realpath(common)
      if not root or not common then return callback(nil,error_value('unavailable','Session repository is unavailable')) end
      callback({root=root,common_dir=common})
    end)
  end)
end
local function stat_key(s)
  return s.size..':'..s.mtime.sec..':'..s.mtime.nsec
end
local captured_keys = { type=true, sessionId=true, session_id=true, cwd=true, timestamp=true, isSidechain=true, aiTitle=true }

local function whitespace(data, pos)
  while data:sub(pos,pos)==' ' or data:sub(pos,pos)=='\t' or data:sub(pos,pos)=='\r' or data:sub(pos,pos)=='\n' do pos=pos+1 end
  return pos
end

local function string_end(data, pos)
  if data:sub(pos,pos)~='"' then return nil end
  local i=pos+1
  while i<=#data do
    local byte=data:byte(i)
    if byte==34 then return i+1 end
    if byte==92 then
      local escape=data:sub(i+1,i+1)
      if escape=='u' then
        if not data:sub(i+2,i+5):match('^%x%x%x%x$') then return nil end
        i=i+6
      elseif escape:match('^["\\/bfnrt]$') then i=i+2
      else return nil end
    elseif byte<32 then return nil
    else i=i+1 end
  end
  return nil
end

local function number_end(data, pos)
  local i=pos
  if data:sub(i,i)=='-' then i=i+1 end
  if data:sub(i,i)=='0' then i=i+1
  elseif data:sub(i,i):match('[1-9]') then
    repeat i=i+1 until not data:sub(i,i):match('%d')
  else return nil end
  if data:sub(i,i)=='.' then
    i=i+1
    if not data:sub(i,i):match('%d') then return nil end
    repeat i=i+1 until not data:sub(i,i):match('%d')
  end
  if data:sub(i,i):match('[eE]') then
    i=i+1
    if data:sub(i,i):match('[+-]') then i=i+1 end
    if not data:sub(i,i):match('%d') then return nil end
    repeat i=i+1 until not data:sub(i,i):match('%d')
  end
  return i
end

local parse_value
parse_value=function(data,pos,capture,depth)
  if depth>128 then return nil,nil,nil end
  pos=whitespace(data,pos)
  local char=data:sub(pos,pos)
  if char=='"' then
    local after=string_end(data,pos)
    if not after then return nil,nil,nil end
    if capture and after-pos<=65538 then
      local ok,value=pcall(vim.json.decode,data:sub(pos,after-1))
      if not ok or type(value)~='string' then return nil,nil,nil end
      return value,after,'string'
    end
    return nil,after,'string'
  end
  if char=='{' or char=='[' then
    local object=char=='{'
    local close=object and '}' or ']'
    pos=whitespace(data,pos+1)
    if data:sub(pos,pos)==close then return nil,pos+1,object and 'object' or 'array' end
    while true do
      if object then
        local key_after=string_end(data,pos)
        if not key_after then return nil,nil,nil end
        pos=whitespace(data,key_after)
        if data:sub(pos,pos)~=':' then return nil,nil,nil end
        pos=pos+1
      end
      local _,after,kind=parse_value(data,pos,false,depth+1)
      if not after then return nil,nil,nil end
      pos=whitespace(data,after)
      local delimiter=data:sub(pos,pos)
      if delimiter==close then return nil,pos+1,object and 'object' or 'array' end
      if delimiter~=',' then return nil,nil,nil end
      pos=whitespace(data,pos+1)
    end
  end
  if data:sub(pos,pos+3)=='true' then return true,pos+4,'boolean' end
  if data:sub(pos,pos+4)=='false' then return false,pos+5,'boolean' end
  if data:sub(pos,pos+3)=='null' then return nil,pos+4,'null' end
  local after=number_end(data,pos)
  if after then return nil,after,'number' end
  return nil,nil,nil
end

local function utf8_char(codepoint)
  if codepoint<0x80 then return string.char(codepoint) end
  if codepoint<0x800 then return string.char(0xC0+math.floor(codepoint/0x40),0x80+codepoint%0x40) end
  if codepoint<0x10000 then return string.char(0xE0+math.floor(codepoint/0x1000),0x80+math.floor(codepoint/0x40)%0x40,0x80+codepoint%0x40) end
  return string.char(0xF0+math.floor(codepoint/0x40000),0x80+math.floor(codepoint/0x1000)%0x40,0x80+math.floor(codepoint/0x40)%0x40,0x80+codepoint%0x40)
end

local function preview_string(data,pos)
  local after=string_end(data,pos)
  if not after then return nil,nil end
  local result,bytes,i={},0,pos+1
  local limit=1197
  while i<after-1 and bytes<limit do
    local byte=data:byte(i)
    local value,step
    if byte==92 then
      local escape=data:sub(i+1,i+1)
      if escape=='u' then
        local codepoint=tonumber(data:sub(i+2,i+5),16)
        step=6
        if codepoint>=0xD800 and codepoint<=0xDBFF and data:sub(i+6,i+7)=='\\u' then
          local low=tonumber(data:sub(i+8,i+11),16)
          if low and low>=0xDC00 and low<=0xDFFF then codepoint=0x10000+(codepoint-0xD800)*0x400+(low-0xDC00);step=12 end
        end
        if codepoint>=0xD800 and codepoint<=0xDFFF then codepoint=0xFFFD end
        value=utf8_char(codepoint)
      else
        value=({['"']='"',['\\']='\\',['/']='/',b=' ',f=' ',n='\n',r='\r',t='\t'})[escape] or ' '
        step=2
      end
    else
      step=byte<0x80 and 1 or (byte<0xE0 and 2 or (byte<0xF0 and 3 or 4))
      value=data:sub(i,i+step-1)
    end
    if bytes+#value>limit then break end
    result[#result+1]=value
    bytes=bytes+#value
    i=i+step
  end
  if i<after-1 then result[#result+1]='…' end
  return table.concat(result),after
end

local function parse_text_block(data,pos)
  if data:sub(pos,pos)~='{' then return nil,nil end
  local kind,text
  pos=whitespace(data,pos+1)
  if data:sub(pos,pos)=='}' then return nil,pos+1 end
  while true do
    local key_after=string_end(data,pos)
    if not key_after then return nil,nil end
    local key=preview_string(data,pos)
    pos=whitespace(data,key_after)
    if data:sub(pos,pos)~=':' then return nil,nil end
    local value_pos=whitespace(data,pos+1)
    local after
    if (key=='type' or key=='text') and data:sub(value_pos,value_pos)=='"' then
      local value
      value,after=preview_string(data,value_pos)
      if key=='type' then kind=value else text=value end
    else
      local _,parsed=parse_value(data,value_pos,false,1)
      after=parsed
    end
    if not after then return nil,nil end
    pos=whitespace(data,after)
    local delimiter=data:sub(pos,pos)
    if delimiter=='}' then return kind=='text' and text or nil,pos+1 end
    if delimiter~=',' then return nil,nil end
    pos=whitespace(data,pos+1)
  end
end

local function parse_content(data,pos)
  local char=data:sub(pos,pos)
  if char=='"' then return preview_string(data,pos) end
  if char~='[' then local _,after=parse_value(data,pos,false,1);return nil,after end
  local texts={}
  pos=whitespace(data,pos+1)
  if data:sub(pos,pos)==']' then return nil,pos+1 end
  while true do
    local value,after
    if data:sub(pos,pos)=='{' then value,after=parse_text_block(data,pos)
    else local _,parsed=parse_value(data,pos,false,1);after=parsed end
    if not after then return nil,nil end
    if value and value~='' then texts[#texts+1]=value end
    pos=whitespace(data,after)
    local delimiter=data:sub(pos,pos)
    if delimiter==']' then
      local joined=table.concat(texts,' ')
      return joined~='' and joined or nil,pos+1
    end
    if delimiter~=',' then return nil,nil end
    pos=whitespace(data,pos+1)
  end
end

local function parse_message(data,pos)
  if data:sub(pos,pos)~='{' then local _,after=parse_value(data,pos,false,1);return nil,after end
  local content
  pos=whitespace(data,pos+1)
  if data:sub(pos,pos)=='}' then return nil,pos+1 end
  while true do
    local key_after=string_end(data,pos)
    if not key_after then return nil,nil end
    local key=preview_string(data,pos)
    pos=whitespace(data,key_after)
    if data:sub(pos,pos)~=':' then return nil,nil end
    local value_pos=whitespace(data,pos+1)
    local after,value
    if key=='content' then value,after=parse_content(data,value_pos)
    else local _,parsed=parse_value(data,value_pos,false,1);after=parsed end
    if not after then return nil,nil end
    if key=='content' then content=value end
    pos=whitespace(data,after)
    local delimiter=data:sub(pos,pos)
    if delimiter=='}' then return content,pos+1 end
    if delimiter~=',' then return nil,nil end
    pos=whitespace(data,pos+1)
  end
end

local function parse_metadata(data)
  local pos=whitespace(data,1)
  if data:sub(pos,pos)~='{' then return nil end
  local result={}
  pos=whitespace(data,pos+1)
  if data:sub(pos,pos)=='}' then return nil end
  while true do
    local key_after=string_end(data,pos)
    if not key_after then return nil end
    local key
    if key_after-pos<=130 then
      local ok,value=pcall(vim.json.decode,data:sub(pos,key_after-1))
      if ok and type(value)=='string' then key=value end
    end
    pos=whitespace(data,key_after)
    if data:sub(pos,pos)~=':' then return nil end
    local wanted=key and captured_keys[key]
    local value,after,kind
    if key=='message' then value,after=parse_message(data,whitespace(data,pos+1));kind='object'
    else value,after,kind=parse_value(data,pos+1,wanted,1) end
    if not after then return nil end
    if wanted and ((kind=='string' and type(value)=='string') or (key=='isSidechain' and kind=='boolean')) then result[key]=value end
    if key=='message' then result.preview_text=value end
    pos=whitespace(data,after)
    local delimiter=data:sub(pos,pos)
    if delimiter=='}' then
      pos=whitespace(data,pos+1)
      return pos>#data and result or nil
    end
    if delimiter~=',' then return nil end
    pos=whitespace(data,pos+1)
  end
end

local function merge_preview(record, role, text, timestamp)
  if (role~='user' and role~='assistant') or type(text)~='string' then return end
  text=text:gsub('[%z\1-\9\11-\31\127]+',' '):gsub('[ \t]+',' '):gsub(' *\n *','\n'):gsub('\n+','\n'):gsub('^%s+',''):gsub('%s+$','')
  if text=='' then return end
  record.preview=record.preview or {}
  local current=record.preview[role]
  timestamp=type(timestamp)=='string' and timestamp or ''
  if not current or timestamp=='' or not current.timestamp or timestamp>=current.timestamp then
    record.preview[role]={text=text,timestamp=timestamp}
  end
end

local function scan_file(path, callback)
  uv.fs_stat(path,function(err,stat)
    if err then return vim.schedule(function() callback({},true) end) end
    local key=stat_key(stat)
    if cache[path] and cache[path].key==key then return vim.schedule(function() callback(vim.deepcopy(cache[path].records),cache[path].partial) end) end
    uv.fs_open(path,'r',0,function(open_error,fd)
      if open_error then return vim.schedule(function() callback({},true) end) end
      local offset,pending,discard,partial=0,'',false,false
      local records={}
      local function line(data)
        if #data>1024*1024 then partial=true;return end
        local row=parse_metadata(data)
        if not row then if data~='' then partial=true end;return end
        local id=row.sessionId or row.session_id
        if row.isSidechain or not M.valid_id(id) then return end
        local record=records[id] or {conversation={provider='claude',session_id=id},title=id}
        records[id]=record
        if type(row.cwd)=='string' and row.cwd:sub(1,1)=='/' then record.conversation.cwd=row.cwd end
        if row.type=='ai-title' and type(row.aiTitle)=='string' and row.aiTitle~='' then record.title=row.aiTitle end
        if type(row.timestamp)=='string' and row.timestamp:match('^%d%d%d%d%-%d%d%-%d%dT') and (not record.updated_at or row.timestamp>record.updated_at) then record.updated_at=row.timestamp end
        merge_preview(record,row.type,row.preview_text,row.timestamp)
      end
      local function finish()
        if pending~='' and not discard then line(pending) end
        uv.fs_close(fd,function()
          uv.fs_stat(path,function(_,after)
            vim.schedule(function()
              local result={}
              for _,r in pairs(records) do result[#result+1]=r end
              if after and stat_key(after)==key then cache[path]={key=key,records=vim.deepcopy(result),partial=partial} else partial=true end
              callback(result,partial)
            end)
          end)
        end)
      end
      local read
      read=function()
        if offset>=16*1024*1024 then partial=true;return finish() end
        uv.fs_read(fd,65536,offset,function(read_error,data)
          vim.schedule(function()
            if read_error or not data or #data==0 then if read_error then partial=true end;return finish() end
            offset=offset+#data
            local start=1
            while true do
              local nl=data:find('\n',start,true)
              local piece=data:sub(start,nl and nl-1 or #data)
              if not discard then
                pending=pending..piece
                if #pending>1024*1024 then pending='';discard=true;partial=true end
              end
              if not nl then break end
              if not discard then line(pending) end
              pending='';discard=false;start=nl+1
            end
            read()
          end)
        end)
      end
      read()
    end)
  end)
end
function M.list(repo, callback)
  local base=vim.env.CLAUDE_CONFIG_DIR
  if not base or base=='' then base=vim.fn.expand('~/.claude') end
  base=vim.fs.normalize(base)..'/projects'
  M.repo_identity(repo,function(target,identity_error)
    if not target then return callback({}, {identity_error.message}) end
    uv.fs_scandir(base,function(scan_error,handle)
      if scan_error then return vim.schedule(function() callback({}, {}) end) end
      local dirs={}
      while true do local name,kind=uv.fs_scandir_next(handle);if not name then break end;if kind=='directory' then dirs[#dirs+1]=base..'/'..name end end
      table.sort(dirs)
      local files,warnings={},{}
      local index=0
      local function collect()
        index=index+1
        if not dirs[index] then
          local merged,cursor={},0
          local function next_file()
            cursor=cursor+1
            if not files[cursor] then
              local candidates={}
              for _,r in pairs(merged) do candidates[#candidates+1]=r end
              local result,at={},0
              local function match_next()
                at=at+1
                local r=candidates[at]
                if not r then table.sort(result,function(a,b) return (a.updated_at or '')>(b.updated_at or '') end);return callback(result,warnings) end
                local cwd=r.conversation.cwd
                if not cwd then warnings[#warnings+1]='Claude session without cwd cannot be matched to a repository';return match_next() end
                M.repo_identity(cwd,function(identity)
                  if identity and (identity.root==target.root or identity.common_dir==target.common_dir) then r.resumable=true;result[#result+1]=r
                  elseif not identity and cwd:sub(1,#target.root)==target.root and (cwd==target.root or cwd:sub(#target.root+1,#target.root+1)=='/') then r.resumable=false;r.reason='Original session cwd is missing';result[#result+1]=r end
                  match_next()
                end)
              end
              return match_next()
            end
            scan_file(files[cursor],function(records,partial)
              if partial then warnings[#warnings+1]='Partial Claude metadata scan: '..vim.fs.basename(files[cursor]) end
              for _,r in ipairs(records) do
                local id=r.conversation.session_id
                local old=merged[id]
                if not old then merged[id]=r else
                  if r.conversation.cwd then old.conversation.cwd=r.conversation.cwd end
                  if r.title~=id then old.title=r.title end
                  if r.updated_at and (not old.updated_at or r.updated_at>old.updated_at) then old.updated_at=r.updated_at end
                  for role,message in pairs(r.preview or {}) do
                    old.preview=old.preview or {}
                    local current=old.preview[role]
                    if not current or not message.timestamp or not current.timestamp or message.timestamp>=current.timestamp then
                      old.preview[role]=message
                    end
                  end
                end
              end
              next_file()
            end)
          end
          return next_file()
        end
        uv.fs_scandir(dirs[index],function(err,dir)
          if not err then while true do local name,kind=uv.fs_scandir_next(dir);if not name then break end
            if kind=='file' and name:match('%.jsonl$') then
              if #files>=2048 then warnings[#warnings+1]='Partial Claude metadata scan: file limit reached';break end
              files[#files+1]=dirs[index]..'/'..name
            end
          end end
          vim.schedule(collect)
        end)
      end
      vim.schedule(collect)
    end)
  end)
end
function M.get(repo,id,callback)
  if not M.valid_id(id) then return vim.schedule(function() callback(nil,error_value('unavailable','Invalid Claude session UUID')) end) end
  M.list(repo,function(records)
    for _,r in ipairs(records) do if r.conversation.session_id==id then
      if not r.resumable then return callback(nil,error_value('unavailable',r.reason)) end
      return callback(r)
    end end
    callback(nil,error_value('unavailable','Claude conversation has no saved transcript in this repository'))
  end)
end
return M
