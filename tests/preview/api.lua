local manager = require('render-markdown.core.manager')
local renderer = require('render-markdown')
local state = require('render-markdown.state')
local original_buffer = vim.api.nvim_get_current_buf()
renderer.setup({ preview = { enabled = false } })
require('render-markdown.core.colors').init()
manager.init()
assert(
    renderer.default.preview.enabled and not state.preview.enabled,
    'Preview defaults or explicit disable were ignored'
)
assert(#state.validate() == 0, table.concat(state.validate(), '\n'))
local source = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(source, 'api-preview.md')
vim.api.nvim_set_current_buf(source)
vim.api.nvim_buf_set_lines(source, 0, -1, false, {
    '# API preview',
    '',
    '| Key | Value |',
    '|---|---|',
    '| item | ' .. string.rep('wrapped cell ', 40) .. '|',
    '',
    '```mermaid',
    'graph LR',
    'A --> B',
    '```',
})
vim.bo.filetype = 'markdown'
local windows = #vim.api.nvim_list_wins()
assert(
    vim.api.nvim_get_current_buf() == source,
    'Disabled preview opened automatically'
)
local custom_calls = 0
renderer.setup({
    preview = {
        enabled = true,
        auto_open = false,
        mermaid = { command = '/missing/optional-termaid' },
    },
    custom_handlers = {
        markdown = {
            extends = true,
            parse = function()
                custom_calls = custom_calls + 1
                return {}
            end,
        },
    },
})
assert(#state.validate() == 0, table.concat(state.validate(), '\n'))
vim.wait(30)
assert(vim.api.nvim_get_current_buf() == source, 'auto_open=false was ignored')
renderer.preview()
local projected = vim.api.nvim_get_current_buf()
local projected_text =
    table.concat(vim.api.nvim_buf_get_lines(projected, 0, -1, false), '\n')
assert(
    projected ~= source and #vim.api.nvim_list_wins() == windows,
    'Preview changed window layout'
)
assert(
    projected_text:find('```mermaid', 1, true)
        and not projected_text:find('Rendering', 1, true),
    'Missing optional Termaid did not preserve source fences'
)
assert(
    require('render-markdown.preview').get(projected) == source,
    'Projected preview lost source lookup'
)
renderer.render({ buf = projected })
assert(custom_calls > 0, 'Projection bypassed upstream custom handlers')
local mapped_buffer = renderer.source_location()
assert(mapped_buffer == source, 'Public source mapping did not resolve preview')
local destination =
    renderer.display_position(vim.api.nvim_get_current_win(), { 5, 7 })
assert(
    destination and destination[1] > 5,
    'Public source position did not map generated table rows'
)
renderer.buf_disable()
assert(
    vim.api.nvim_get_current_buf() == source,
    'buf_disable did not restore source'
)
renderer.buf_enable()
renderer.preview()
renderer.disable()
assert(
    vim.api.nvim_get_current_buf() == source and not renderer.get(),
    'disable did not restore source'
)
renderer.enable()
renderer.preview()
renderer.leave_preview()
assert(
    vim.api.nvim_get_current_buf() == source,
    'Public leave_preview did not restore source'
)
renderer.setup({ preview = { enabled = true } })
assert(
    vim.wait(200, function()
        return vim.api.nvim_get_current_buf() ~= source
    end, 5),
    'Lazy setup did not open the current Markdown source'
)
renderer.setup({ preview = { enabled = false } })
assert(
    vim.api.nvim_get_current_buf() == source,
    'Disabling projection through setup leaked its preview'
)
vim.api.nvim_set_current_buf(original_buffer)
vim.api.nvim_buf_delete(source, { force = true })
