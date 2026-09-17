local preview = require('render-markdown.preview')
local original_buffer = vim.api.nvim_get_current_buf()
local directory = vim.fn.tempname()
vim.fn.mkdir(directory, 'p')
local document = {
    '# Jump history',
    '',
    '| Key | Value |',
    '|---|---|',
    '| item | ' .. string.rep('wrapped content ', 40) .. '|',
    '',
    'Last paragraph',
}
vim.fn.writefile({ 'First file', 'Second line' }, directory .. '/before.txt')
vim.fn.writefile(document, directory .. '/document.md')
vim.fn.writefile({ 'Last file' }, directory .. '/after.txt')
require('render-markdown').setup({ preview = { enabled = true } })
vim.api.nvim_cmd({ cmd = 'edit', args = { directory .. '/before.txt' } }, {})
local before = vim.api.nvim_get_current_buf()
vim.cmd('clearjumps')
vim.api.nvim_win_set_cursor(0, { 2, 3 })
vim.api.nvim_cmd({ cmd = 'edit', args = { directory .. '/document.md' } }, {})
local source = vim.api.nvim_get_current_buf()
vim.bo.filetype = 'markdown'
assert(
    vim.wait(200, function()
        return vim.b.markdown_preview_source == source
    end, 5),
    'Expected preview test condition'
)
local rendered = vim.api.nvim_get_current_buf()
assert(
    #vim.fn.getjumplist()[1] == 1,
    'Opening the rendered view added a source jump'
)
local rendered_position = { vim.api.nvim_buf_line_count(rendered), 4 }
vim.api.nvim_win_set_cursor(0, rendered_position)

local function jump(keys, target, position)
    vim.api.nvim_feedkeys(vim.keycode(keys), 'nxt', false)
    vim.wait(30)
    assert(
        vim.api.nvim_get_current_buf() == target,
        'Jump reached the wrong buffer: ' .. keys
    )
    if position then
        assert(
            vim.deep_equal(vim.api.nvim_win_get_cursor(0), position),
            'Jump lost its cursor: '
                .. keys
                .. ' '
                .. vim.inspect(vim.api.nvim_win_get_cursor(0))
        )
    end
end

for _ = 1, 3 do
    jump('<C-o>', before, { 2, 3 })
    assert(
        vim.api.nvim_buf_is_valid(rendered),
        'Leaving Markdown deleted the forward destination'
    )
    jump('<C-i>', rendered, rendered_position)
    assert(
        vim.wo.foldmethod == 'manual' and vim.wo.wrap,
        'Jumping into the preview lost its window options'
    )
end
vim.api.nvim_cmd({ cmd = 'edit', args = { directory .. '/after.txt' } }, {})
local after = vim.api.nvim_get_current_buf()
for _ = 1, 3 do
    jump('<C-o>', rendered, rendered_position)
    jump('<C-o>', before, { 2, 3 })
    jump('<C-i>', rendered, rendered_position)
    jump('<C-i>', after)
end
jump('2<C-o>', before, { 2, 3 })
jump('2<C-i>', after)
jump('<C-o>', rendered, rendered_position)
-- Native jumps within the projected text retain their displayed coordinates.
jump('gg0', rendered, { 1, 0 })
jump('<C-o>', rendered, rendered_position)
jump('<C-i>', rendered, { 1, 0 })
vim.api.nvim_cmd({ cmd = 'buffer', args = { tostring(source) } }, {})
vim.api.nvim_win_set_cursor(0, { 7, 4 })
assert(
    vim.wait(200, function()
        return vim.api.nvim_get_current_buf() == rendered
    end, 5),
    'Reopening the source replaced the preview and invalidated jump destinations'
)
assert(
    vim.deep_equal(vim.api.nvim_win_get_cursor(0), rendered_position),
    'Reopening the source lost its projected position'
)
preview.toggle()
assert(
    vim.api.nvim_get_current_buf() == source
        and not vim.api.nvim_buf_is_valid(rendered),
    'Explicit source mode retained the hidden preview'
)
local source_history = vim.fn.getjumplist()
preview.toggle()
preview.toggle()
assert(
    vim.deep_equal(vim.fn.getjumplist(), source_history),
    'Source toggles changed native jump history'
)

-- Hidden previews still belong to their source and must retire with it.
local hidden_preview = preview.open(source)
vim.api.nvim_set_current_buf(before)
vim.api.nvim_buf_delete(source, { force = true })
assert(
    not vim.api.nvim_buf_is_valid(hidden_preview),
    'Deleting the source leaked its hidden preview'
)
vim.api.nvim_del_augroup_by_name('markdown_default_preview')
vim.api.nvim_set_current_buf(original_buffer)
vim.api.nvim_buf_delete(before, { force = true })
vim.api.nvim_buf_delete(after, { force = true })
vim.fn.delete(directory, 'rf')
