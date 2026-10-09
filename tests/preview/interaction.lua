local renderer = require('render-markdown')
local preview = require('render-markdown.preview')
local original = vim.api.nvim_get_current_buf()
local window = vim.api.nvim_get_current_win()
renderer.setup({ preview = { condition = function() return true end, auto_open = false, mermaid = { enabled = false } } })
local source = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(source)
local lines = {
    '# Router', '', 'alpha [github](https://example.com/a_(b)) omega', '',
    '| Name | Description |', '|---|---|',
    '| 两🙂 | ' .. string.rep('wrapped content ', 12) .. '|', '', 'last',
}
vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
vim.bo[source].filetype = 'markdown'
local display = preview.open(source)
for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(display, 'n')) do
    assert(mapping.lhs ~= ' mp' and mapping.lhs ~= '<Space>mp', 'Renderer owns the user preview shortcut')
end
vim.api.nvim_win_set_cursor(window, { 3, 9 })
local context = renderer.interaction()
assert(context.projected and context.source == source and context:valid(), 'Source context missing')
assert(context:link().destination == 'https://example.com/a_(b)', 'Source grammar lost balanced URL')
local before_invalid = vim.api.nvim_win_get_cursor(window)
assert(not context:select_source({ start = { 99, 0 }, finish = { 99, 1 } }), 'Invalid source range was selected')
assert(not context:select_source({ start = { 3, 12 }, finish = { 3, 7 } }), 'Reversed source range was selected')
assert(vim.deep_equal(before_invalid, vim.api.nvim_win_get_cursor(window)), 'Invalid range moved the cursor')
local hidden = assert(lines[3]:find('https', 1, true)) - 1
local visible, quality = context:to_display({ 3, hidden })
assert(quality == 'anchor' and visible[2] == 12, 'Hidden URL did not return to last label character')
local token, value, trailing = renderer.dispatch({
    target = 'source',
    run = function(ctx)
        assert(ctx:valid() and vim.api.nvim_get_current_buf() == source, 'Source route retained generated buffer')
        local recursive, reason = renderer.dispatch({ run = function() error('nested') end })
        assert(not recursive and reason == 'busy', 'Reentrant operation was dispatched')
        vim.api.nvim_win_set_cursor(window, { 3, hidden })
        return nil, 'returned'
    end,
})
assert(token.done and value == nil and trailing == 'returned', 'Router lost callback returns')
assert(vim.api.nvim_get_current_buf() == display and vim.api.nvim_win_get_cursor(window)[2] == 12,
    'Source operation did not restore visible link position')
local view = vim.fn.winsaveview()
local ok, err = pcall(renderer.dispatch, {
    target = 'source', run = function() error('adapter failed') end,
})
assert(not ok and tostring(err):find('adapter failed', 1, true), 'Adapter error lost traceback')
assert(vim.api.nvim_get_current_buf() == display and not vim.b[source].markdown_preview_disabled
    and vim.deep_equal(view, vim.fn.winsaveview()), 'Error leaked source mode or viewport')
local async = renderer.dispatch({ target = 'display', async = true, run = function() end })
assert(async:valid(), 'Async token started stale')
local snapshot = renderer.interaction()
preview.refresh(source)
assert(snapshot:valid(), 'Projection changed underneath an active operation')
async:finish()
assert(not async:valid() and not snapshot:valid(), 'Finished operation retained stale snapshot')
local cancelled = 0
local timeout = renderer.dispatch({ target = 'source', async = true, timeout = 20,
    run = function() end, cancel = function() cancelled = cancelled + 1 end })
assert(vim.wait(300, function() return timeout.done end, 5), 'Async timeout did not release source')
assert(cancelled == 1 and vim.api.nvim_get_current_buf() == display, 'Timeout leaked preview context')
local stale = renderer.dispatch({ target = 'display', async = true, run = function() end })
vim.api.nvim_buf_set_lines(source, 8, 9, false, { 'changed last' })
assert(not stale:valid() and not stale.context:valid(), 'Source revision did not invalidate callbacks')
local selected, reason = stale.context:select_source({ start = { 1, 0 }, finish = { 1, 3 } })
assert(not selected and reason == 'stale', 'Stale selection moved cursor')
stale:cancel()
local moving = renderer.dispatch({ target = 'display', async = true, run = function() end })
vim.api.nvim_win_set_cursor(window, { 1, 0 })
assert(not moving:valid(), 'Cursor change did not invalidate the async target')
moving:cancel(true)
renderer.dispatch({ target = 'source', run = function()
    vim.cmd.normal({ 'v', bang = true })
end })
assert(vim.api.nvim_get_current_buf() == source and vim.fn.mode() == 'v', 'Native Visual operation was interrupted')
-- A pending source event must not consume the return request during selection.
vim.api.nvim_exec_autocmds('TextChanged', { buffer = source })
vim.wait(20)
assert(vim.api.nvim_get_current_buf() == source and vim.fn.mode() == 'v', 'Source event interrupted selection')
vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'xt', false)
assert(vim.wait(300, function() return vim.api.nvim_get_current_buf() == display end, 5), 'Manual preview did not resume after native Visual operation')
-- Semantic selection survives the lossy visual projection and yanks source.
for _, selection in ipairs({ 'inclusive', 'exclusive' }) do
    vim.o.selection = selection
    vim.api.nvim_win_set_cursor(window, { 3, 9 })
    local semantic = renderer.interaction()
    assert(semantic:select_source({ start = { 3, 6 }, finish = { 3, 39 } }), 'Source selection failed')
    vim.api.nvim_feedkeys(vim.keycode('"ay'), 'xt', false)
    assert(vim.wait(300, function() return vim.api.nvim_get_current_buf() == display end, 5), 'Source yank lost preview')
    assert(vim.fn.getreg('a') == lines[3]:sub(7, 39), 'Semantic yank used displayed endpoints')
end
vim.o.selection = 'inclusive'
-- Standalone source syntax selection exercises the API without Flash.
vim.api.nvim_win_set_cursor(window, { 3, 9 })
local node_token, node_selected = renderer.select_node()
assert(node_token.done and node_selected and vim.fn.mode() == 'v'
    and vim.api.nvim_get_current_buf() == source, 'Core syntax selection did not fall back to source')
vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'xt', false)
assert(vim.wait(300, function() return vim.api.nvim_get_current_buf() == display end, 5),
    'Core syntax selection did not restore preview after completion')
local projected_token, projected_selected = renderer.select_node(nil, { preview = true })
assert(projected_token.done and projected_selected and vim.fn.mode() == 'v'
    and vim.api.nvim_get_current_buf() == display, 'Optional source selection did not stay in preview')
vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'xt', false)
-- A plugin can perform native source edits and retain a single undo history.
vim.api.nvim_win_set_cursor(window, { 1, 0 })
renderer.dispatch({ target = 'source', exact = true, run = function()
    vim.cmd.normal({ 'A edited' .. vim.keycode('<Esc>'), bang = true })
end })
assert(vim.api.nvim_buf_get_lines(source, 0, 1, false)[1] == '# Router edited', 'Native source edit missing')
vim.api.nvim_feedkeys('u', 'xt', false)
assert(vim.api.nvim_buf_get_lines(source, 0, 1, false)[1] == '# Router', 'Native source undo missing')
local isolated = renderer.dispatch({ target = 'display', async = true, run = function() end })
vim.api.nvim_set_current_buf(original)
assert(isolated.done, 'Leaving the operation window did not cancel the token')
vim.api.nvim_set_current_buf(display)
local teardown = renderer.dispatch({ target = 'source', async = true, run = function() end })
renderer.setup({ preview = { condition = function() return true end, enabled = false } })
assert(teardown.done and not vim.b[source].markdown_preview_disabled, 'Teardown leaked source suppression')
vim.api.nvim_set_current_buf(original)
vim.api.nvim_buf_delete(source, { force = true })
