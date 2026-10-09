-- Preview must preserve native diff buffers, bindings, and line coordinates.
local renderer = require('render-markdown')
local preview = require('render-markdown.preview')
renderer.setup({ preview = { condition = function() return true end, auto_open = true, mermaid = { enabled = false } } })
vim.cmd.tabnew()
local source = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(source, 0, -1, false, { '# Before', '', 'unchanged' })
-- FileType queues automatic preview before Diffview sets its window options.
vim.bo[source].filetype = 'markdown'
vim.cmd.diffthis()
local left = vim.api.nvim_get_current_win()
vim.cmd.vnew()
local target = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(target, 0, -1, false, { '# After', '', 'unchanged' })
vim.bo[target].filetype = 'markdown'
vim.cmd.diffthis()
local right = vim.api.nvim_get_current_win()
vim.wait(30)
for _, pane in ipairs({ { window = left, buffer = source }, { window = right, buffer = target } }) do
    vim.api.nvim_set_current_win(pane.window)
    vim.wait(30)
    preview.open(pane.buffer)
    renderer.preview()
    assert(vim.api.nvim_win_get_buf(pane.window) == pane.buffer,
        'Automatic or explicit preview replaced a diff source')
    assert(vim.wo[pane.window].diff and vim.wo[pane.window].scrollbind
        and vim.wo[pane.window].cursorbind and vim.wo[pane.window].foldmethod == 'diff',
        'Preview changed native diff window options')
end

-- The same source can still render in an ordinary window next to a diff pane.
vim.cmd.vnew()
local ordinary = vim.api.nvim_get_current_win()
vim.api.nvim_set_current_buf(source)
vim.cmd.diffoff()
vim.api.nvim_exec_autocmds('WinEnter', { buffer = source })
assert(vim.wait(200, function() return preview.get(vim.api.nvim_get_current_buf()) == source end, 5),
    'A source shown in a diff pane could not render in an ordinary window')
assert(vim.api.nvim_win_get_buf(left) == source and vim.wo[left].diff,
    'An ordinary preview changed the other diff pane')
preview.leave()

-- Diffview index buffers have buftype="" before they enter a diff window.
local index = vim.api.nvim_create_buf(false, false)
vim.api.nvim_buf_set_name(index, 'diffview:///tmp/preview-fixture/.git/:0:/sample.md')
vim.api.nvim_set_current_buf(index)
vim.api.nvim_buf_set_lines(index, 0, -1, false, { '# Index' })
vim.bo[index].filetype = 'markdown'
vim.wait(30)
preview.open(index)
assert(vim.api.nvim_win_get_buf(ordinary) == index and not preview.get(index),
    'Preview replaced an editable virtual index before diff options were set')

vim.cmd('tabclose!')
for _, buffer in ipairs({ source, target, index }) do
    vim.api.nvim_buf_delete(buffer, { force = true })
end
