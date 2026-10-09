local renderer = require('render-markdown')
local preview = require('render-markdown.preview')
renderer.setup({ preview = { mermaid = { enabled = false } } })
vim.cmd.tabnew()
local first = vim.api.nvim_get_current_win()
local source = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(source, 0, -1, false, { '# Contexts', '', 'Source text' })
vim.bo[source].filetype = 'markdown'
vim.wo[first].conceallevel = 2
vim.wait(30)
renderer.preview()
assert(not preview.open(source) and vim.api.nvim_win_get_buf(first) == source,
    'Unapproved context opened automatically or through an explicit API')
assert(vim.wo[first].conceallevel == 2, 'Denied preview changed window options')
require('render-markdown.core.colors').init()
local manager = require('render-markdown.core.manager')
manager.init()
assert(manager.attached(source),
    'Denied projection suppressed ordinary inline rendering')
vim.w[first].render_markdown_preview = true
vim.api.nvim_exec_autocmds('WinEnter', { buffer = source })
assert(vim.wait(200, function() return preview.get(vim.api.nvim_win_get_buf(first)) == source end, 5),
    'Approved context did not automatically open')
local display = vim.api.nvim_win_get_buf(first)
vim.cmd.vsplit()
local second = vim.api.nvim_get_current_win()
vim.w[second].render_markdown_preview = false
vim.wait(30)
assert(vim.api.nvim_win_get_buf(second) == source,
    'Unapproved split retained another window\'s projection')
assert(vim.api.nvim_win_get_buf(first) == display and preview.get(display) == source,
    'Unapproved split destroyed its sibling projection')
renderer.preview()
assert(vim.api.nvim_win_get_buf(second) == source, 'Manual entry bypassed window permission')

-- Queued work must re-evaluate the destination permission.
vim.w[second].render_markdown_preview = true
vim.api.nvim_exec_autocmds('WinEnter', { buffer = source })
vim.w[second].render_markdown_preview = false
vim.wait(30)
assert(vim.api.nvim_win_get_buf(second) == source, 'Stale approval opened a projection')
vim.w[second].render_markdown_preview = true
renderer.preview()
assert(preview.get(vim.api.nvim_get_current_buf()) == source, 'Explicit opt-in did not permit manual entry')
vim.w[second].render_markdown_preview = false
vim.api.nvim_exec_autocmds('WinEnter', { buffer = vim.api.nvim_get_current_buf() })
assert(vim.api.nvim_win_get_buf(second) == source and preview.get(display) == source,
    'Revocation did not preserve the other window\'s session')
vim.api.nvim_set_current_win(first)
preview.leave()
vim.cmd('tabclose!')
vim.api.nvim_buf_delete(source, { force = true })
