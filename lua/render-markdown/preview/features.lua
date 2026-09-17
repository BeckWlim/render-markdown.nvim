-- Shared contract: features replace source ranges with real display rows. Each
-- row carries semantic chunks and a source row; optional byte spans map cells.
---@alias MarkdownPreviewChunk { [1]: string, [2]: string? }
---@class MarkdownSourceSpan
---@field first integer First preview byte (inclusive).
---@field last integer Last preview byte (exclusive).
---@field source_column integer Original source byte column.
---@class MarkdownPreviewRow
---@field chunks MarkdownPreviewChunk[]
---@field source_row integer Zero-based source row.
---@field source_column? integer
---@field spans? MarkdownSourceSpan[]
---@field identity? boolean Unchanged source line.
local M = {}
local refresh_callbacks = {}
local pending_refreshes = {}

-- Cache visual work by object content and layout, independently of its location.
-- Moving an object only remaps its source rows; chunks and byte spans are shared.
function M.block_key(source, layout)
    return vim.fn.sha256(source .. '\0' .. vim.json.encode(layout))
end

-- Build the current element map and plan only missing work. Positions belong
-- to the current element; completed and in-flight work is identified by key.
function M.plan_elements(elements, cached, running, limit)
    local by_key, render = {}, {}
    local count = 0
    for _, element in ipairs(elements) do
        if not by_key[element.key] and count < limit then
            by_key[element.key] = element
            count = count + 1
            if not cached[element.key] and not running[element.key] then
                render[#render + 1] = element
            end
        end
    end
    return { by_key = by_key, render = render }
end

function M.cached_projection(cache, key, start_row, render)
    local block = cache[key]
    if not block then
        block = render()
        if not block then
            return
        end
        cache[key] = block
    end
    local offset = start_row - block.start_row
    if offset == 0 then
        return block
    end
    local rows = {}
    for index, row in ipairs(block.rows) do
        rows[index] = vim.tbl_extend(
            'force',
            row,
            { source_row = row.source_row + offset }
        )
    end
    return vim.tbl_extend(
        'force',
        block,
        { start_row = start_row, end_row = block.end_row + offset, rows = rows }
    )
end

-- Only visible content/styling participates in buffer patches. Source maps are
-- replaced separately, so an insertion above an object does not repaint it.
function M.changed_ranges(previous_rows, next_rows)
    local function signatures(rows)
        local lines = {}
        for index, row in ipairs(rows) do
            lines[index] = vim.json.encode({ row.chunks, row.identity == true })
        end
        return #lines > 0 and table.concat(lines, '\n') .. '\n' or ''
    end
    local ranges = {}
    vim.text.diff(signatures(previous_rows), signatures(next_rows), {
        algorithm = 'histogram',
        on_hunk = function(old_start, old_count, new_start, new_count)
            ranges[#ranges + 1] = {
                old_start = old_count == 0 and old_start or old_start - 1,
                old_count = old_count,
                new_start = new_count == 0 and new_start or new_start - 1,
                new_count = new_count,
            }
        end,
    })
    return ranges
end

function M.chunks_width(chunks)
    local width = 0
    for _, chunk in ipairs(chunks) do
        width = width + vim.fn.strdisplaywidth(chunk[1])
    end
    return width
end

function M.subscribe(buffer, callback)
    refresh_callbacks[buffer] = callback
end

function M.request_render(buffer, event)
    if pending_refreshes[buffer] then
        return
    end
    local callback = refresh_callbacks[buffer]
    if not callback then
        return
    end
    local request = {}
    pending_refreshes[buffer] = request
    vim.schedule(function()
        if pending_refreshes[buffer] ~= request then
            return
        end
        pending_refreshes[buffer] = nil
        if
            refresh_callbacks[buffer] == callback
            and vim.api.nvim_buf_is_valid(buffer)
        then
            callback(event)
        end
    end)
end

function M.forget_buffer(buffer)
    refresh_callbacks[buffer] = nil
    pending_refreshes[buffer] = nil
end

function M.project(features, context)
    local replacements = {}
    local tasks = {}
    for _, feature in ipairs(features) do
        local blocks, render_tasks = (feature.layout or feature.project)(
            context
        )
        vim.list_extend(replacements, blocks)
        vim.list_extend(tasks, render_tasks or {})
    end
    table.sort(replacements, function(left, right)
        return left.start_row < right.start_row
    end)
    local source_lines = vim.api.nvim_buf_get_lines(context.buf, 0, -1, false)
    local rows = {}
    local next_source_row = 0
    local function copy_until(last_row)
        while next_source_row < last_row do
            rows[#rows + 1] = {
                chunks = { { source_lines[next_source_row + 1] } },
                source_row = next_source_row,
                identity = true,
            }
            next_source_row = next_source_row + 1
        end
    end
    for _, replacement in ipairs(replacements) do
        assert(
            replacement.start_row >= next_source_row
                and replacement.end_row > replacement.start_row
                and replacement.end_row <= #source_lines,
            'Markdown feature ranges overlap or exceed the source'
        )
        copy_until(replacement.start_row)
        vim.list_extend(rows, replacement.rows)
        next_source_row = replacement.end_row
    end
    copy_until(#source_lines)
    return rows, tasks
end

-- The owning preview calls this after committing the measured frame. Keeping
-- dispatch separate prevents process completions from racing initial layout.
function M.dispatch(tasks, valid)
    if not tasks or #tasks == 0 then
        return
    end
    vim.schedule(function()
        if not valid() then
            return
        end
        for _, task in ipairs(tasks) do
            task()
        end
    end)
end

---@param row MarkdownPreviewRow
---@param column integer
---@return integer[]
function M.source_position(row, column)
    if row.identity then
        return { row.source_row + 1, column }
    end
    local source_column = row.source_column or 0
    for _, span in ipairs(row.spans or {}) do
        if column < span.first then
            break
        end
        source_column = span.source_column
        if column < span.last then
            break
        end
    end
    return { row.source_row + 1, source_column }
end

---@param rows MarkdownPreviewRow[]
---@param source_row integer
---@param source_column integer
---@return integer[]
function M.preview_position(rows, source_row, source_column)
    local best_row = 1
    local best_column = 0
    local best_distance = math.huge
    local best_source_column = -1
    for index, row in ipairs(rows) do
        local distance = math.abs(row.source_row - source_row)
        if distance < best_distance then
            best_row, best_column, best_distance =
                index, row.identity and source_column or 0, distance
            best_source_column = -1
        end
        if distance == 0 and row.spans then
            for _, span in ipairs(row.spans) do
                if
                    span.source_column <= source_column
                    and span.source_column > best_source_column
                then
                    best_row, best_column = index, span.first
                    best_source_column = span.source_column
                end
            end
        end
    end
    return { best_row, best_column }
end

return M
