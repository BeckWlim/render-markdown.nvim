local renderer = require('render-markdown')
local preview = require('render-markdown.preview')
local original = vim.api.nvim_get_current_buf()
renderer.setup({ preview = { condition = function() return true end, auto_open = false, mermaid = { enabled = false } } })
local source = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(source)
local line = 'alpha [github](https://example.com/a_(b)) omega'
local unicode = '前 [部署指南](https://example.com/a/long/url) 后面'
vim.api.nvim_buf_set_lines(source, 0, -1, false, { line, unicode, '`[literal](url)` tail' })
vim.bo.filetype = 'markdown'
local display = preview.open(source)
vim.treesitter.start(display)
vim.treesitter.get_parser(display):parse(true)
vim.wo.conceallevel = 3
vim.wo.concealcursor = 'nvic'
local function move(row, column, keys, expected)
    vim.api.nvim_win_set_cursor(0, { row, column })
    vim.api.nvim_feedkeys(vim.keycode(keys), 'xt', false)
    local actual = vim.api.nvim_win_get_cursor(0)
    assert(vim.deep_equal(actual, { row, expected }), keys .. ': ' .. vim.inspect(actual) .. ' expected ' .. expected)
end
local after = assert(line:find(' omega', 1, true)) - 1
local omega = after + 1
move(1, after, 'h', 12)
move(1, after, '<Left>', 12)
move(1, after, '2h', 11)
move(1, 12, 'h', 11) -- No sticky endpoint after returning from a hidden URL.
move(1, 12, 'l', after)
move(1, 11, '2l', after)
move(1, 0, 'w', 7)
move(1, 0, '2w', omega)
move(1, 7, 'w', omega)
move(1, 7, 'e', 12)
move(1, 12, 'e', #line - 1)
move(1, omega, 'b', 7)
move(1, omega, '2b', 0)
move(1, after, 'b', 7)
move(1, omega, 'ge', 12)
move(1, 0, 'W', 7)
move(1, 0, '2W', omega)
move(1, omega, 'B', 7)
move(1, 7, 'E', 12)
move(1, 12, 'E', #line - 1)
move(1, omega, 'gE', 12)
move(1, omega, 'vb', 7)
assert(vim.fn.mode() == 'v', 'Word motion ended Visual selection')
vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'xt', false)
local unicode_after = assert(unicode:find(' 后面', 1, true)) - 1
local unicode_end = assert(unicode:find(']', 1, true)) - 1
move(2, unicode_after, 'h', unicode_end - 3)
move(2, unicode_end - 3, 'h', unicode_end - 6)
move(2, unicode_after + 1, 'b', 5)
move(2, 0, 'W', 5)
move(2, unicode_after + 1, 'B', 5)
move(2, 5, 'E', unicode_end - 3)
move(1, 7, 'vE', 12)
assert(vim.fn.mode() == 'v', 'WORD end motion ended Visual selection')
vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'xt', false)
-- Literal code stays native; source mode has no renderer word mappings.
vim.wo.conceallevel = 0
move(1, omega, 'b', after - 2)
preview.toggle()
assert(vim.tbl_isempty(vim.fn.maparg('w', 'n', false, true)), 'Source mode inherited visible word mapping')
vim.api.nvim_set_current_buf(original)
vim.api.nvim_buf_delete(source, { force = true })
