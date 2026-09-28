local preview = require('render-markdown.preview')
local original_buffer = vim.api.nvim_get_current_buf()
local window = vim.api.nvim_get_current_win()
local fixture =
    { 'alpha BRAVO charlie', 'delta ECHO foxtrot', 'golf HOTEL india' }

require('render-markdown').setup({ preview = { mermaid = { enabled = false } } })

local function input(keys)
    vim.api.nvim_feedkeys(vim.keycode(keys), 'xt', false)
end

local function open_source(lines)
    local source = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(source)
    vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
    vim.bo[source].filetype = 'markdown'
    local buffer = preview.open(source)
    return source, buffer
end

local function wait_preview(source, buffer)
    assert(
        vim.wait(300, function()
            return vim.api.nvim_get_current_buf() == buffer
        end, 5),
        'Edit did not restore the retained preview'
    )
    assert(
        vim.b[buffer].markdown_preview_source == source
            and not vim.bo[buffer].modifiable,
        'Edit lost the source association or left the projection modifiable'
    )
end

-- Compare against native edits, including selection direction, registers and
-- exclusive endpoints. These commands must edit source, never generated text.
local cases = {
    'vld',
    'v2ld',
    'v2l"ad',
    'v2l"_d',
    'v2lcEDIT<Esc>',
    'v2lsEDIT<Esc>',
    'v2lrZ',
    'v2lp',
    'v2lP',
    'v2lU',
    'v2lu',
    'v2l~',
    'v2lg?',
    'v2lD',
    'v2lX',
    'v2l<Del>',
    'v2lCEDIT<Esc>',
    'v2lSEDIT<Esc>',
    'v2lREDIT<Esc>',
    'v2lgU',
    'v2lgu',
    'v2lg~',
    'v2lIEDIT<Esc>',
    'v2lAEDIT<Esc>',
    'Vjd',
    'VkcEDIT<Esc>',
    'VkJ',
    'VkgJ',
    'Vj>',
    'Vj2>',
    'Vj<',
    'Vj=',
    'v2hod',
    'v2hd',
    'v$d',
    'v$od',
    'vj$d',
    'vjld',
    'vkhd',
    'viwd',
    'vawd',
    '<C-v>jld',
    '<C-v>klcEDIT<Esc>',
    '<C-v>jlIEDIT<Esc>',
    '<C-v>jlAEDIT<Esc>',
    '<C-v>j$rZ',
    '<C-v>j$od',
}
for _, selection in ipairs({ 'inclusive', 'exclusive' }) do
    local original_selection = vim.o.selection
    vim.o.selection = selection
    for _, keys in ipairs(cases) do
        local reference = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_set_current_buf(reference)
        vim.api.nvim_buf_set_lines(reference, 0, -1, false, fixture)
        vim.api.nvim_win_set_cursor(window, { 2, 6 })
        vim.fn.setreg('a', 'REGISTER', 'v')
        vim.fn.setreg('"', 'PASTE', 'v')
        input(keys .. '<Esc>')
        local expected = vim.api.nvim_buf_get_lines(reference, 0, -1, false)
        local expected_register = vim.fn.getreg('a')
        local source, buffer = open_source(fixture)
        vim.api.nvim_win_set_cursor(window, { 2, 6 })
        vim.fn.setreg('a', 'REGISTER', 'v')
        vim.fn.setreg('"', 'PASTE', 'v')
        input(keys .. '<Esc>')
        wait_preview(source, buffer)
        local actual = vim.api.nvim_buf_get_lines(source, 0, -1, false)
        assert(
            vim.deep_equal(actual, expected),
            selection
                .. ' '
                .. keys
                .. ': '
                .. vim.inspect({ actual = actual, expected = expected })
        )
        assert(
            vim.fn.getreg('a') == expected_register,
            keys .. ': lost selected register'
        )
        vim.api.nvim_buf_delete(source, { force = true })
        vim.api.nvim_buf_delete(reference, { force = true })
    end
    vim.o.selection = original_selection
end

local source, buffer = open_source({ 'one 两🙂 three', 'untouched' })
vim.api.nvim_win_set_cursor(window, { 1, 4 })
input('vld')
wait_preview(source, buffer)
assert(
    vim.api.nvim_buf_get_lines(source, 0, 1, false)[1] == 'one  three',
    'UTF-8 selection split a character'
)
input('u')
assert(
    vim.api.nvim_buf_get_lines(source, 0, 1, false)[1] == 'one 两🙂 three',
    'Visual edit lost source undo'
)
input('<C-r>')
assert(
    vim.api.nvim_buf_get_lines(source, 0, 1, false)[1] == 'one  three',
    'Visual edit lost source redo'
)
vim.api.nvim_buf_delete(source, { force = true })

local table_lines = {
    'before',
    '',
    '| name | description |',
    '|---|---|',
    '| value | alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november |',
    '',
    'after',
}
local first_byte = assert(table_lines[5]:find('charlie', 1, true)) - 1
local last_byte = assert(table_lines[5]:find('november', 1, true))
    + #'november'
    - 2
for _, backwards in ipairs({ false, true }) do
    local table_source, table_buffer = open_source(table_lines)
    local first_position = preview.display_position(window, { 5, first_byte })
    local last_position = preview.display_position(window, { 5, last_byte })
    assert(
        first_position[1] < last_position[1],
        'Fixture needs wrapped table cells'
    )
    vim.api.nvim_win_set_cursor(
        window,
        backwards and last_position or first_position
    )
    input('v')
    vim.api.nvim_win_set_cursor(
        window,
        backwards and first_position or last_position
    )
    input('d')
    wait_preview(table_source, table_buffer)
    local expected_line = table_lines[5]:sub(1, first_byte)
        .. table_lines[5]:sub(last_byte + 2)
    assert(
        vim.api.nvim_buf_get_lines(table_source, 4, 5, false)[1]
            == expected_line,
        'Wrapped selection did not delete the mapped source range'
    )
    input('u')
    assert(
        vim.deep_equal(
            vim.api.nvim_buf_get_lines(table_source, 0, -1, false),
            table_lines
        )
    )
    -- Yanking remains native: the register contains the displayed selection.
    vim.api.nvim_win_set_cursor(window, first_position)
    input('vly')
    assert(vim.fn.getreg('"') == 'ch', 'Yank stopped copying displayed text')
    vim.api.nvim_win_set_cursor(window, first_position)
    input('Vd')
    wait_preview(table_source, table_buffer)
    assert(
        vim.api.nvim_buf_get_lines(table_source, 4, 5, false)[1] == '',
        'Linewise selection of a continuation did not delete its source row'
    )
    vim.api.nvim_buf_delete(table_source, { force = true })
end

local guarded_source, guarded_buffer = open_source(table_lines)
local mapped_position = preview.display_position(window, { 5, first_byte })
vim.api.nvim_win_set_cursor(window, mapped_position)
local original_notify = vim.notify
local notices = {}
vim.notify = function(message)
    notices[#notices + 1] = message
end
input('<C-v>ld')
assert(
    vim.api.nvim_get_mode().mode == '\22' and #notices == 1,
    'Generated block edit did not retain selection and explain source mode'
)
assert(
    vim.deep_equal(
        vim.api.nvim_buf_get_lines(guarded_source, 0, -1, false),
        table_lines
    ),
    'Generated block edit changed unrelated source columns'
)
input('<Esc>')

-- Provider refreshes and source changes must not replace a selected frame.
vim.api.nvim_win_set_cursor(window, { 1, 0 })
input('vl')
vim.api.nvim_buf_set_lines(
    guarded_source,
    0,
    1,
    false,
    { 'changed externally' }
)
vim.api.nvim_exec_autocmds('TextChanged', { buffer = guarded_source })
vim.wait(250)
assert(
    vim.api.nvim_buf_get_lines(guarded_buffer, 0, 1, false)[1] == 'before',
    'Background refresh replaced the selected preview frame'
)
input('d')
assert(
    vim.api.nvim_get_current_buf() == guarded_buffer and #notices == 2,
    'Stale selection was replayed into changed source'
)
assert(
    vim.api.nvim_buf_get_lines(guarded_source, 0, 1, false)[1]
        == 'changed externally',
    'Stale selection changed source text'
)
input('<Esc>')
assert(
    vim.wait(300, function()
        return vim.api.nvim_buf_get_lines(guarded_buffer, 0, 1, false)[1]
            == 'changed externally'
    end, 5),
    'Deferred refresh did not resume after Visual mode'
)
vim.notify = original_notify
vim.api.nvim_buf_delete(guarded_source, { force = true })
vim.api.nvim_set_current_buf(original_buffer)
