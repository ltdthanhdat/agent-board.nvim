if vim.g.loaded_agent_board_plugin then return end
vim.g.loaded_agent_board_plugin = true

vim.api.nvim_create_user_command('AgentBoard', function(opts)
  if opts.args ~= '' and opts.args ~= 'global' then
    vim.notify('agent-board: usage is :AgentBoard [global]', vim.log.levels.ERROR)
    return
  end
  local scope = opts.args == 'global' and 'global' or 'repo'
  local buf, err = require('agent-board.board').open({ scope = scope, repo = vim.fn.getcwd() })
  if not buf then vim.notify('agent-board: ' .. tostring(err), vim.log.levels.ERROR) end
end, { nargs = '?', desc = 'Open the AgentBoard task view' })
