local M = {}

local function fit(text,width)
  text=tostring(text or '')
  local result=''
  for index=0,vim.fn.strchars(text)-1 do
    local char=vim.fn.strcharpart(text,index,1)
    if vim.fn.strdisplaywidth(result..char)>width then
      result=result..'…'
      break
    end
    result=result..char
  end
  return result..string.rep(' ',math.max(0,width-vim.fn.strdisplaywidth(result)))
end

local function set_lines(buf,lines)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  vim.bo[buf].modifiable=true
  vim.api.nvim_buf_set_lines(buf,0,-1,false,lines)
  vim.bo[buf].modifiable=false
end

local function ordered_messages(preview)
  local messages={}
  for _,role in ipairs({'user','assistant'}) do
    local message=preview and preview[role]
    if message and type(message.text)=='string' and message.text~='' then
      messages[#messages+1]={role=role,text=message.text,timestamp=message.timestamp or ''}
    end
  end
  table.sort(messages,function(a,b) return a.timestamp<b.timestamp end)
  return messages
end

local function preview_lines(item)
  local provider=item.conversation and 'Claude session' or
    (item.agent and item.agent.identity and (item.agent.identity.provider or 'Agent')..' session' or 'Session')
  local lines={item.title or 'Untitled session',provider..' · '..(item.state or 'unknown')}
  if item.updated_at then lines[#lines+1]='Updated · '..item.updated_at end
  local messages=ordered_messages(item.preview)
  if #messages==0 then
    lines[#lines+1]=''
    lines[#lines+1]='No transcript preview available.'
    if item.reason then lines[#lines+1]=item.reason end
    return lines,{}
  end
  local labels={}
  for _,message in ipairs(messages) do
    lines[#lines+1]=''
    labels[#lines+1]=#lines
    lines[#lines+1]=message.role=='user' and 'YOU' or 'CLAUDE'
    local parts=vim.split(message.text,'\n',{plain=true,trimempty=false})
    for _,part in ipairs(parts) do lines[#lines+1]=part end
  end
  return lines,labels
end

local function buffer(lines,kind)
  local buf=vim.api.nvim_create_buf(false,true)
  vim.b[buf][kind]=true
  vim.bo[buf].buftype='nofile'
  vim.bo[buf].bufhidden='wipe'
  vim.bo[buf].swapfile=false
  vim.bo[buf].modifiable=true
  vim.api.nvim_buf_set_lines(buf,0,-1,false,lines)
  vim.bo[buf].modifiable=false
  return buf
end

function M.open(items,opts,callback)
  opts=opts or {}
  if #items==0 then return callback(nil) end

  local vertical=vim.o.columns<84
  local height=math.max(4,math.min(22,vim.o.lines-8))
  local state={items=items,index=1,callback=callback,closed=false,ns=vim.api.nvim_create_namespace('AgentBoardSessionPicker')}
  local list_width,preview_width,list_height,preview_height,row,col,preview_row,preview_col
  if vertical then
    list_width=math.max(14,math.min(112,vim.o.columns-6))
    preview_width=list_width
    list_height=math.max(2,math.floor((height-2)*0.34))
    preview_height=math.max(2,height-list_height-3)
    local total_height=list_height+preview_height+5
    row=math.max(0,math.floor((vim.o.lines-total_height)/2))
    col=math.max(0,math.floor((vim.o.columns-list_width-2)/2))
    preview_row=row+list_height+3
    preview_col=col
  else
    local width=math.max(36,math.min(112,vim.o.columns-8))
    list_width=math.max(18,math.floor((width-2)*0.42))
    preview_width=width-list_width-2
    list_height=height
    preview_height=height
    local total_width=list_width+preview_width+6
    row=math.max(0,math.floor((vim.o.lines-height-2)/2))
    col=math.max(0,math.floor((vim.o.columns-total_width)/2))
    preview_row=row
    preview_col=col+list_width+4
  end

  vim.api.nvim_set_hl(0,'AgentBoardPickerSelected',{default=true,link='PmenuSel'})
  vim.api.nvim_set_hl(0,'AgentBoardPickerLabel',{default=true,link='Title'})
  vim.api.nvim_set_hl(0,'AgentBoardPickerMeta',{default=true,link='Comment'})
  local formatter=opts.format_item or function(item) return tostring(item) end
  local function list_text(index)
    local text={}
    for _,item in ipairs(items) do text[#text+1]=fit(formatter(item),list_width) end
    return text
  end
  local preview,labels=preview_lines(items[1])
  state.list_buf=buffer(list_text(1),'agent_board_session_picker')
  state.preview_buf=buffer(preview,'agent_board_session_preview')
  state.list_win=vim.api.nvim_open_win(state.list_buf,true,{
    relative='editor',row=row,col=col,width=list_width,height=list_height,
    border='rounded',title=' Sessions ',title_pos='center',style='minimal',
  })
  state.preview_win=vim.api.nvim_open_win(state.preview_buf,false,{
    relative='editor',row=preview_row,col=preview_col,width=preview_width,height=preview_height,
    border='rounded',title=' Preview ',title_pos='center',style='minimal',focusable=false,
  })
  for _,win in ipairs({state.list_win,state.preview_win}) do
    vim.wo[win].number=false
    vim.wo[win].relativenumber=false
    vim.wo[win].signcolumn='no'
    vim.wo[win].wrap=win==state.preview_win
    vim.wo[win].linebreak=win==state.preview_win
    vim.wo[win].cursorline=false
  end
  vim.api.nvim_win_set_hl_ns(state.preview_win,state.ns)
  for _,line in ipairs(labels) do vim.api.nvim_buf_add_highlight(state.preview_buf,state.ns,'AgentBoardPickerLabel',line-1,0,-1) end
  if #preview>2 then
    vim.api.nvim_buf_add_highlight(state.preview_buf,state.ns,'AgentBoardPickerMeta',1,0,-1)
    if items[1].updated_at then vim.api.nvim_buf_add_highlight(state.preview_buf,state.ns,'AgentBoardPickerMeta',2,0,-1) end
  end

  local function close(choice)
    if state.closed then return end
    state.closed=true
    if state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) then pcall(vim.api.nvim_win_close,state.preview_win,true) end
    if state.list_win and vim.api.nvim_win_is_valid(state.list_win) then pcall(vim.api.nvim_win_close,state.list_win,true) end
    if state.group then pcall(vim.api.nvim_del_augroup_by_id,state.group);state.group=nil end
    local done=state.callback
    state.callback=nil
    if done then done(choice) end
  end

  local function update()
    local item=items[state.index]
    set_lines(state.list_buf,list_text(state.index))
    vim.api.nvim_buf_clear_namespace(state.list_buf,state.ns,0,-1)
    vim.api.nvim_buf_add_highlight(state.list_buf,state.ns,'AgentBoardPickerSelected',state.index-1,0,-1)
    local current_preview,current_labels=preview_lines(item)
    set_lines(state.preview_buf,current_preview)
    vim.api.nvim_buf_clear_namespace(state.preview_buf,state.ns,0,-1)
    for _,line in ipairs(current_labels) do vim.api.nvim_buf_add_highlight(state.preview_buf,state.ns,'AgentBoardPickerLabel',line-1,0,-1) end
    vim.api.nvim_win_set_cursor(state.list_win,{state.index,0})
    vim.api.nvim_win_call(state.preview_win,function() vim.cmd('normal! gg') end)
  end

  local function move(delta)
    state.index=math.max(1,math.min(#items,state.index+delta))
    update()
  end

  for key,delta in pairs({j=1,k=-1,['<Down>']=1,['<Up>']=-1,['<C-n>']=1,['<C-p>']=-1}) do
    vim.keymap.set('n',key,function() if not state.closed then move(delta) end end,{buffer=state.list_buf,silent=true,nowait=true})
  end
  vim.keymap.set('n','<CR>',function() close(items[state.index]) end,{buffer=state.list_buf,silent=true,nowait=true})
  vim.keymap.set('n','<Esc>',function() close(nil) end,{buffer=state.list_buf,silent=true,nowait=true})
  vim.keymap.set('n','q',function() close(nil) end,{buffer=state.list_buf,silent=true,nowait=true})

  state.group=vim.api.nvim_create_augroup('AgentBoardSessionPicker'..state.list_buf,{clear=true})
  vim.api.nvim_create_autocmd('WinClosed',{group=state.group,pattern=tostring(state.list_win),once=true,callback=function() close(nil) end})
  vim.api.nvim_create_autocmd('WinClosed',{group=state.group,pattern=tostring(state.preview_win),once=true,callback=function() close(nil) end})
  update()
  return state
end

return M
