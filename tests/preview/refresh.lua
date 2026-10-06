local renderer = require('render-markdown')
local preview = require('render-markdown.preview')
local projection = require('render-markdown.preview.projection')
local original = vim.api.nvim_get_current_buf()
renderer.setup({ debounce = 0,
    preview = { auto_open = false, mermaid = { enabled = false } } })
local source = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(source)
vim.api.nvim_buf_set_lines(source, 0, -1, false, {
    '# Messages', 'original prose', '', '```text', 'payload', '```',
})
vim.bo[source].filetype = 'markdown'
local display = preview.open(source)
local function deliver()
    local delivered = false
    vim.schedule(function() delivered = true end)
    assert(vim.wait(500, function() return delivered end, 1),
        'Main-loop message was not delivered')
end
local function prose()
    return vim.api.nvim_buf_get_lines(display, 1, 2, false)[1]
end
local function change(text)
    vim.api.nvim_buf_set_lines(source, 1, 2, false, { text })
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = source })
end
deliver()
deliver()
change('first notification')
change('latest unsaved notification')
deliver()
assert(prose() == 'latest unsaved notification',
    'Source-change messages did not commit their latest content on delivery')
assert(vim.bo[source].modified and vim.bo[display].modified,
    'Message commit cleared unsaved content')

-- A selection protects its frame until the explicit Normal-mode event.
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.api.nvim_feedkeys('v', 'xt', false)
assert(vim.fn.mode() == 'v', 'Selection did not enter Visual mode')
local cursor = vim.api.nvim_win_get_cursor(0)
change('pending during selection')
deliver()
assert(prose() == 'latest unsaved notification'
    and vim.deep_equal(vim.api.nvim_win_get_cursor(0), cursor),
    'Queued refresh changed the selected frame')
vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'xt', false)
deliver()
assert(prose() == 'pending during selection',
    'Normal-mode message did not release the pending frame')

-- Cooperative operations likewise release dirty state through completion.
local operation = renderer.dispatch({ target = 'display', async = true,
    run = function() end })
local snapshot = renderer.interaction()
projection.request_render(source, 'MermaidRender')
deliver()
deliver()
assert(operation:valid() and snapshot:valid(),
    'Provider message changed an active operation frame')
operation:finish()
deliver()
assert(not snapshot:valid(),
    'Operation completion did not release pending messages')
local stale = renderer.dispatch({ target = 'display', async = true,
    run = function() end })
change('source change cancelled operation')
deliver()
deliver()
assert(stale.done and prose() == 'source change cancelled operation',
    'Source-change cancellation did not commit the current frame')

-- Hidden views retain changes; entry commits the latest source immediately.
vim.api.nvim_set_current_buf(source)
change('latest hidden source')
deliver()
assert(prose() == 'source change cancelled operation',
    'Hidden view committed while native editing owned the source')
preview.open(source)
deliver()
deliver()
assert(vim.api.nvim_get_current_buf() == display and prose() == 'latest hidden source',
    'Preview-entry messages did not commit unsaved source content')

change('retired notification')
preview.toggle()
deliver()
assert(vim.api.nvim_get_current_buf() == source and not vim.api.nvim_buf_is_valid(display),
    'A retired refresh message restored its old preview')
vim.api.nvim_set_current_buf(original)
vim.api.nvim_buf_delete(source, { force = true })
