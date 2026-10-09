-- Each pane of a Markdown source owns its projection, cursor, and render jobs.
local renderer = require('render-markdown')
local preview = require('render-markdown.preview')
local mermaid = require('render-markdown.preview.mermaid')
local original_buffer = vim.api.nvim_get_current_buf()
local original_command = mermaid.find_executable
local original_process = mermaid.start_process
local requests = {}
rawset(mermaid, 'find_executable', function() return '/test/bin/termaid-shared-windows' end)
rawset(mermaid, 'start_process', function(command, _, callback)
    local request = { command = command, killed = false, completed = false }
    request.callback = function(result) request.completed = true; callback(result) end
    requests[#requests + 1] = request
    if vim.tbl_contains(command, '--format') then
        request.callback({ code = 2, stdout = '', stderr = 'unrecognized arguments: --format' })
    end
    return { kill = function() request.killed = true end }
end)
renderer.setup({ preview = { condition = function() return true end, enabled = true, mermaid = { enabled = true } } })
vim.cmd.tabnew()
local first = vim.api.nvim_get_current_win()
local source = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(source, 0, -1, false, {
    '# Shared views', '', '| Key | Value |', '|---|---|',
    '| link | ' .. string.rep('wrapped text ', 35) .. ' |', '',
    '```mermaid', 'graph LR', '  SharedSource --> SeparateWindows', '```',
})
vim.bo.filetype = 'markdown'
local first_preview = preview.open(source)
vim.cmd.vsplit()
local second = vim.api.nvim_get_current_win()
assert(vim.wait(200, function() return preview.source_location(second) == source end, 5),
    'Native split copied a preview without creating its source map')
local second_preview = vim.api.nvim_get_current_buf()
assert(second_preview ~= first_preview, 'Two panes share one generated projection')
vim.api.nvim_win_set_width(second, 25)
preview.refresh(source)
assert(vim.api.nvim_buf_line_count(second_preview) > vim.api.nvim_buf_line_count(first_preview),
    'Different-width windows did not project tables independently')
local first_cursor = assert(preview.display_position(first, { 5, 4 }))
local second_cursor = assert(preview.display_position(second, { 1, 2 }))
vim.api.nvim_win_set_cursor(first, first_cursor)
vim.api.nvim_win_set_cursor(second, second_cursor)
local _, first_source_position = preview.source_location(first)
local _, second_source_position = preview.source_location(second)
assert(first_source_position and second_source_position
    and first_source_position[1] == 5 and second_source_position[1] == 1,
    'Moving one preview changed the other source cursor')

-- Complete the two current width-specific jobs in reverse order. A refresh in
-- the other pane must neither cancel the request nor discard its completion.
local active = {}
assert(vim.wait(500, function()
    active = {}
    for _, request in ipairs(requests) do
        if not request.killed and not request.completed then active[#active + 1] = request end
    end
    return #active == 2
end, 5), 'Different-width views did not retain two independent render jobs')
for index = #active, 1, -1 do
    active[index].callback({ code = 0, stdout = 'shared window diagram\n', stderr = '' })
end
assert(vim.wait(500, function()
    local first_blocks = mermaid.stage(source, first_preview)
    local second_blocks = mermaid.stage(source, second_preview)
    return #first_blocks == 1 and not first_blocks[1].pending
        and #second_blocks == 1 and not second_blocks[1].pending
end, 5), 'One window discarded the other diagram completion')
preview.refresh(source)
vim.wait(20)
local request_count = #requests
preview.refresh(source)
vim.wait(20)
assert(#requests == request_count, 'Stable window widths keep restarting each other render jobs')

vim.bo[source].modified = false
vim.api.nvim_set_current_win(second)
vim.cmd.quit()
assert(not vim.api.nvim_win_is_valid(second) and vim.api.nvim_win_is_valid(first),
    'Quit closed more than its focused Markdown pane')
assert(preview.source_location(first) == source and vim.api.nvim_buf_is_valid(first_preview),
    'Quit retired the surviving window projection')
assert(#mermaid.stage(source, first_preview) == 1,
    'Closing one pane detached provider state from the surviving pane')
vim.api.nvim_set_current_win(first)
preview.toggle()
vim.cmd.tabclose()
vim.api.nvim_set_current_buf(original_buffer)
vim.api.nvim_buf_delete(source, { force = true })
rawset(mermaid, 'find_executable', original_command)
rawset(mermaid, 'start_process', original_process)
