-- Projection owns provider configuration, frame composition, caching, refresh
-- requests, deferred work, and the resulting source/display coordinate map.
---@alias MarkdownPreviewChunk { [1]: string, [2]: (string|string[])? }
---@class MarkdownSourceSpan
---@field first integer First preview byte (inclusive).
---@field last integer Last preview byte (exclusive).
---@field source_column integer Original source byte column.
---@field source_end? integer Original source byte end (exclusive).
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

function M.compose(features, context)
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
    local position = M.to_source({ row }, { 1, column })
    return assert(position)
end

---@param rows MarkdownPreviewRow[]
---@param source_row integer
---@param source_column integer
---@return integer[]
function M.preview_position(rows, source_row, source_column)
    local position = M.to_display(rows, { source_row + 1, source_column })
    return position
end

-- All public coordinates are one-based rows and zero-based byte columns.
-- Ranges are half-open. Generated decoration is an anchor, never exact text.

local function before(left, right)
    return left[1] < right[1]
        or (left[1] == right[1] and left[2] < right[2])
end

local function width(row)
    local result = 0
    for _, chunk in ipairs(row.chunks) do
        result = result + #chunk[1]
    end
    return result
end

local function source_end(span)
    return span.source_end or span.source_column + span.last - span.first
end

function M.to_source(rows, position)
    local row = rows[position[1]]
    if not row then
        return nil, 'unmapped'
    end
    local column = math.max(0, math.min(position[2], width(row)))
    if row.identity then
        return { row.source_row + 1, column }, 'exact'
    end
    local anchor = row.source_column or 0
    for _, span in ipairs(row.spans or {}) do
        if column < span.first then
            break
        end
        anchor = span.source_column
        if column < span.last then
            local exact = span.source_end ~= nil and source_end(span) - span.source_column
                == span.last - span.first
            return {
                row.source_row + 1,
                span.source_column + (exact and column - span.first or 0),
            }, exact and 'exact' or 'anchor'
        end
    end
    return { row.source_row + 1, anchor }, 'anchor'
end

function M.to_display(rows, position)
    local best = { 1, 0 }
    local distance = math.huge
    local best_column = -1
    for index, row in ipairs(rows) do
        local delta = math.abs(row.source_row + 1 - position[1])
        if delta < distance then
            best, distance, best_column = { index, 0 }, delta, -1
        end
        if delta == 0 then
            if row.identity then
                return { index, math.min(position[2], width(row)) }, 'exact'
            end
            for _, span in ipairs(row.spans or {}) do
                if position[2] >= span.source_column then
                    if span.source_end and position[2] < source_end(span) then
                        local exact = span.source_end ~= nil and source_end(span) - span.source_column
                            == span.last - span.first
                        return {
                            index,
                            span.first
                                + (exact and position[2] - span.source_column or 0),
                        }, exact and 'exact' or 'anchor'
                    end
                    if span.source_column > best_column then
                        best, best_column = { index, span.first }, span.source_column
                    end
                end
            end
        end
    end
    return best, 'anchor'
end

---Return every displayed fragment of a source range, including wrapped cells.
---The fragments are ordered in display order, not source byte order.
function M.display_ranges(rows, range)
    local result = {}
    for index, row in ipairs(rows) do
        local source_row = row.source_row + 1
        local first = source_row == range.start[1] and range.start[2] or 0
        local last = source_row == range.finish[1] and range.finish[2] or math.huge
        if source_row >= range.start[1] and source_row <= range.finish[1]
            and first < last then
            if row.identity then
                local limit = width(row)
                result[#result + 1] = {
                    start = { index, math.min(first, limit) },
                    finish = { index, math.min(last, limit) },
                    quality = 'exact',
                }
            elseif row.spans then
                for _, span in ipairs(row.spans) do
                    local span_end = source_end(span)
                    if span.source_column < last and span_end > first then
                        local exact = span.source_end ~= nil and span_end - span.source_column == span.last - span.first
                        local start_col = span.first
                            + (exact and math.max(0, first - span.source_column) or 0)
                        local end_col = span.last
                            - (exact and math.max(0, span_end - last) or 0)
                        local previous = result[#result]
                        if previous and previous.finish[1] == index
                            and previous.finish[2] == start_col
                            and previous.quality == (exact and 'exact' or 'anchor') then
                            previous.finish[2] = end_col
                        else
                            result[#result + 1] = {
                                start = { index, start_col },
                                finish = { index, end_col },
                                quality = exact and 'exact' or 'anchor',
                            }
                        end
                    end
                end
            else
                result[#result + 1] = {
                    start = { index, 0 }, finish = { index, width(row) },
                    quality = 'anchor',
                }
            end
        end
    end
    return result
end

function M.source_range(rows, range)
    local first, first_quality = M.to_source(rows, range.start)
    local last, last_quality = M.to_source(rows, range.finish)
    if range.finish[1] == #rows + 1 and range.finish[2] == 0 and #rows > 0 then
        local final_row = rows[#rows]
        last = { final_row.source_row + 2, 0 }
        last_quality = final_row.identity and 'exact' or 'anchor'
    end
    if not first or not last or before(last, first) then
        return nil, 'unmapped'
    end
    -- Exact endpoints do not prove that the intervening generated cells form
    -- a contiguous source range. Require identity rows for arbitrary edits.
    local exact = first_quality == 'exact' and last_quality == 'exact'
    for index = range.start[1], math.min(#rows, range.finish[1]) do
        local row = rows[index]
        exact = exact and row.identity == true
            and row.source_row == first[1] - 1 + index - range.start[1]
    end
    return { start = first, finish = last }, exact and 'exact' or 'anchor'
end

-- Load providers only after this module is initialized. Each provider consumes
-- projection helpers, while selection and lifetime remain owned here.
local all_providers
local configured_providers
local function providers()
    if not all_providers then
        all_providers = {
            require('render-markdown.preview.table'),
            require('render-markdown.preview.mermaid'),
        }
    end
    return all_providers
end

function M.setup(options)
    local all = providers()
    configured_providers = { all[1] }
    if options.mermaid.enabled then
        configured_providers[#configured_providers + 1] = all[2]
    end
    for key, value in pairs(options.mermaid) do
        if key ~= 'enabled' then
            all[2][key] = value
        end
    end
end

function M.project(context)
    return M.compose(configured_providers or providers(), context)
end

function M.detach(buffer, view)
    if not view then
        M.forget_buffer(buffer)
    end
    for _, provider in ipairs(providers()) do
        if provider.detach then
            provider.detach(buffer, view)
        end
    end
end

return M
