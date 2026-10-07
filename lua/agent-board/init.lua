local tasks = require('agent-board.tasks')
local M = {}

for _, name in ipairs({ 'resolve_repo', 'list_tasks', 'get_task', 'create_task', 'update_task', 'move_task', 'delete_task' }) do
  M[name] = tasks[name]
end

function M.setup(opts)
  if opts ~= nil and type(opts) ~= 'table' then
    return nil, 'setup options must be a table'
  end
  return true
end

return M
