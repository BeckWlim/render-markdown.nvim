local renderer = require('render-markdown')
local preview = require('render-markdown.preview')
local original = vim.api.nvim_get_current_buf()
local original_tagfunc = _G.renderer_test_tagfunc
local directory = vim.fn.tempname()
vim.fn.mkdir(directory, 'p')
local filename = directory .. '/source.md'
local target = directory .. '/target.lua'
vim.fn.writefile({ 'return true' }, target)
renderer.setup({ preview = { mermaid = { enabled = false } } })
local source = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(source)
vim.api.nvim_buf_set_name(source, filename)
local lines = {
    '# Native', '', 'alpha [github](https://same.example/first) omega', '',
    '[other](https://same.example/second)', '', 'after',
}
vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
vim.bo[source].filetype = 'markdown'
local display = preview.open(source)
local context = renderer.interaction()
assert(renderer.source_buffer(display) == source and renderer.source_buffer(source) == source,
    'Source and projection did not resolve to the same file buffer')
assert(context.filename == filename and context.filetype == 'markdown', 'Canonical file metadata lost')
local function input(keys)
    vim.api.nvim_feedkeys(vim.keycode(keys), 'xt', false)
end
local source_tick = vim.api.nvim_buf_get_changedtick(source)
local source_entries = 0
local group = vim.api.nvim_create_augroup('renderer_native_search_test', { clear = true })
vim.api.nvim_create_autocmd('BufEnter', {
    group = group, buffer = source, callback = function() source_entries = source_entries + 1 end,
})
for _, key in ipairs({ '/', '?', 'n', 'N' }) do
    for _, mode in ipairs({ 'n', 'x', 'o' }) do
        assert(vim.tbl_isempty(vim.fn.maparg(key, mode, false, true)),
            'Renderer replaced native preview search: ' .. key)
    end
end
vim.api.nvim_win_set_cursor(0, { 1, 0 })
input('/\\vgithub|other<CR>')
assert(vim.api.nvim_get_current_buf() == display, 'Native search left preview')
assert(vim.api.nvim_win_get_cursor(0)[1] == 3, 'Native search missed the visible link label')
input('n')
assert(vim.api.nvim_win_get_cursor(0)[1] == 5, 'Search repeat did not advance in preview')
local search_view = vim.fn.winsaveview()
input('/alpha<Esc>')
assert(vim.api.nvim_get_current_buf() == display, 'Search cancellation left preview')
assert(vim.deep_equal(vim.fn.winsaveview(), search_view), 'Search cancellation lost the original view')
vim.api.nvim_win_set_cursor(0, { 1, 0 })
input('2/\\vgithub|other<CR>')
assert(vim.api.nvim_win_get_cursor(0)[1] == 5, 'Native preview search dropped its count')
input('?\\vgithub|other<CR>')
assert(vim.api.nvim_win_get_cursor(0)[1] == 3, 'Backward preview search lost its target')
-- Restore forward direction before testing native Visual repeat.
vim.v.searchforward = 1
input('vn')
assert(vim.fn.mode() == 'v' and vim.api.nvim_get_current_buf() == display,
    'Visual repeat left the preview')
assert(vim.api.nvim_win_get_cursor(0)[1] == 5, 'Visual repeat missed the next label')
input('N')
assert(vim.api.nvim_win_get_cursor(0)[1] == 3, 'Visual reverse repeat lost its preview position')
input('<Esc>')
vim.api.nvim_win_set_cursor(0, { 3, 9 })
input('v/omega<CR>')
assert(vim.fn.mode() == 'v', 'Visual search lost its selection')
assert(vim.api.nvim_get_current_buf() == display, 'Native Visual search left preview')
input('<Esc>')
assert(source_entries == 0, 'Native search temporarily entered the source buffer')
assert(vim.api.nvim_buf_get_changedtick(source) == source_tick, 'Native search modified Markdown source')
vim.api.nvim_del_augroup_by_id(group)
vim.api.nvim_win_set_cursor(0, { 3, 9 })
input('ma')
assert(vim.deep_equal(vim.api.nvim_buf_get_mark(source, 'a'), { 3, 9 }), 'Mark was stored in the projected buffer')
vim.api.nvim_win_set_cursor(0, { 7, 0 })
input('`a')
assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 3, 9 }), 'Source mark did not return to its display position')
vim.fn.setreg('/', '\\Vgithub')
vim.v.searchforward = 1
vim.api.nvim_win_set_cursor(0, { 1, 0 })
input('n')
assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 3, 7 }), 'Repeat missed the visible label start')
input('l')
input('h')
assert(vim.api.nvim_win_get_cursor(0)[2] == 7, 'Visible movement stuck after native preview search')
_G.renderer_test_tagfunc = function(pattern)
    assert(vim.api.nvim_get_current_buf() == source, 'Native tag lookup used the generated buffer')
    assert(pattern == 'github', 'Native tag lookup changed the source token')
    return { { name = 'github', filename = target, cmd = '1' } }
end
vim.bo[source].tagfunc = 'v:lua.renderer_test_tagfunc'
vim.api.nvim_win_set_cursor(0, { 3, 9 })
input('<C-]>')
assert(vim.api.nvim_buf_get_name(0) == target, 'Native tag did not open its target')
local stack = vim.fn.gettagstack()
assert(stack.items[#stack.items].from[1] == source, 'Tag stack recorded a synthetic file')
input('<C-t>')
assert(vim.wait(300, function() return vim.api.nvim_get_current_buf() == display end, 5),
    'Native tag return did not restore the retained file view')
assert(vim.api.nvim_win_get_cursor(0)[2] == 9, 'Tag return changed the label cursor')
_G.renderer_test_tagfunc = original_tagfunc
vim.api.nvim_set_current_buf(original)
vim.api.nvim_buf_delete(source, { force = true })
local target_buffer = vim.fn.bufnr(target)
if target_buffer ~= -1 then vim.api.nvim_buf_delete(target_buffer, { force = true }) end
vim.fn.delete(directory, 'rf')
