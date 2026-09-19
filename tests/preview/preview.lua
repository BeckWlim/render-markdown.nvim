local features = require('render-markdown.preview.features')
local markdown = require('render-markdown.preview.providers')
local preview = require('render-markdown.preview')
local original_buffer = vim.api.nvim_get_current_buf()
local original_options = {
    number = vim.wo.number,
    winbar = vim.wo.winbar,
    wrap = vim.wo.wrap,
    relativenumber = vim.wo.relativenumber,
    colorcolumn = vim.wo.colorcolumn,
    conceallevel = vim.wo.conceallevel,
    concealcursor = vim.wo.concealcursor,
}
local source = vim.api.nvim_create_buf(true, false)
local source_lines = {
    string.rep('Prose before the table. ', 10),
    '',
    '| heading | description |',
    '|---|---|',
    '| value | alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november |',
    '',
    string.rep('Prose after the table. ', 10),
}
vim.api.nvim_buf_set_lines(source, 0, -1, false, source_lines)
vim.api.nvim_set_current_buf(source)
local window = vim.api.nvim_get_current_win()
local window_count = #vim.api.nvim_list_wins()
local window_width = vim.api.nvim_win_get_width(window)
vim.wo[window].wrap = true
vim.wo[window].number = true
vim.wo[window].relativenumber = true
vim.wo[window].winbar = 'source window'
vim.wo[window].colorcolumn = '80,160'
local source_tick = vim.api.nvim_buf_get_changedtick(source)
require('render-markdown').setup({ preview = { enabled = true } })
vim.bo[source].filetype = 'markdown'
assert(
    vim.wait(200, function()
        return vim.api.nvim_get_current_buf() ~= source
    end, 5),
    'Markdown did not open rendered by default'
)
local preview_buffer = vim.api.nvim_get_current_buf()
assert(vim.wo[window].winbar == '', 'Preview retained the shortcut banner')
assert(
    vim.wo[window].colorcolumn == '',
    'Rendered Markdown retained editing column guides'
)
assert(
    vim.wo[window].number and vim.wo[window].relativenumber,
    'Preview hid the editor line-number settings'
)
assert(
    vim.api.nvim_get_current_win() == window
        and #vim.api.nvim_list_wins() == window_count
        and vim.api.nvim_win_get_width(window) == window_width,
    'Default rendering changed the pane layout'
)
assert(
    vim.b[preview_buffer].markdown_preview_source == source
        and not vim.bo[preview_buffer].modifiable,
    'Default view is not an independent read-only projection'
)
local preview_lines = vim.api.nvim_buf_get_lines(preview_buffer, 0, -1, false)
local blank_count = 0
for _, line in ipairs(preview_lines) do
    if line == '' then
        blank_count = blank_count + 1
    end
end
assert(
    blank_count == 2,
    'Preview inserted phantom blank rows beneath the table'
)
assert(
    #preview_lines > #source_lines,
    'Table continuations are not real preview lines'
)
assert(
    source_tick == vim.api.nvim_buf_get_changedtick(source),
    'Preview changed source text'
)
local prose_parser = vim.treesitter.get_parser(preview_buffer, 'markdown')
local prose_regions = prose_parser:included_regions()
assert(
    #prose_regions == 2,
    'Generated table rows were included in Markdown parsing'
)
assert(
    #prose_parser:trees() == #prose_regions,
    'Projected preview did not parse every prose region'
)
assert(
    prose_regions[1][1][1] == 0
        and prose_regions[1][1][4] == 2
        and prose_regions[2][1][1] == #preview_lines - 2,
    'Prose regions do not preserve the surrounding source lines'
)
local tree = assert(
    vim.treesitter.get_parser(source, 'markdown'):parse()[1],
    'Expected preview test condition'
)
local rows = markdown.project({
    buf = source,
    root = tree:root(),
    width = window_width - vim.fn.getwininfo(window)[1].textoff,
})
local target_row
for index, row in ipairs(rows) do
    if
        row.source_row == 4
        and row.spans
        and row.spans[1].source_column > 20
    then
        target_row = index
        break
    end
end
assert(target_row, 'Fixture has no mapped table continuation')
local target_column = rows[target_row].spans[1].first
local source_target = features.source_position(rows[target_row], target_column)
vim.api.nvim_win_set_cursor(window, { target_row, target_column })
vim.api.nvim_exec_autocmds('CursorMoved', { buffer = preview_buffer })
local cursor_namespace = vim.api.nvim_get_namespaces().markdown_preview_cursor
local cursor_marks = vim.api.nvim_buf_get_extmarks(
    preview_buffer,
    cursor_namespace,
    0,
    -1,
    { details = true }
)
assert(
    #cursor_marks == 1
        and cursor_marks[1][2] == target_row - 1
        and cursor_marks[1][4].hl_group == 'CursorLine'
        and cursor_marks[1][4].priority > 200,
    'Current table row does not place CursorLine above semantic chunk backgrounds'
)
-- Simulate the prose renderer's window options before returning to editable source.
vim.wo[window].conceallevel = 3
vim.wo[window].concealcursor = 'nvic'
vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'xt', false)
assert(
    vim.api.nvim_get_current_win() == window
        and vim.api.nvim_get_current_buf() == preview_buffer,
    'Enter unexpectedly switched the rendered table to source mode'
)
assert(
    vim.api.nvim_win_get_cursor(window)[1] == target_row + 1,
    'Enter lost its native next-line movement in the preview'
)
assert(
    vim.api.nvim_buf_get_changedtick(source) == source_tick
        and not vim.bo[preview_buffer].modifiable,
    'Enter changed the source or made the preview editable'
)
vim.api.nvim_win_set_cursor(window, { target_row, target_column })
vim.api.nvim_feedkeys('q', 'xt', false)
assert(
    vim.api.nvim_get_current_win() == window
        and vim.api.nvim_get_current_buf() == source,
    'q did not restore source in the same pane'
)
assert(
    vim.deep_equal(vim.api.nvim_win_get_cursor(window), source_target),
    'q lost its source byte position'
)
assert(
    vim.wo[window].number
        and vim.wo[window].winbar == 'source window'
        and vim.wo[window].wrap,
    'Returning to source did not restore window options'
)
assert(
    vim.wo[window].conceallevel == 0
        and vim.wo[window].concealcursor == original_options.concealcursor,
    'Source mode still conceals Markdown punctuation'
)
vim.api.nvim_exec_autocmds('BufWinEnter', { buffer = source })
vim.wait(50)
assert(
    vim.api.nvim_get_current_buf() == source,
    'Automatic preview overrode the explicit source selection'
)
assert(
    not vim.api.nvim_buf_is_valid(preview_buffer),
    'Source toggle retained the old preview buffer'
)
assert(
    vim.wo[window].colorcolumn == '80,160',
    'Source toggle lost its editing column guides'
)
preview.toggle()
local quick_edit_preview = vim.api.nvim_get_current_buf()
vim.api.nvim_win_set_cursor(window, { target_row, target_column })
vim.api.nvim_feedkeys(vim.keycode('iEDIT<Esc>'), 'xt', false)
assert(
    vim.wait(200, function()
        return vim.b.markdown_preview_source == source
    end, 5),
    'Leaving Insert mode did not automatically restore the rendered preview'
)
assert(
    vim.api.nvim_get_current_buf() == quick_edit_preview,
    'Quick edit replaced the retained preview buffer'
)
assert(
    vim.api.nvim_get_current_win() == window
        and not vim.bo.modifiable
        and vim.bo[source].modified,
    'Quick edit changed panes, left preview editable, or discarded unsaved changes'
)
local original_table_line = source_lines[source_target[1]]
local expected_table_line = original_table_line:sub(1, source_target[2])
    .. 'EDIT'
    .. original_table_line:sub(source_target[2] + 1)
assert(
    vim.api.nvim_buf_get_lines(
        source,
        source_target[1] - 1,
        source_target[1],
        false
    )[1] == expected_table_line,
    'Typing from a wrapped preview cell did not insert at its mapped source byte'
)
local _, edited_position = preview.source_location(window)
assert(
    edited_position and edited_position[1] == source_target[1],
    'Automatic preview lost the edited source row'
)
vim.api.nvim_feedkeys(vim.keycode('<Space>mp'), 'xt', false)
vim.api.nvim_feedkeys(vim.keycode('iRAW<Esc>'), 'xt', false)
vim.wait(50)
assert(
    vim.api.nvim_get_current_buf() == source
        and vim.b[source].markdown_preview_disabled,
    'Leaving Insert mode overrode explicitly selected raw source'
)
vim.api.nvim_buf_set_lines(
    source,
    source_target[1] - 1,
    source_target[1],
    false,
    { original_table_line }
)
vim.api.nvim_buf_set_lines(source, 6, 7, false, { 'changed prose after table' })
preview.toggle()
local reopened = vim.api.nvim_get_current_buf()
assert(
    reopened ~= source and #vim.api.nvim_list_wins() == window_count,
    'Render toggle opened an extra pane'
)
assert(
    vim.api.nvim_buf_get_lines(reopened, -2, -1, false)[1]
        == 'changed prose after table',
    'Reopening the rendered view did not reflect source edits'
)
local display_namespace = vim.api.nvim_get_namespaces().markdown_preview
local table_marks =
    vim.api.nvim_buf_get_extmarks(reopened, display_namespace, 0, -1, {})
vim.api.nvim_buf_set_lines(
    source,
    0,
    1,
    false,
    { 'Changed prose before table' }
)
vim.api.nvim_buf_set_lines(
    source,
    6,
    7,
    false,
    { 'Another change after table' }
)
preview.refresh(source)
assert(
    vim.deep_equal(
        table_marks,
        vim.api.nvim_buf_get_extmarks(reopened, display_namespace, 0, -1, {})
    ),
    'Prose changes on both sides repainted unchanged table highlights'
)
vim.api.nvim_buf_set_lines(source, 6, 7, false, { 'changed prose after table' })
preview.refresh(source)
vim.api.nvim_win_set_cursor(
    window,
    { vim.api.nvim_buf_line_count(reopened), 0 }
)
vim.api.nvim_exec_autocmds('CursorMoved', { buffer = reopened })
vim.treesitter.start(reopened)
vim.api.nvim_buf_set_lines(
    source,
    0,
    0,
    false,
    { 'inserted above preview selection' }
)
vim.api.nvim_exec_autocmds('TextChanged', { buffer = source })
for _ = 1, 4 do
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = reopened })
    vim.wait(50)
    assert(
        vim.api.nvim_buf_get_lines(reopened, 0, 1, false)[1]
            ~= 'inserted above preview selection',
        'A background refresh interrupted ongoing preview navigation'
    )
end
assert(
    vim.wait(200, function()
        return vim.api.nvim_buf_get_lines(reopened, 0, 1, false)[1]
            == 'inserted above preview selection'
    end, 5),
    'Hidden source edits did not refresh the rendered view'
)
assert(
    vim.treesitter.highlighter.active[reopened],
    'Refresh did not restore prose highlighting'
)
local preserved_cursor = vim.api.nvim_win_get_cursor(window)
assert(
    vim.api.nvim_buf_get_lines(
        reopened,
        preserved_cursor[1] - 1,
        preserved_cursor[1],
        false
    )[1] == 'changed prose after table',
    'Source insertion moved the selection to unrelated text'
)
vim.api.nvim_feedkeys('q', 'xt', false)
assert(
    vim.api.nvim_win_is_valid(window)
        and vim.api.nvim_get_current_buf() == source,
    'Leaving rendered view closed the editor pane'
)
features.request_render(source, 'late result')
vim.wait(50)
assert(
    vim.api.nvim_get_current_buf() == source,
    'Late callback reopened an explicitly closed view'
)
preview.toggle()
local code_buffer = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(code_buffer)
assert(
    vim.api.nvim_get_current_buf() == code_buffer and vim.wo.wrap == vim.go.wrap,
    'Leaving rendered Markdown changed the next buffer or leaked its wrapping'
)
vim.api.nvim_set_current_buf(source)
assert(
    vim.wait(200, function()
        return vim.api.nvim_get_current_buf() ~= source
    end, 5),
    'Revisiting a rendered Markdown file unexpectedly selected raw source'
)
preview.toggle()
vim.api.nvim_buf_delete(code_buffer, { force = true })
preview.toggle()
preview.toggle()
assert(
    #vim.api.nvim_list_wins() == window_count
        and vim.api.nvim_get_current_buf() == source,
    'Repeated toggles changed window layout or source selection'
)
vim.cmd('vsplit')
local second_window = vim.api.nvim_get_current_win()
preview.toggle()
vim.api.nvim_set_current_win(window)
preview.toggle()
assert(
    vim.api.nvim_get_current_win() == window
        and vim.b.markdown_preview_source == source
        and vim.api.nvim_win_get_buf(second_window) == source,
    'Toggling a shared Markdown file redirected focus into another pane'
)
preview.toggle()
vim.api.nvim_win_close(second_window, true)
vim.api.nvim_del_augroup_by_name('markdown_default_preview')
vim.api.nvim_set_current_buf(original_buffer)
vim.api.nvim_buf_delete(source, { force = true })
local section_source = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(section_source, 0, -1, false, {
    '# Document',
    '',
    '## Table section',
    '',
    '| Key | Value |',
    '|---|---|',
    '| item | ' .. string.rep('wrapped content ', 100) .. '|',
    '',
    '## Next section',
    '',
    'Next body',
})
vim.api.nvim_set_current_buf(section_source)
vim.bo.filetype = 'markdown'
preview.open(section_source)
local section_position = preview.display_position(window, { 7, 400 })
vim.api.nvim_win_set_cursor(window, section_position)
vim.cmd('normal! zt5j')
local mapped_source, mapped_position = preview.source_location(window)
assert(
    mapped_source == section_source and mapped_position[1] == 7,
    'Generated rows lost their source section position'
)
preview.toggle()
vim.wo.number = false
vim.wo.relativenumber = false
preview.open(section_source)
assert(
    not vim.wo.number and not vim.wo.relativenumber,
    'Preview overrode an intentional choice to hide line numbers'
)
preview.toggle()
vim.api.nvim_set_current_buf(original_buffer)
vim.api.nvim_buf_delete(section_source, { force = true })

-- Disk reloads affect the hidden source without firing its editing events.
local external_path = vim.fn.tempname() .. '.md'
local saved_autoread = vim.o.autoread
vim.o.autoread = true
vim.fn.writefile({ '# Before reload', '', 'Original prose' }, external_path)
vim.api.nvim_cmd({ cmd = 'edit', args = { external_path } }, {})
local external_source = vim.api.nvim_get_current_buf()
local external_preview = preview.open(external_source)
vim.fn.writefile(
    { '# After external reload', '', 'Updated prose from disk' },
    external_path
)
vim.api.nvim_cmd(
    { cmd = 'checktime', args = { tostring(external_source) } },
    {}
)
assert(
    vim.api.nvim_buf_get_lines(external_source, 0, 1, false)[1]
        == '# After external reload',
    'External change fixture did not reload its hidden source'
)
assert(
    vim.wait(500, function()
        return vim.api.nvim_buf_get_lines(external_preview, 0, 1, false)[1]
            == '# After external reload'
    end, 5),
    'External file reload did not refresh the rendered preview'
)
assert(
    vim.api.nvim_get_current_buf() == external_preview
        and not vim.bo[external_source].modified,
    'External reload left the preview or modified the source'
)
vim.api.nvim_buf_set_lines(
    external_source,
    0,
    1,
    false,
    { '# Unsaved local edit' }
)
vim.fn.writefile(
    { '# Conflicting external change', '', 'Disk content' },
    external_path
)
local conflict_reason
local conflict_handler = vim.api.nvim_create_autocmd('FileChangedShell', {
    buffer = external_source,
    callback = function()
        conflict_reason = vim.v.fcs_reason
        vim.v.fcs_choice = '' -- Keep local edits without opening an interactive prompt in the test.
    end,
})
vim.api.nvim_cmd(
    { cmd = 'checktime', args = { tostring(external_source) } },
    {}
)
assert(
    conflict_reason == 'conflict'
        and vim.bo[external_source].modified
        and vim.api.nvim_buf_get_lines(external_source, 0, 1, false)[1]
            == '# Unsaved local edit',
    'External file checks bypassed Neovim conflict handling or overwrote local edits'
)
assert(
    vim.api.nvim_get_current_buf() == external_preview
        and vim.api.nvim_buf_get_lines(external_preview, 0, 1, false)[1]
            ~= '# Conflicting external change',
    'Conflict handling replaced the preview with disk content'
)
vim.api.nvim_del_autocmd(conflict_handler)
preview.toggle()
vim.api.nvim_set_current_buf(original_buffer)
vim.api.nvim_buf_delete(external_source, { force = true })
vim.fn.delete(external_path)
vim.o.autoread = saved_autoread

-- :write targets raw Markdown, with native write hooks and failure handling.
local write_path = vim.fn.tempname() .. ' source.md'
vim.fn.writefile(
    { '# Original', '', '| Key | Value |', '|---|---|', '| item | original |' },
    write_path
)
vim.api.nvim_cmd({ cmd = 'edit', args = { write_path } }, {})
local write_source = vim.api.nvim_get_current_buf()
vim.bo[write_source].filetype = 'markdown'
vim.api.nvim_buf_set_lines(
    write_source,
    4,
    5,
    false,
    { '| item | unsaved edit |' }
)
local write_preview = preview.open(write_source)
assert(
    vim.bo[write_preview].modified,
    'Preview did not mirror unsaved source state'
)
local write_cursor = vim.api.nvim_win_get_cursor(window)
local write_events = {}
local write_group =
    vim.api.nvim_create_augroup('markdown_preview_write_test', { clear = true })
vim.api.nvim_create_autocmd({ 'BufWritePre', 'BufWritePost' }, {
    group = write_group,
    buffer = write_source,
    callback = function(event)
        write_events[#write_events + 1] = event.event
        assert(
            vim.api.nvim_get_current_buf() == write_source,
            'Write hook did not run in the source buffer'
        )
    end,
})
vim.cmd('write')
assert(
    vim.deep_equal(
        vim.fn.readfile(write_path),
        vim.api.nvim_buf_get_lines(write_source, 0, -1, false)
    ),
    'Writing from preview saved rendered rows instead of raw Markdown'
)
assert(
    vim.deep_equal(write_events, { 'BufWritePre', 'BufWritePost' })
        and not vim.bo[write_source].modified,
    'Preview write skipped source hooks or left the saved source modified'
)
assert(
    not vim.bo[write_preview].modified,
    'Saved preview still reports unsaved changes'
)
assert(
    vim.api.nvim_get_current_buf() == write_preview
        and not vim.bo[write_preview].modifiable
        and vim.deep_equal(vim.api.nvim_win_get_cursor(window), write_cursor),
    'Writing changed the preview buffer, editability, or cursor'
)
vim.api.nvim_buf_set_lines(
    write_source,
    0,
    1,
    false,
    { '# Unsaved readonly edit' }
)
vim.bo[write_source].readonly = true
local readonly_written, readonly_error = pcall(vim.cmd, 'write')
assert(
    not readonly_written
        and tostring(readonly_error):find('E45', 1, true)
        and vim.bo[write_source].modified
        and vim.fn.readfile(write_path)[1] == '# Original',
    'Preview write bypassed readonly protection or lost unsaved edits on failure'
)
assert(
    vim.api.nvim_get_current_buf() == write_preview,
    'Failed write left the preview'
)
vim.cmd('write!')
assert(
    not vim.bo[write_source].modified
        and vim.fn.readfile(write_path)[1] == '# Unsaved readonly edit',
    'Explicit forced preview write did not reach the source'
)
vim.bo[write_source].readonly = false
vim.api.nvim_buf_set_lines(
    write_source,
    0,
    1,
    false,
    { '# Update from preview' }
)
preview.refresh(write_source)
vim.cmd('update')
assert(
    not vim.bo[write_source].modified
        and not vim.bo[write_preview].modified
        and vim.fn.readfile(write_path)[1] == '# Update from preview',
    'Update skipped the dirty source behind the preview'
)
local copy_path = vim.fn.tempname() .. ' raw copy.md'
vim.api.nvim_cmd({ cmd = 'write', args = { copy_path } }, {})
assert(
    vim.deep_equal(
        vim.fn.readfile(copy_path),
        vim.api.nvim_buf_get_lines(write_source, 0, -1, false)
    )
        and vim.api.nvim_buf_get_name(write_source) == write_path
        and vim.api.nvim_get_current_buf() == write_preview,
    'Writing a named copy from preview changed the source identity or exported rendered rows'
)
vim.fn.delete(copy_path)
vim.api.nvim_del_augroup_by_id(write_group)
preview.toggle()
vim.api.nvim_set_current_buf(original_buffer)
vim.api.nvim_buf_delete(write_source, { force = true })
vim.fn.delete(write_path)
for name, value in pairs(original_options) do
    vim.wo[name] = value
end
