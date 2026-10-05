-- Interaction owns source document services, coordinate-aware contexts, native
-- selection, and routed operation acquisition, completion, and cancellation.
---@class render.md.interaction.Range
---@field start integer[]
---@field finish integer[]
---@field quality? 'exact'|'anchor'
---@field kind? string

---@class render.md.interaction.Context
---@field window integer
---@field source integer
---@field buffer integer
---@field projected boolean
---@field position integer[]
---@field position_quality 'exact'|'anchor'
---@field changedtick integer
---@field mode string
---@field count integer
---@field register string
---@field filename string Canonical source filename.
---@field filetype string Canonical source filetype.
---@field private _rows? MarkdownPreviewRow[]
---@field private _valid? fun(): boolean
---@field private _visible? fun(position: integer[]): boolean
---@field _operation? render.md.interaction.Token Internal operation owner.

---@class render.md.interaction.Token
---@field context render.md.interaction.Context
---@field target 'display'|'source'
---@field cursor integer[]
---@field done? boolean
---@field cancelling? boolean
---@field group? integer
---@field timer? table
---@field valid fun(self: render.md.interaction.Token): boolean
---@field finish fun(self: render.md.interaction.Token): boolean
---@field cancel fun(self: render.md.interaction.Token, keep_cursor?: boolean): boolean

---@class render.md.interaction.Operation
---@field target? 'display'|'source'
---@field run fun(context: render.md.interaction.Context, token: render.md.interaction.Token, ...: any): any
---@field async? boolean
---@field exact? boolean
---@field timeout? integer
---@field track_cursor? boolean
---@field cancel? fun()

local M = {}
---@class render.md.interaction.Context
local Context = {}
Context.__index = Context
local active = {}
local projection = require('render-markdown.preview.projection')
local function pack(...) return { n = select('#', ...), ... } end

local function link_at(buffer, position)
    local ok, parser = pcall(vim.treesitter.get_parser, buffer, 'markdown')
    if not ok or not parser then
        return
    end
    parser:parse(true)
    local result
    local point = { position[1] - 1, position[2], position[1] - 1, position[2] }
    parser:for_each_tree(function(tree, language_tree)
        if result or not language_tree:contains(point) then
            return
        end
        local node = tree:root():named_descendant_for_range(unpack(point))
        while node do
            if node:type() == 'inline_link' or node:type() == 'image' then
                local label, destination
                for child in node:iter_children() do
                    if child:type() == 'link_text' or child:type() == 'image_description' then
                        label = child
                    elseif child:type() == 'link_destination' then
                        destination = child
                    end
                end
                if label and destination then
                    local first_row, first_col, last_row, last_col = label:range()
                    result = {
                        label = { start = { first_row + 1, first_col }, finish = { last_row + 1, last_col } },
                        destination = vim.treesitter.get_node_text(destination, buffer):gsub('^<(.*)>$', '%1'),
                    }
                    return
                end
            end
            node = node:parent()
        end
    end)
    return result
end

function M.visible_position(buffer, position)
    local link = link_at(buffer, position)
    if not link then
        return position
    end
    local first, last = link.label.start, link.label.finish
    if position[1] < first[1] or (position[1] == first[1] and position[2] < first[2]) then
        return first
    end
    if position[1] > last[1] or (position[1] == last[1] and position[2] >= last[2]) then
        local line = vim.api.nvim_buf_get_lines(buffer, last[1] - 1, last[1], false)[1] or ''
        local character = vim.fn.charidx(line, last[2])
        local minimum = first[1] == last[1] and first[2] or 0
        return { last[1], math.max(minimum, vim.fn.byteidx(line, math.max(0, character - 1))) }
    end
    return position
end

local function node_ranges(context)
    if not context or not context:valid() then
        return {}
    end
    local ok, parser = pcall(vim.treesitter.get_parser, context.source)
    if not ok or not parser then
        return {}
    end
    parser:parse(true)
    local result, seen = {}, {}
    local position = context.position
    parser:for_each_tree(function(tree, language_tree)
        if not tree or not language_tree:contains({ position[1] - 1, position[2], position[1] - 1, position[2] }) then
            return
        end
        local node = tree:root():named_descendant_for_range(position[1] - 1, position[2], position[1] - 1, position[2])
        while node do
            local first_row, first_col, last_row, last_col = node:range()
            local key = table.concat({ first_row, first_col, last_row, last_col }, ':')
            if not seen[key] and (first_row ~= last_row or first_col ~= last_col) then
                seen[key] = true
                result[#result + 1] = {
                    start = { first_row + 1, first_col },
                    finish = { last_row + 1, last_col },
                    kind = node:type(),
                }
            end
            node = node:parent()
        end
    end)
    table.sort(result, function(left, right)
        local left_size = vim.api.nvim_buf_get_offset(context.source, left.finish[1] - 1) + left.finish[2]
            - vim.api.nvim_buf_get_offset(context.source, left.start[1] - 1) - left.start[2]
        local right_size = vim.api.nvim_buf_get_offset(context.source, right.finish[1] - 1) + right.finish[2]
            - vim.api.nvim_buf_get_offset(context.source, right.start[1] - 1) - right.start[2]
        return left_size < right_size
    end)
    return result
end

local function valid_position(buffer, position, allow_eof)
    if type(position) ~= 'table' or type(position[1]) ~= 'number'
        or type(position[2]) ~= 'number' then return false end
    local row, column = position[1], position[2]
    local count = vim.api.nvim_buf_line_count(buffer)
    if allow_eof and row == count + 1 and column == 0 then return true end
    if row < 1 or row > count or column < 0
        or row ~= math.floor(row) or column ~= math.floor(column) then return false end
    local line = vim.api.nvim_buf_get_lines(buffer, row - 1, row, false)[1]
    if column > #line then return false end
    local byte = line:byte(column + 1)
    return not byte or byte < 128 or byte >= 192
end

local function valid_range(buffer, range)
    return type(range) == 'table' and valid_position(buffer, range.start)
        and valid_position(buffer, range.finish, true)
        and (range.start[1] < range.finish[1]
            or (range.start[1] == range.finish[1] and range.start[2] < range.finish[2]))
end

function Context:valid()
    local expected = self._operation and not self._operation.done
        and self._operation.target == 'source' and self.source or self.buffer
    return vim.api.nvim_win_is_valid(self.window)
        and vim.api.nvim_buf_is_valid(self.source)
        and vim.api.nvim_win_get_buf(self.window) == expected
        and vim.api.nvim_buf_get_changedtick(self.source) == self.changedtick
        and (not self._valid or self._valid())
end

function Context:to_source(position)
    if not self:valid() then
        return nil, 'stale'
    end
    if not valid_position(self.buffer, position) then return nil, 'unmapped' end
    if self.projected then
        return projection.to_source(self._rows, position)
    end
    return vim.deepcopy(position), 'exact'
end

function Context:to_display(position)
    if not self:valid() then
        return nil, 'stale'
    end
    if not valid_position(self.source, position) then return nil, 'unmapped' end
    if self.projected then
        local visible = M.visible_position(self.source, position)
        local mapped, quality = projection.to_display(self._rows, visible)
        return mapped, vim.deep_equal(visible, position) and quality or 'anchor'
    end
    return vim.deepcopy(position), 'exact'
end

function Context:link(position)
    if not self:valid() then
        return nil, 'stale'
    end
    return link_at(self.source, position or self.position)
end

---Source syntax nodes at the captured cursor, smallest range first.
---@return render.md.interaction.Range[]?, string?
function Context:node_ranges()
    if not self:valid() then
        return nil, 'stale'
    end
    return node_ranges(self)
end

---Convert a half-open endpoint to a native Visual endpoint in either buffer.
---@param finish integer[]
---@param target? 'display'|'source'
---@return integer[]?, string?
function Context:selection_end(finish, target)
    assert(target == nil or target == 'display' or target == 'source', 'Invalid selection target')
    if not self:valid() then
        return nil, 'stale'
    end
    local buffer = target == 'source' and self.source or self.buffer
    if not valid_position(buffer, finish, true) then
        return nil, 'unmapped'
    end
    return M.selection_end(buffer, finish)
end

function Context:is_visible(position)
    return self:valid() and (not self._visible or self._visible(position))
end

function Context:source_range(range)
    if not self:valid() then
        return nil, 'stale'
    end
    if not valid_range(self.buffer, range) then return nil, 'unmapped' end
    if self.projected then
        return projection.source_range(self._rows, range)
    end
    return vim.deepcopy(range), 'exact'
end

function Context:display_ranges(range)
    if not self:valid() then
        return nil, 'stale'
    end
    if not valid_range(self.source, range) then return nil, 'unmapped' end
    if self.projected then
        return projection.display_ranges(self._rows, range)
    end
    return { vim.tbl_extend('force', range, { quality = 'exact' }) }
end

---Select a semantic source range while retaining its original endpoints.
function Context:select_source(range)
    if not self:valid() then
        return false, 'stale'
    end
    if not valid_range(self.source, range) then return false, 'unmapped' end
    local projected = package.loaded['render-markdown.preview']
    if self.projected and vim.api.nvim_win_get_buf(self.window) == self.buffer then
        return projected.select_source(self.window, range)
    end
    return M.select_native(self.window, range)
end

---@param win? integer
---@return render.md.interaction.Context?
function M.context(win)
    local window = (win == nil or win == 0) and vim.api.nvim_get_current_win() or win
    if not vim.api.nvim_win_is_valid(window) then
        return nil
    end
    local projected = package.loaded['render-markdown.preview']
    local context = projected and projected.interaction_context(window)
    if not context then
        local buffer = vim.api.nvim_win_get_buf(window)
        -- A stale/copied projection must not masquerade as a source document.
        if vim.b[buffer].markdown_preview_source then
            return nil
        end
        context = {
            window = window, source = buffer, buffer = buffer, projected = false,
            position = vim.api.nvim_win_get_cursor(window),
            position_quality = 'exact',
            changedtick = vim.api.nvim_buf_get_changedtick(buffer),
        }
    end
    context.mode = vim.api.nvim_get_mode().mode
    context.count = vim.v.count
    context.register = vim.v.register
    context.filename = vim.api.nvim_buf_get_name(context.source)
    context.filetype = vim.bo[context.source].filetype
    return setmetatable(context, Context)
end

---Convert a half-open byte endpoint to a native Visual endpoint.
function M.selection_end(buffer, finish)
    local count = vim.api.nvim_buf_line_count(buffer)
    if finish[1] > count then
        return { count, #vim.api.nvim_buf_get_lines(buffer, count - 1, count, false)[1] }
    end
    if vim.o.selection == 'exclusive' then
        return vim.deepcopy(finish)
    end
    local row, column = finish[1], finish[2]
    if column == 0 and row > 1 then
        row = row - 1
        column = #vim.api.nvim_buf_get_lines(buffer, row - 1, row, false)[1]
        return { row, column }
    end
    local line = vim.api.nvim_buf_get_lines(buffer, row - 1, row, false)[1] or ''
    local character = vim.fn.charidx(line, column)
    return { row, math.max(0, vim.fn.byteidx(line, math.max(0, character - 1))) }
end

function M.select_native(window, range)
    local buffer = vim.api.nvim_win_get_buf(window)
    local last = M.selection_end(buffer, range.finish)
    vim.api.nvim_win_call(window, function()
        if vim.fn.mode() ~= 'n' then
            vim.cmd.normal({ vim.keycode('<Esc>'), bang = true })
        end
        vim.api.nvim_win_set_cursor(window, range.start)
        vim.cmd.normal({ 'v', bang = true })
        vim.fn.setpos('.', { 0, last[1], last[2] + 1, 0 })
    end)
    return true
end

---Route an operation. Async adapters retain the token and call finish/cancel.
---A timeout is mandatory in practice: the default bounds a forgotten callback.
---@param operation render.md.interaction.Operation
---@param opts? {window?: integer}
function M.dispatch(operation, opts)
    assert(type(operation.run) == 'function', 'An interaction requires a run callback')
    assert(not operation.timeout or (operation.timeout > 0 and operation.timeout < 2147483648), 'Invalid interaction timeout')
    local context = M.context(opts and opts.window)
    if not context or not context:valid() then
        return nil, 'stale'
    end
    local window = context.window
    if active[window] then
        return nil, 'busy'
    end
    local target = operation.target or 'source'
    assert(target == 'source' or target == 'display', 'Invalid interaction target')
    if operation.exact and context.position_quality ~= 'exact' then
        return nil, 'anchor'
    end
    local projected = package.loaded['render-markdown.preview']
    local lease = context.projected and projected.begin_interaction(window, target, context.position) or nil
    if context.projected and not lease then
        return nil, 'busy'
    end
    local token = { context = context, target = target,
        cursor = vim.api.nvim_win_get_cursor(window) }
    ---@cast token render.md.interaction.Token
    context._operation = token
    active[window] = token
    local function complete(cancelled)
        if token.done then
            return false
        end
        token.done = true
        active[window] = nil
        if token.group then
            pcall(vim.api.nvim_del_augroup_by_id, token.group)
        end
        if token.timer then
            token.timer:stop()
            token.timer:close()
        end
        if lease then
            projected.end_interaction(lease, cancelled)
        end
        return true
    end
    function token:valid()
        return not self.done and vim.api.nvim_win_is_valid(window)
            and vim.api.nvim_buf_is_valid(context.source)
            and vim.api.nvim_win_get_buf(window) == (target == 'source' and context.source or context.buffer)
            and vim.api.nvim_buf_get_changedtick(context.source) == context.changedtick
            and (not lease or projected.interaction_valid(lease))
            and (not operation.async or operation.track_cursor == false
                or vim.deep_equal(vim.api.nvim_win_get_cursor(window), self.cursor))
    end
    function token:finish() return complete(false) end
    function token:cancel(keep_cursor)
        if self.done or self.cancelling then
            return false
        end
        self.cancelling = true
        local ok, err = true, nil
        if operation.cancel then
            ok, err = xpcall(operation.cancel, debug.traceback)
        end
        if lease then
            lease.keep_cursor = keep_cursor
        end
        complete(true)
        self.cancelling = false
        if not ok then
            error(err, 0)
        end
        return true
    end
    if lease then
        lease.cancel = function() token:cancel() end
    end
    if operation.async then
        token.group = vim.api.nvim_create_augroup('markdown_interaction_' .. window, { clear = true })
        vim.api.nvim_create_autocmd({ 'WinClosed', 'BufWipeout', 'BufEnter', 'CursorMoved', 'TextChanged', 'TextChangedI' }, {
            group = token.group,
            callback = function(event)
                if (event.event == 'WinClosed' and tonumber(event.match) == window)
                    or (event.event == 'BufWipeout' and (event.buf == context.source or event.buf == context.buffer))
                    or not token:valid() then token:cancel(true) end
            end,
        })
        token.timer = assert(vim.uv.new_timer())
        token.timer:start(operation.timeout or 10000, 0, vim.schedule_wrap(function() token:cancel() end))
    end
    local results
    local ok, err = xpcall(function()
        vim.api.nvim_win_call(window, function() results = pack(operation.run(context, token)) end)
    end, debug.traceback)
    if not ok then
        local cleanup_ok, cleanup_error = pcall(function() token:cancel() end)
        if not cleanup_ok then
            err = err .. '\nInteraction cleanup: ' .. tostring(cleanup_error)
        end
        error(err, 0)
    end
    if not operation.async then
        token:finish()
    end
    return token, unpack(results, 1, results.n)
end

---Build a user-owned callback; resolve its context only when invoked.
---@param operation render.md.interaction.Operation
---@param opts? {window?: integer}
---@return function
function M.wrap(operation, opts)
    assert(type(operation.run) == 'function', 'An interaction requires a run callback')
    local template = vim.tbl_extend('force', {}, operation)
    local options = opts and vim.tbl_extend('force', {}, opts) or nil
    return function(...)
        local arguments = pack(...)
        local invocation = vim.tbl_extend('force', {}, template, {
            run = function(context, token)
                return template.run(context, token, unpack(arguments, 1, arguments.n))
            end,
        })
        return M.dispatch(invocation, options)
    end
end

---Select natively in source; projected source selection is an explicit opt-in.
function M.select_node(index, opts)
    return M.dispatch({
        target = opts and opts.preview == true and 'display' or 'source',
        run = function(context)
            local range = (context:node_ranges() or {})[index or 1]
            return range and context:select_source(range) or false
        end,
    }, opts)
end

return M
