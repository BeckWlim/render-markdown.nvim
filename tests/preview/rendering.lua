local renderer = require('render-markdown')
local preview = require('render-markdown.preview')
local ui = require('render-markdown.core.ui')
local original = vim.api.nvim_get_current_buf()
renderer.setup({
    debounce = 100,
    preview = { auto_open = false, mermaid = { enabled = false } },
})
local source = vim.api.nvim_create_buf(true, false)
local filename = vim.fn.tempname() .. '.md'
vim.api.nvim_buf_set_name(source, filename)
vim.api.nvim_set_current_buf(source)
local lines = { '# Quick editing', '' }
for _ = 1, 80 do
    lines[#lines + 1] = 'prose'
end
vim.list_extend(lines, { '', '```text', 'payload', '```', '', 'end' })
vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
vim.bo[source].filetype = 'markdown'
local window = vim.api.nvim_get_current_win()
local display = preview.open(source)
assert(vim.wait(50, function()
    return ui.get(display).n > 0
end, 1), 'Preview did not render promptly')
vim.api.nvim_win_set_cursor(window, { 84, 0 })
vim.cmd('normal! zt')
vim.api.nvim_exec_autocmds('CursorMoved', { buffer = display })
local function has_language_label()
    local marks = vim.api.nvim_buf_get_extmarks(
        display, ui.ns, 0, -1, { details = true }
    )
    for _, mark in ipairs(marks) do
        if mark[2] == 83 then
            for _, chunk in ipairs(mark[4].virt_text or {}) do
                if chunk[1]:find('text', 1, true) then
                    return true
                end
            end
        end
    end
    return false
end
assert(
    vim.wait(500, has_language_label, 5),
    'Viewport update during debounce lost the code language label'
)
vim.api.nvim_win_set_cursor(window, { 82, 0 })
vim.api.nvim_feedkeys(vim.keycode('iZ<Esc>'), 'xt', false)
assert(vim.wait(200, function()
    return vim.api.nvim_win_get_buf(window) == display
end, 1), 'Quick edit did not return to its preview')
assert(
    vim.api.nvim_buf_get_lines(source, 81, 82, false)[1] == 'Zprose',
    'Quick edit did not modify the mapped source'
)
assert(vim.wait(500, has_language_label, 5),
    'Unsaved quick edit lost the code language label')
assert(vim.bo[source].modified and vim.bo[display].modified,
    'Unsaved preview cleared its source or display modified flag')
assert(vim.fn.filereadable(filename) == 0,
    'Returning to preview wrote a new unsaved file')
preview.toggle()
assert(vim.api.nvim_get_current_buf() == source and vim.bo[source].modified,
    'Explicit source mode lost the unsaved edit')
display = preview.open(source)
assert(vim.wait(500, has_language_label, 5),
    'Reopening unsaved content lost the code language label')
assert(vim.bo[display].modified and vim.fn.filereadable(filename) == 0,
    'Reopening preview saved or cleared new unsaved content')
vim.cmd('silent write')
assert(
    vim.deep_equal(
        vim.fn.readfile(filename),
        vim.api.nvim_buf_get_lines(source, 0, -1, false)
    ),
    'Saving the preview wrote generated text instead of its edited source'
)
assert(
    vim.wait(500, has_language_label, 5),
    'Quick editing and saving lost the code language label'
)
local saved_lines = vim.fn.readfile(filename)
vim.api.nvim_win_set_cursor(window, { 82, 0 })
vim.api.nvim_feedkeys(vim.keycode('iUnsaved <Esc>'), 'xt', false)
assert(vim.wait(500, function()
    return vim.api.nvim_get_current_buf() == display
        and vim.api.nvim_buf_get_lines(source, 81, 82, false)[1] == 'Unsaved Zprose'
        and has_language_label()
end, 5), 'Unsaved changes to an existing file lost its code label')
assert(vim.bo[source].modified and vim.bo[display].modified,
    'Existing-file preview cleared unsaved changes')
assert(vim.deep_equal(vim.fn.readfile(filename), saved_lines),
    'Existing-file preview wrote unsaved changes to disk')
vim.api.nvim_set_current_buf(original)
vim.api.nvim_buf_delete(source, { force = true })
vim.fn.delete(filename)

-- Programmatic frame commits must render without relying on TextChanged or
-- cursor events. Consecutive commits can change the language and its position
-- while the leading render is still within its debounce interval.
local frame_initializations = 0
renderer.setup({
    debounce = 100,
    preview = { auto_open = false, mermaid = { enabled = false } },
    on = { initial = function() frame_initializations = frame_initializations + 1 end },
})
local frame_source = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(frame_source)
local frame_filename = vim.fn.tempname() .. '.md'
vim.api.nvim_buf_set_name(frame_source, frame_filename)
vim.api.nvim_buf_set_lines(frame_source, 0, -1, false, {
    '# Frame', 'ordinary prose', '', '```text', 'payload', '```', '', 'end',
})
vim.bo[frame_source].filetype = 'markdown'
local frame_display = preview.open(frame_source)
local function frame_label(row, language)
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
        frame_display, ui.ns, 0, -1, { details = true }
    )) do
        if mark[2] == row then
            for _, chunk in ipairs(mark[4].virt_text or {}) do
                if chunk[1]:find(language, 1, true) then
                    return true
                end
            end
        end
    end
    return false
end
assert(vim.wait(500, function() return frame_label(3, 'text') end, 5),
    'Initial frame has no language label')
vim.api.nvim_buf_set_lines(frame_source, 1, 2, false, { 'edited ordinary prose' })
vim.api.nvim_buf_set_lines(frame_source, 3, 4, false, { '```lua' })
preview.refresh(frame_source)
assert(vim.wait(500, function()
    return frame_label(3, 'lua') and not frame_label(3, 'text')
end, 5), 'Frame commit retained stale language decorations')
vim.api.nvim_buf_set_lines(frame_source, 1, 2, false, {
    'first prose change', 'extra prose row',
})
preview.refresh(frame_source)
vim.api.nvim_buf_set_lines(frame_source, 4, 5, false, { '```python' })
preview.refresh(frame_source)
vim.api.nvim_buf_set_lines(frame_source, 4, 5, false, { '```text' })
preview.refresh(frame_source)
assert(vim.wait(500, function()
    return frame_label(4, 'text') and not frame_label(4, 'python')
        and not frame_label(4, 'lua')
end, 5), 'Rapid commits did not render the latest frame')
vim.cmd('silent write')
assert(vim.wait(500, function() return frame_label(4, 'text') end, 5),
    'Saving the latest frame lost its code label')
assert(vim.deep_equal(vim.fn.readfile(frame_filename),
    vim.api.nvim_buf_get_lines(frame_source, 0, -1, false)),
    'Frame save did not preserve the Markdown source')
assert(frame_initializations == 1, 'Frame rebuild repeated the initial render hook')
-- A queued rebuild must not decorate a source window after leaving preview.
vim.api.nvim_buf_set_lines(frame_source, 1, 2, false, { 'final prose change' })
preview.refresh(frame_source)
preview.toggle()
vim.wait(150)
assert(vim.api.nvim_get_current_buf() == frame_source,
    'Queued frame rebuild returned a retired preview')
assert(#vim.api.nvim_buf_get_extmarks(frame_source, ui.ns, 0, -1, {}) == 0,
    'Queued frame rebuild decorated the explicit source view')
vim.api.nvim_set_current_buf(original)
vim.api.nvim_buf_delete(frame_source, { force = true })
vim.fn.delete(frame_filename)
