local renderer = require('render-markdown')
local preview = require('render-markdown.preview')
local original = vim.api.nvim_get_current_buf()
local window = vim.api.nvim_get_current_win()
local selection = vim.o.selection
renderer.setup({ preview = { condition = function() return true end, auto_open = false, mermaid = { enabled = false } } })
local source = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(source)
vim.api.nvim_buf_set_lines(source, 0, -1, false, {
    'alpha [github](https://example.com) omega',
    '| Name | Description |',
    '|---|---|',
    '| item | ' .. string.rep('wrapped content ', 12) .. '|',
    '两🙂',
})
vim.bo[source].filetype = 'markdown'

-- Construction is inert; the same callback resolves source and preview anew.
local calls = 0
local operation = {
    target = 'source',
    run = function(context, token, ...)
        calls = calls + 1
        assert(context:valid() and token:valid(), 'Wrapped action started stale')
        assert(vim.api.nvim_get_current_buf() == source, 'Wrapped action lost source identity')
        assert(select('#', ...) == 3, 'Wrapper dropped nil arguments')
        local first, middle, last = ...
        assert(first == 'first' and middle == nil and last == 'last', 'Wrapper changed arguments')
        return nil, context.projected, last, nil
    end,
}
local options = { window = window }
local callback = renderer.wrap(operation, options)
assert(calls == 0, 'Wrapper ran during configuration')
operation.run = function() error('Wrapper did not snapshot operation') end
options.window = -1
local results = { callback('first', nil, 'last') }
assert(results[1].done and results[2] == nil and results[3] == false and results[4] == 'last',
    'Source wrapper lost results or configuration snapshot')
local user_jumps = 0
for _, key in ipairs({ 's', 'S' }) do
    vim.keymap.set('n', key, function()
        user_jumps = user_jumps + 1
        vim.api.nvim_win_set_cursor(window, { 1, 9 })
    end)
end
local display = preview.open(source)
local before_jump = vim.api.nvim_buf_get_changedtick(source)
vim.api.nvim_feedkeys('sS', 'xt', false)
assert(user_jumps == 2 and vim.api.nvim_get_current_buf() == display
    and vim.api.nvim_buf_get_changedtick(source) == before_jump,
    'Core editing fallbacks intercepted user navigation mappings')
local result_count
local function capture(...)
    result_count = select('#', ...)
    return { ... }
end
results = capture(callback('first', nil, 'last'))
assert(calls == 2 and result_count == 5 and results[3] == true,
    'Wrapper retained old context or lost trailing nil returns')
assert(vim.api.nvim_get_current_buf() == display, 'Wrapped action did not restore preview')

-- Source syntax and endpoint services can be consumed without private modules.
vim.api.nvim_win_set_cursor(window, { 1, 9 })
local context = renderer.interaction()
local ranges = context:node_ranges()
assert(#ranges > 0, 'Public context did not expose source syntax')
assert(vim.tbl_contains(vim.tbl_map(function(range) return range.kind end, ranges), 'inline_link'),
    'Public syntax ranges parsed generated text instead of source')
vim.o.selection = 'inclusive'
assert(vim.deep_equal(context:selection_end({ 5, 7 }, 'source'), { 5, 3 }),
    'Public source endpoint split a UTF-8 character')
assert(vim.deep_equal(context:selection_end({ 6, 0 }, 'source'), { 5, 7 }),
    'Public endpoint lost the source EOF boundary')
vim.o.selection = 'exclusive'
assert(vim.deep_equal(context:selection_end({ 5, 7 }, 'source'), { 5, 7 }),
    'Public endpoint ignored exclusive selection')
local endpoint, reason = context:selection_end({ 5, 4 }, 'source')
assert(not endpoint and reason == 'unmapped', 'Public endpoint accepted a partial UTF-8 byte')
vim.o.selection = 'inclusive'

-- User-owned mappings keep count/register and operate on the requested view.
local mapped_count, mapped_register
vim.keymap.set('n', '<F6>', renderer.wrap({
    target = 'display',
    run = function(ctx)
        mapped_count, mapped_register = ctx.count, ctx.register
        assert(vim.api.nvim_get_current_buf() == display, 'Display callback switched to source')
    end,
}), { buffer = display })
vim.api.nvim_feedkeys(vim.keycode('"a3<F6>'), 'xt', false)
assert(mapped_count == 3 and mapped_register == 'a', 'Configuration callback lost invocation state')
local rejected = renderer.wrap({ exact = true, run = function() error('Anchor action ran') end })
vim.api.nvim_win_set_cursor(window, { 2, 0 })
local token
token, reason = rejected()
assert(not token and reason == 'anchor', 'Wrapper bypassed exact source requirements')
vim.api.nvim_win_set_cursor(window, { 1, 9 })
local failing = renderer.wrap({ run = function() error('configuration failed') end })
local ok, err = pcall(failing)
assert(not ok and tostring(err):find('configuration failed', 1, true), 'Wrapper lost callback error')
assert(vim.api.nvim_get_current_buf() == display, 'Callback error leaked source mode')

-- Async wrappers keep their lease until a user-supplied completion hook fires.
local pending
local async = renderer.wrap({
    async = true,
    run = function(_, owner) pending = owner end,
})
token = async()
assert(pending == token and token:valid() and vim.api.nvim_get_current_buf() == source,
    'Async wrapper restored preview before completion')
token:finish()
assert(token.done and vim.api.nvim_get_current_buf() == display, 'Async completion lost preview')
local completed = token
token = async()
assert(token ~= completed and token == pending and token:valid(),
    'Repeated wrapper reused an expired lease')
token:cancel()
assert(token.done and vim.api.nvim_get_current_buf() == display, 'Async cancellation lost preview')

-- Cursor origins hidden by conceal survive toggles and native source edits.
local line = vim.api.nvim_buf_get_lines(source, 0, 1, false)[1]
local hidden = assert(line:find('https', 1, true)) - 1
renderer.dispatch({ run = function() vim.api.nvim_win_set_cursor(window, { 1, hidden }) end })
renderer.preview()
assert(vim.api.nvim_get_current_buf() == source
    and vim.deep_equal(vim.api.nvim_win_get_cursor(window), { 1, hidden }),
    'Leaving preview lost the remembered concealed source cursor')
renderer.preview()
display = vim.api.nvim_get_current_buf()
renderer.preview()
assert(vim.deep_equal(vim.api.nvim_win_get_cursor(window), { 1, hidden }),
    'An unchanged preview/source round trip lost its source cursor')
renderer.preview()
display = vim.api.nvim_get_current_buf()
vim.api.nvim_feedkeys(vim.keycode('iZ<Esc>'), 'xt', false)
assert(vim.wait(300, function() return vim.api.nvim_get_current_buf() == display end, 5),
    'Native edit fallback did not restore preview')
assert(vim.api.nvim_buf_get_lines(source, 0, 1, false)[1] == line:sub(1, hidden) .. 'Z' .. line:sub(hidden + 1),
    'Native edit fallback used the visible label instead of its source origin')

context = renderer.interaction()
vim.api.nvim_buf_set_lines(source, 0, 1, false, { 'changed source' })
ranges, reason = context:node_ranges()
assert(not ranges and reason == 'stale', 'Public syntax service accepted a stale context')
endpoint, reason = context:selection_end({ 1, 1 })
assert(not endpoint and reason == 'stale', 'Public endpoint service accepted a stale context')
vim.o.selection = selection
vim.keymap.del('n', 's')
vim.keymap.del('n', 'S')
vim.api.nvim_set_current_buf(original)
vim.api.nvim_buf_delete(source, { force = true })
