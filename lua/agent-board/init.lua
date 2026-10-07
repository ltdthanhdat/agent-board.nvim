local tasks = require('agent-board.tasks')
local M = {}

for _, name in ipairs({ 'resolve_repo', 'list_tasks', 'list_lanes', 'add_lane', 'rename_lane', 'get_task', 'create_task', 'update_task', 'move_task', 'delete_task', 'bind_conversation', 'list_sessions' }) do
  M[name] = tasks[name]
end

function M.start_agent(ref, opts, callback)
  if type(callback) ~= 'function' then return nil, 'a callback is required' end
  return tasks.start_agent(ref, opts, function(task, err)
    if not task or not task.existing then return callback(task, err) end
    M.open_agent(ref, function(_, open_error)
      callback(open_error and nil or task, open_error)
    end, opts.terminal_opts)
  end)
end

function M.bind_agent(ref, identity, expected_snapshot, callback)
  if type(expected_snapshot) == 'function' then
    callback, expected_snapshot = expected_snapshot, nil
  end
  return tasks.bind_agent(ref, identity, expected_snapshot, callback)
end

for _, name in ipairs({ 'open_agent', 'hide_agent', 'send', 'stop_agent' }) do
  M[name] = tasks[name]
end

function M.focus_board(opts)
  return require('agent-board.board').open(opts)
end

function M.setup(opts)
  if opts ~= nil and type(opts) ~= 'table' then
    return nil, 'setup options must be a table'
  end
  return true
end

return M
