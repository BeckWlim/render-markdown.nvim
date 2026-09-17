local M = { max_source_bytes = 1024 * 1024, max_source_lines = 10000 }
local features = require('render-markdown.preview.features')
local markdown = require('render-markdown.preview.providers')
local namespace = vim.api.nvim_create_namespace('markdown_preview')
local cursor_namespace =
    vim.api.nvim_create_namespace('markdown_preview_cursor')
local sessions = {}
local sessions_by_preview = {}
local options = vim.deepcopy(require('render-markdown.preview.config').default)

local function enabled(source)
    local state = require('render-markdown.state')
    return options.enabled
        and state.enabled
        and state.get(source).enabled
        and not state.ignore(source)
end
local window_option_names = {
    'number',
    'relativenumber',
    'signcolumn',
    'foldcolumn',
    'foldenable',
    'foldmethod',
    'wrap',
    'linebreak',
    'breakindent',
    'breakindentopt',
    'showbreak',
    'smoothscroll',
    'cursorline',
    'winbar',
    'conceallevel',
    'concealcursor',
    'colorcolumn',
}

local function set_buffer(window, buffer)
    vim.api.nvim_win_call(window, function()
        vim.api.nvim_cmd({
            cmd = 'buffer',
            args = { tostring(buffer) },
            mods = { keepjumps = true },
        }, {})
    end)
end

local function preview_options(session)
    local window = session.window
    vim.wo[window].foldmethod = 'manual'
    vim.wo[window].number = session.source_options.number
    vim.wo[window].relativenumber = session.source_options.relativenumber
    vim.wo[window].signcolumn = 'no'
    vim.wo[window].foldcolumn = '0'
    vim.wo[window].foldenable = false
    vim.wo[window].wrap = true
    vim.wo[window].linebreak = true
    vim.wo[window].breakindent = true
    vim.wo[window].showbreak = '↳ '
    vim.wo[window].smoothscroll = true
    vim.wo[window].cursorline = true
    vim.wo[window].colorcolumn = ''
    vim.wo[window].winbar = ''
end

local function live(session)
    return sessions[session.source] == session
        and vim.api.nvim_buf_is_valid(session.source)
        and vim.api.nvim_win_is_valid(session.window)
        and vim.api.nvim_win_get_buf(session.window) == session.buffer
end

local function clamp_source_position(buffer, position)
    local row =
        math.max(1, math.min(position[1], vim.api.nvim_buf_line_count(buffer)))
    local line = vim.api.nvim_buf_get_lines(buffer, row - 1, row, false)[1]
        or ''
    return { row, math.min(position[2], #line) }
end

local function source_position(session)
    local cursor = vim.api.nvim_win_get_cursor(session.window)
    local row = session.rows[cursor[1]]
    return row and features.source_position(row, cursor[2]) or { 1, 0 }
end

local function remember_source_position(session)
    if
        not live(session)
        or session.changedtick
            ~= vim.api.nvim_buf_get_changedtick(session.source)
    then
        return
    end
    local position =
        clamp_source_position(session.source, source_position(session))
    session.anchor = vim.api.nvim_buf_set_extmark(
        session.source,
        namespace,
        position[1] - 1,
        position[2],
        { id = session.anchor }
    )
end

local function highlight_cursor(session)
    if not live(session) then
        return
    end
    local row = vim.api.nvim_win_get_cursor(session.window)[1] - 1
    vim.api.nvim_buf_clear_namespace(session.buffer, cursor_namespace, 0, -1)
    if not vim.wo[session.window].cursorline then
        return
    end
    vim.api.nvim_buf_set_extmark(session.buffer, cursor_namespace, row, 0, {
        end_row = row + 1,
        hl_group = 'CursorLine',
        hl_eol = true,
        priority = 1000,
    })
end

local function concealed_spans(buffer, row, line)
    local highlighter = vim.treesitter.highlighter.active[buffer]
    if not highlighter then
        return {}
    end
    local spans = {}
    highlighter.tree:for_each_tree(function(tree, language_tree)
        local root = tree:root()
        local first_row, _, last_row = root:range()
        if row < first_row or row > last_row then
            return
        end
        local query =
            vim.treesitter.query.get(language_tree:lang(), 'highlights')
        if not query then
            return
        end
        for id, node, metadata in
            query:iter_captures(root, buffer, row, row + 1)
        do
            local capture_metadata = metadata[id] or {}
            if capture_metadata.conceal ~= nil or metadata.conceal ~= nil then
                local range =
                    vim.treesitter.get_range(node, buffer, capture_metadata)
                local start_row, start_col, end_row, end_col =
                    range[1], range[2], range[4], range[5]
                if start_row <= row and end_row >= row then
                    local first_byte = start_row == row and start_col or 0
                    local last_byte = end_row == row and end_col or #line
                    spans[#spans + 1] = {
                        vim.fn.charidx(line, first_byte),
                        vim.fn.charidx(line, last_byte),
                    }
                end
            end
        end
    end)
    table.sort(spans, function(left, right)
        return left[1] < right[1]
    end)
    local merged = {}
    for _, span in ipairs(spans) do
        local previous = merged[#merged]
        if previous and span[1] <= previous[2] then
            previous[2] = math.max(previous[2], span[2])
        else
            merged[#merged + 1] = span
        end
    end
    return merged
end

local function move_horizontal(session, key, direction)
    local count = vim.v.count1
    local cursor = vim.api.nvim_win_get_cursor(session.window)
    local line = vim.api.nvim_buf_get_lines(
        session.buffer,
        cursor[1] - 1,
        cursor[1],
        false
    )[1]
    local mode = vim.api.nvim_get_mode().mode
    local conceal_mode = mode == 'n' and 'n' or 'v'
    local spans = vim.wo[session.window].conceallevel == 3
            and vim.wo[session.window].concealcursor:find(conceal_mode, 1, true)
            and concealed_spans(session.buffer, cursor[1] - 1, line)
        or {}
    local steps = count
    if #spans > 0 then
        local original_character = vim.fn.charidx(line, cursor[2])
        local character = original_character
        local character_count = vim.fn.strchars(line, true)
        for _ = 1, count do
            local candidate = character + direction
            for _, span in ipairs(spans) do
                if candidate >= span[1] and candidate < span[2] then
                    candidate = direction < 0 and span[1] - 1 or span[2]
                    break
                end
            end
            if candidate < 0 or candidate >= character_count then
                break
            end
            character = candidate
        end
        steps = math.abs(character - original_character)
    end
    -- Replay one native motion so Visual selection and UTF-8 character movement
    -- retain their usual semantics, without stopping on concealed URL bytes.
    if steps > 0 then
        vim.api.nvim_cmd({
            cmd = 'normal',
            args = { tostring(steps) .. vim.keycode(key) },
            bang = true,
        }, {})
    end
end

-- Each untouched prose run is a Markdown parse region. Generated rows already
-- contain their final text and styling; diagram labels must not become links,
-- list markers, or code blocks when the ordinary Markdown renderer attaches.
local function parse_prose(buffer, rows)
    local parser_ok, parser =
        pcall(vim.treesitter.get_parser, buffer, 'markdown')
    if not parser_ok then
        return
    end
    local regions = {}
    local first_row = nil
    for index = 1, #rows + 1 do
        local row = rows[index]
        if row and row.identity then
            if not first_row then
                first_row = index - 1
            end
        elseif first_row then
            regions[#regions + 1] = { { first_row, 0, index - 1, 0 } }
            first_row = nil
        end
    end
    parser:set_included_regions(regions)
end

local function restore_source(session, position)
    set_buffer(session.window, session.source)
    for name, value in pairs(session.source_options) do
        vim.wo[session.window][name] = value
    end
    vim.api.nvim_win_call(session.window, function()
        vim.fn.winrestview(session.source_view)
    end)
    vim.api.nvim_win_set_cursor(session.window, position)
end

local function sync_modified(session)
    if
        vim.api.nvim_buf_is_valid(session.source)
        and vim.api.nvim_buf_is_valid(session.buffer)
    then
        vim.bo[session.buffer].modified = vim.bo[session.source].modified
    end
end

local function close(session, buffer_wiping)
    if sessions[session.source] ~= session then
        return
    end
    local returning_to_source = live(session)
        and not buffer_wiping
        and not session.source_gone
    local position = live(session)
            and clamp_source_position(session.source, source_position(session))
        or nil
    sessions[session.source] = nil
    sessions_by_preview[session.buffer] = nil
    features.forget_buffer(session.source)
    markdown.detach(session.source)
    pcall(vim.api.nvim_del_augroup_by_id, session.group)
    if vim.api.nvim_buf_is_valid(session.source) then
        if returning_to_source then
            vim.b[session.source].markdown_preview_disabled = true
        end
        if session.anchor then
            pcall(
                vim.api.nvim_buf_del_extmark,
                session.source,
                namespace,
                session.anchor
            )
        end
    end
    if
        vim.api.nvim_win_is_valid(session.window)
        and vim.api.nvim_win_get_buf(session.window) == session.buffer
    then
        if returning_to_source then
            restore_source(session, position)
        elseif not buffer_wiping then
            local replacement = not session.source_gone
                    and vim.api.nvim_buf_is_valid(session.source)
                    and session.source
                or vim.api.nvim_create_buf(true, false)
            set_buffer(session.window, replacement)
        end
    end
    if vim.api.nvim_buf_is_valid(session.source) then
        vim.bo[session.source].bufhidden = session.source_bufhidden
    end
    if not buffer_wiping and vim.api.nvim_buf_is_valid(session.buffer) then
        vim.api.nvim_buf_delete(session.buffer, { force = true })
    end
end

local function jump_to_source(session)
    if not live(session) then
        return
    end
    if
        session.changedtick ~= vim.api.nvim_buf_get_changedtick(session.source)
    then
        M.refresh(session.source)
    end
    close(session)
    vim.cmd('normal! zv')
end

local function source_rows(buffer)
    local rows = {}
    for index, line in ipairs(vim.api.nvim_buf_get_lines(buffer, 0, -1, false)) do
        rows[index] =
            { chunks = { { line } }, source_row = index - 1, identity = true }
    end
    return rows
end

local function project(session)
    local line_count = vim.api.nvim_buf_line_count(session.source)
    local byte_count = vim.api.nvim_buf_get_offset(session.source, line_count)
    if line_count > M.max_source_lines or byte_count > M.max_source_bytes then
        return {
            {
                chunks = {
                    {
                        'Markdown preview: document exceeds the preview size limit.',
                    },
                },
                source_row = 0,
            },
        }
    end
    local parser_ok, parser =
        pcall(vim.treesitter.get_parser, session.source, 'markdown')
    if not parser_ok then
        return source_rows(session.source)
    end
    local tree = parser:parse()[1]
    if not tree then
        return source_rows(session.source)
    end
    local window_info = vim.fn.getwininfo(session.window)[1] or { textoff = 0 }
    return markdown.project({
        buf = session.source,
        root = tree:root(),
        width = math.max(
            1,
            vim.api.nvim_win_get_width(session.window) - window_info.textoff
        ),
        cache = session.feature_cache,
    })
end

function M.refresh(source)
    local session = sessions[source]
    if not session or not live(session) then
        return
    end
    local anchor_position = session.anchor
            and vim.api.nvim_buf_get_extmark_by_id(
                session.source,
                namespace,
                session.anchor,
                {}
            )
        or {}
    local previous_position = #anchor_position == 2
            and { anchor_position[1] + 1, anchor_position[2] }
        or source_position(session)
    local view = vim.api.nvim_win_call(session.window, vim.fn.winsaveview)
    local projected_rows, render_tasks = project(session)
    local function dispatch()
        features.dispatch(render_tasks, function()
            return sessions[source] == session
        end)
    end
    session.changedtick = vim.api.nvim_buf_get_changedtick(session.source)
    local ranges = features.changed_ranges(session.rows, projected_rows)
    if #session.rows == 0 and #ranges > 0 then
        ranges[1].old_count = vim.api.nvim_buf_line_count(session.buffer)
    end
    session.rows = projected_rows
    if #ranges == 0 then
        sync_modified(session)
        dispatch()
        return
    end
    -- A buffer replacement can synchronously redraw. Retire the old highlight
    -- iterators before changing lines whose Markdown parse regions are moving.
    local highlighted = vim.treesitter.highlighter.active[session.buffer] ~= nil
    if highlighted then
        vim.treesitter.stop(session.buffer)
    end
    vim.bo[session.buffer].modifiable = true
    for index = #ranges, 1, -1 do
        local range = ranges[index]
        local lines = {}
        for row_index = range.new_start + 1, range.new_start + range.new_count do
            local parts = {}
            for _, chunk in ipairs(projected_rows[row_index].chunks) do
                parts[#parts + 1] = chunk[1]
            end
            lines[#lines + 1] = table.concat(parts)
        end
        if range.old_count > 0 then
            vim.api.nvim_buf_clear_namespace(
                session.buffer,
                namespace,
                range.old_start,
                range.old_start + range.old_count
            )
        end
        vim.api.nvim_buf_set_lines(
            session.buffer,
            range.old_start,
            range.old_start + range.old_count,
            false,
            lines
        )
    end
    vim.bo[session.buffer].modifiable = false
    sync_modified(session)
    parse_prose(session.buffer, projected_rows)
    if highlighted then
        vim.treesitter.start(session.buffer)
    end
    for _, range in ipairs(ranges) do
        for index = range.new_start + 1, range.new_start + range.new_count do
            local row = projected_rows[index]
            local column = 0
            for _, chunk in ipairs(row.chunks) do
                if chunk[2] and #chunk[1] > 0 then
                    vim.api.nvim_buf_set_extmark(
                        session.buffer,
                        namespace,
                        index - 1,
                        column,
                        {
                            end_col = column + #chunk[1],
                            hl_group = chunk[2],
                            priority = 200,
                        }
                    )
                end
                column = column + #chunk[1]
            end
        end
    end
    local target = features.preview_position(
        projected_rows,
        previous_position[1] - 1,
        previous_position[2]
    )
    vim.api.nvim_win_call(session.window, function()
        vim.fn.winrestview(view)
    end)
    vim.api.nvim_win_set_cursor(session.window, target)
    remember_source_position(session)
    highlight_cursor(session)
    dispatch()
end

local function schedule_refresh(session)
    if session.pending then
        return
    end
    session.pending = true
    local function apply_when_idle()
        if not live(session) then
            session.pending = false
            return
        end
        local quiet_ms = (vim.uv.hrtime() - session.last_activity_ns) / 1e6
        if quiet_ms < 120 then
            vim.defer_fn(apply_when_idle, math.ceil(120 - quiet_ms))
            return
        end
        session.pending = false
        M.refresh(session.source)
    end
    vim.defer_fn(apply_when_idle, 80)
end

local function schedule_preview(source, window)
    vim.schedule(function()
        if
            vim.api.nvim_buf_is_valid(source)
            and vim.api.nvim_win_is_valid(window)
            and vim.api.nvim_get_current_win() == window
            and vim.api.nvim_win_get_buf(window) == source
            and vim.api.nvim_get_mode().mode == 'n'
            and enabled(source)
            and not vim.b[source].markdown_preview_disabled
        then
            M.open(source)
        end
    end)
end

local function edit_source(session, keys)
    if not live(session) then
        return
    end
    local count = vim.v.count > 0 and tostring(vim.v.count) or ''
    local register = vim.v.register
    if
        session.changedtick ~= vim.api.nvim_buf_get_changedtick(session.source)
    then
        M.refresh(session.source)
    end
    local position =
        clamp_source_position(session.source, source_position(session))
    -- Suppress automatic preview entry while restoring the source. Native keys
    -- then own counts, registers, motions, repeat, and the source undo history.
    vim.b[session.source].markdown_preview_disabled = true
    restore_source(session, position)
    vim.cmd('normal! zv')
    vim.b[session.source].markdown_preview_disabled = false
    vim.api.nvim_feedkeys(
        vim.keycode('"' .. register .. count .. keys),
        'ni',
        false
    )
    -- Also return after a native command that makes no change (for example x on
    -- an empty line). Pending operators and Insert mode remain in the source.
    schedule_preview(session.source, session.window)
end

function M.open(source)
    local window = vim.api.nvim_get_current_win()
    local existing = sessions[source]
    if existing and live(existing) and existing.window == window then
        return existing.buffer
    end
    if existing and existing.window == window then
        local source_cursor = vim.api.nvim_win_get_cursor(window)
        existing.source_view = vim.fn.winsaveview()
        for _, name in ipairs(window_option_names) do
            existing.source_options[name] = vim.wo[window][name]
        end
        set_buffer(window, existing.buffer)
        preview_options(existing)
        M.refresh(source)
        vim.api.nvim_win_set_cursor(
            window,
            features.preview_position(
                existing.rows,
                source_cursor[1] - 1,
                source_cursor[2]
            )
        )
        remember_source_position(existing)
        highlight_cursor(existing)
        return existing.buffer
    end
    if existing then
        close(existing)
    end
    local source_cursor = vim.api.nvim_win_get_cursor(window)
    local source_view = vim.fn.winsaveview()
    local source_options = {}
    for _, name in ipairs(window_option_names) do
        source_options[name] = vim.wo[window][name]
    end
    local source_bufhidden = vim.bo[source].bufhidden
    vim.bo[source].bufhidden = 'hide'
    vim.b[source].markdown_preview_disabled = false
    local buffer = vim.api.nvim_create_buf(false, true)
    vim.bo[buffer].buftype = 'acwrite'
    -- Native jump entries refer to this buffer. Keep it until an explicit source
    -- transition or source/window teardown so forward jumps retain their target.
    vim.bo[buffer].bufhidden = 'hide'
    vim.bo[buffer].swapfile = false
    vim.bo[buffer].undolevels = -1
    vim.b[buffer].markdown_preview_source = source
    vim.api.nvim_buf_set_name(buffer, ('markdown-preview://%d'):format(source))
    vim.wo[window].foldmethod = 'manual'
    set_buffer(window, buffer)
    local session = {
        source = source,
        buffer = buffer,
        window = window,
        rows = {},
        feature_cache = {},
        last_activity_ns = vim.uv.hrtime(),
        source_options = source_options,
        source_view = source_view,
        source_bufhidden = source_bufhidden,
        group = vim.api.nvim_create_augroup(
            'markdown_preview_' .. buffer,
            { clear = true }
        ),
    }
    sessions[source] = session
    sessions_by_preview[buffer] = session
    vim.api.nvim_create_autocmd('BufWriteCmd', {
        group = session.group,
        buffer = buffer,
        nested = true,
        callback = function(event)
            -- Write the original Markdown through Neovim, preserving its encoding,
            -- write hooks, readonly/conflict checks, and explicit bang/options.
            local preview_name = vim.api.nvim_buf_get_name(buffer)
            local destination = event.match ~= preview_name
                    and event.file ~= preview_name
                    and (' ' .. vim.fn.fnameescape(event.file))
                or ''
            local command = 'write'
                .. (vim.v.cmdbang == 1 and '!' or '')
                .. vim.v.cmdarg
                .. destination
            vim.api.nvim_buf_call(source, function()
                vim.cmd(command)
            end)
            sync_modified(session)
        end,
        desc = 'Save the Markdown source while keeping its rendered preview open',
    })
    preview_options(session)
    features.subscribe(source, function()
        schedule_refresh(session)
    end)
    local close_preview = function()
        close(session)
    end
    vim.keymap.set('n', 'q', close_preview, {
        buffer = buffer,
        nowait = true,
        silent = true,
        desc = 'Return to Markdown source',
    })
    vim.keymap.set(
        { 'n', 'x' },
        '<C-q>',
        close_preview,
        { buffer = buffer, silent = true }
    )
    for key, direction in pairs({
        h = -1,
        l = 1,
        ['<Left>'] = -1,
        ['<Right>'] = 1,
    }) do
        vim.keymap.set({ 'n', 'x' }, key, function()
            move_horizontal(session, key, direction)
        end, {
            buffer = buffer,
            silent = true,
            desc = 'Move across visible Markdown text',
        })
    end
    for _, keys in ipairs({
        'i',
        'I',
        'a',
        'A',
        'o',
        'O',
        's',
        'S',
        'c',
        'C',
        'd',
        'D',
        'x',
        'X',
        'r',
        'R',
        'p',
        'P',
        'J',
        '~',
        '.',
        '>',
        '<',
        '=',
        'gu',
        'gU',
        'g~',
    }) do
        vim.keymap.set('n', keys, function()
            edit_source(session, keys)
        end, {
            buffer = buffer,
            silent = true,
            desc = 'Edit Markdown source at cursor',
        })
    end
    for _, keys in ipairs({ 'u', '<C-r>' }) do
        vim.keymap.set('n', keys, function()
            local command_keys = tostring(vim.v.count1) .. vim.keycode(keys)
            vim.api.nvim_buf_call(source, function()
                vim.api.nvim_cmd(
                    { cmd = 'normal', args = { command_keys }, bang = true },
                    {}
                )
            end)
            M.refresh(source)
        end, {
            buffer = buffer,
            silent = true,
            desc = 'Undo/redo Markdown source',
        })
    end
    vim.keymap.set(
        'n',
        '<Space>mp',
        close_preview,
        { buffer = buffer, desc = 'Return to Markdown source' }
    )
    vim.api.nvim_create_autocmd('BufWinLeave', {
        group = session.group,
        buffer = buffer,
        callback = function()
            if not vim.api.nvim_win_is_valid(window) then
                return
            end
            for name, value in pairs(source_options) do
                vim.wo[window][name] = value
            end
            for _, name in ipairs({
                'wrap',
                'linebreak',
                'breakindent',
                'showbreak',
                'smoothscroll',
            }) do
                vim.wo[window][name] = vim.go[name]
            end
        end,
    })
    vim.api.nvim_create_autocmd('BufWinEnter', {
        group = session.group,
        buffer = buffer,
        callback = function()
            if not live(session) then
                return
            end
            preview_options(session)
            -- The native jump sets its destination cursor after BufWinEnter finishes.
            vim.schedule(function()
                if not live(session) then
                    return
                end
                remember_source_position(session)
                M.refresh(source)
                highlight_cursor(session)
            end)
        end,
    })
    vim.api.nvim_create_autocmd({
        'TextChanged',
        'TextChangedI',
        'BufWritePost',
        'FileChangedShellPost',
    }, {
        group = session.group,
        buffer = source,
        callback = function()
            schedule_refresh(session)
        end,
    })
    vim.api.nvim_create_autocmd('BufModifiedSet', {
        group = session.group,
        buffer = source,
        callback = function()
            sync_modified(session)
        end,
    })
    vim.api.nvim_create_autocmd('CursorMoved', {
        group = session.group,
        buffer = buffer,
        callback = function()
            session.last_activity_ns = vim.uv.hrtime()
            remember_source_position(session)
            highlight_cursor(session)
        end,
    })
    vim.api.nvim_create_autocmd('WinScrolled', {
        group = session.group,
        pattern = tostring(window),
        callback = function()
            session.last_activity_ns = vim.uv.hrtime()
        end,
    })
    vim.api.nvim_create_autocmd('WinResized', {
        group = session.group,
        callback = function()
            schedule_refresh(session)
        end,
    })
    vim.api.nvim_create_autocmd('BufWipeout', {
        group = session.group,
        buffer = source,
        callback = function()
            session.source_gone = true
            close(session)
        end,
    })
    vim.api.nvim_create_autocmd('BufWipeout', {
        group = session.group,
        buffer = buffer,
        callback = function()
            close(session, true)
        end,
    })
    vim.api.nvim_create_autocmd('WinClosed', {
        group = session.group,
        pattern = tostring(window),
        callback = close_preview,
    })
    M.refresh(source)
    vim.bo[buffer].filetype = 'markdown'
    pcall(vim.treesitter.start, buffer)
    vim.api.nvim_win_set_cursor(
        window,
        features.preview_position(
            session.rows,
            source_cursor[1] - 1,
            source_cursor[2]
        )
    )
    remember_source_position(session)
    highlight_cursor(session)
    return buffer
end

-- Syntax context resolves ancestry in the original document, then projects
-- heading positions back into this window's generated rows.
function M.source_location(window)
    local session = sessions_by_preview[vim.api.nvim_win_get_buf(window)]
    if not session or not live(session) or session.window ~= window then
        return
    end
    return session.source,
        clamp_source_position(session.source, source_position(session))
end

function M.display_position(window, position)
    local session = sessions_by_preview[vim.api.nvim_win_get_buf(window)]
    if not session or not live(session) or session.window ~= window then
        return
    end
    return features.preview_position(session.rows, position[1] - 1, position[2])
end

-- Leave the generated buffer before another full-pane UI captures the file and
-- editor options. Revisiting that file should retain its rendered preference.
function M.leave()
    local session = sessions_by_preview[vim.api.nvim_get_current_buf()]
    if not session or not live(session) then
        return
    end
    jump_to_source(session)
    if vim.api.nvim_buf_is_valid(session.source) then
        vim.b[session.source].markdown_preview_disabled = false
    end
end

function M.get(buffer)
    local session = sessions_by_preview[buffer]
    return session and session.source or nil
end

-- Match upstream enable/disable APIs while keeping explicit source preference.
function M.sync_enabled()
    local retired = {}
    for _, session in pairs(sessions) do
        if not enabled(session.source) then
            retired[#retired + 1] = session
        end
    end
    for _, session in ipairs(retired) do
        close(session)
        if vim.api.nvim_buf_is_valid(session.source) then
            vim.b[session.source].markdown_preview_disabled = false
        end
    end
    local buffer = vim.api.nvim_get_current_buf()
    if
        options.auto_open
        and vim.bo[buffer].filetype == 'markdown'
        and vim.bo[buffer].buftype == ''
    then
        schedule_preview(buffer, vim.api.nvim_get_current_win())
    end
end

function M.setup(config)
    local retired = {}
    for _, session in pairs(sessions) do
        retired[#retired + 1] = session
    end
    for _, session in ipairs(retired) do
        close(session)
        if vim.api.nvim_buf_is_valid(session.source) then
            vim.b[session.source].markdown_preview_disabled = false
        end
    end
    options = vim.deepcopy(
        config or require('render-markdown.preview.config').default
    )
    markdown.setup(options)
    local group = vim.api.nvim_create_augroup(
        'markdown_default_preview',
        { clear = true }
    )
    if not options.enabled then
        M.sync_enabled()
        return
    end
    local function render_when_normal(event)
        local buffer = event.buf
        local window = vim.api.nvim_get_current_win()
        if
            vim.bo[buffer].filetype ~= 'markdown'
            or vim.bo[buffer].buftype ~= ''
            or vim.b[buffer].markdown_preview_source
            or vim.api.nvim_win_get_buf(window) ~= buffer
        then
            return
        end
        vim.wo[window].conceallevel = 0
        if vim.b[buffer].markdown_preview_disabled or not options.auto_open then
            return
        end
        schedule_preview(buffer, window)
    end
    vim.api.nvim_create_autocmd({ 'FileType', 'BufWinEnter', 'TextChanged' }, {
        group = group,
        callback = render_when_normal,
        desc = 'Show Markdown files rendered by default in their current pane',
    })
    vim.api.nvim_create_autocmd('ModeChanged', {
        group = group,
        pattern = '*:n',
        callback = render_when_normal,
        desc = 'Return to rendered Markdown after a quick edit',
    })
    -- Native checktime skips hidden source buffers unless named explicitly.
    vim.api.nvim_create_autocmd(
        { 'FocusGained', 'BufEnter', 'CursorHold', 'CursorHoldI' },
        {
            group = group,
            nested = true,
            callback = function()
                for source in pairs(sessions) do
                    if vim.api.nvim_buf_is_loaded(source) then
                        vim.api.nvim_cmd(
                            { cmd = 'checktime', args = { tostring(source) } },
                            {}
                        )
                    end
                end
            end,
        }
    )
    -- Setup may run after the current buffer's FileType event under lazy loading.
    render_when_normal({ buf = vim.api.nvim_get_current_buf() })
end

function M.toggle()
    local buffer = vim.api.nvim_get_current_buf()
    local session = sessions_by_preview[buffer]
    if session then
        close(session)
        return
    end
    if not enabled(buffer) then
        return
    end
    if vim.bo[buffer].filetype ~= 'markdown' then
        vim.notify(
            'Markdown preview is available in Markdown buffers',
            vim.log.levels.INFO
        )
        return
    end
    M.open(buffer)
end

return M
