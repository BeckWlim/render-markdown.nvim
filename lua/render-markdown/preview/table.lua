local M = {}
local markdown_features = require('render-markdown.preview.features')

M.cell_margins = { left = 1, right = 2 }
M.table_layout = {
    full_width_threshold = 80,
    outer_right_ratio = 0.2,
}

local table_query_cache
local table_query_resolved = false

local table_highlights = {
    cell = 'RenderMarkdownTableCell',
    code = 'RenderMarkdownTableCode',
    header = 'RenderMarkdownTableHeader',
    icon = 'RenderMarkdownTableIcon',
    label = 'RenderMarkdownTableLabel',
    row_rule = 'RenderMarkdownTableRowRule',
    rule = 'RenderMarkdownTableRule',
}

local function table_query()
    if table_query_resolved then
        return table_query_cache
    end
    table_query_resolved = true
    pcall(function()
        table_query_cache =
            vim.treesitter.query.parse('markdown', '(pipe_table) @table')
    end)
    return table_query_cache
end

local function display_width(text)
    return vim.fn.strdisplaywidth(text)
end

local function cell_display_text(raw_text)
    local normalized_text = raw_text:gsub('\r', '')
    local image_labels_removed =
        normalized_text:gsub('!%[([^%]]-)%]%([^%)]-%)', '%1')
    local link_destinations_removed =
        image_labels_removed:gsub('%[([^%]]-)%]%([^%)]-%)', '%1')
    local code_ticks_removed = link_destinations_removed:gsub('`([^`]-)`', '%1')
    local unescaped_pipes = code_ticks_removed:gsub('\\|', '|')
    return vim.trim(unescaped_pipes)
end

local function append_display_characters(target, text, is_code, source_start)
    local next_byte = 1
    while next_byte <= #text do
        local escaped_pipe = text:sub(next_byte, next_byte + 1) == '\\|'
        local character_text = escaped_pipe and '|'
            or vim.fn.strcharpart(text:sub(next_byte), 0, 1)
        local source_width = escaped_pipe and 2 or #character_text
        target[#target + 1] = {
            is_code = is_code,
            source_end = source_start + next_byte - 1 + source_width,
            source_start = source_start + next_byte - 1,
            text = character_text,
        }
        next_byte = next_byte + source_width
    end
end

local function display_markup(raw_text, next_byte)
    local prefix = raw_text:sub(next_byte, next_byte)
    local pattern
    local is_code = false
    if prefix == '!' and raw_text:sub(next_byte + 1, next_byte + 1) == '[' then
        pattern = '!%[()([^%]]-)%]%([^%)]-%)'
    elseif prefix == '[' then
        pattern = '%[()([^%]]-)%]%([^%)]-%)'
    elseif prefix == '`' then
        pattern = '`()([^`]*)`'
        is_code = true
    else
        return nil
    end
    local markup_start, markup_end, content_start, content =
        raw_text:find(pattern, next_byte)
    if markup_start ~= next_byte then
        return nil
    end
    return markup_end, content_start - 1, content, is_code
end

local function cell_display_characters(raw_text)
    local source_characters = {}
    local next_byte = 1
    while next_byte <= #raw_text do
        local markup_end, content_start, content, is_code =
            display_markup(raw_text, next_byte)
        if markup_end then
            append_display_characters(
                source_characters,
                content,
                is_code,
                content_start
            )
            next_byte = markup_end + 1
        elseif raw_text:sub(next_byte, next_byte + 1) == '\\|' then
            source_characters[#source_characters + 1] = {
                is_code = false,
                source_end = next_byte + 1,
                source_start = next_byte - 1,
                text = '|',
            }
            next_byte = next_byte + 2
        else
            local character_text =
                vim.fn.strcharpart(raw_text:sub(next_byte), 0, 1)
            if character_text ~= '\r' then
                append_display_characters(
                    source_characters,
                    character_text,
                    false,
                    next_byte - 1
                )
            end
            next_byte = next_byte + #character_text
        end
    end

    local display_characters = {}
    local pending_space
    for _, source_character in ipairs(source_characters) do
        if source_character.text:match('%s') then
            if pending_space then
                pending_space.source_end = source_character.source_end
            else
                pending_space = vim.tbl_extend(
                    'force',
                    {},
                    source_character,
                    { text = ' ' }
                )
            end
        else
            if pending_space and #display_characters > 0 then
                display_characters[#display_characters + 1] = pending_space
            end
            display_characters[#display_characters + 1] = source_character
            pending_space = nil
        end
    end
    return display_characters
end

local function characters_width(characters)
    local width = 0
    for _, character in ipairs(characters) do
        width = width + display_width(character.text)
    end
    return width
end

local function character_words(characters)
    local words = {}
    local current_word = {}
    for _, character in ipairs(characters) do
        if character.text == ' ' then
            if #current_word > 0 then
                words[#words + 1] = current_word
                current_word = {}
            end
        else
            current_word[#current_word + 1] = character
        end
    end
    if #current_word > 0 then
        words[#words + 1] = current_word
    end
    return words
end

local function split_character_prefix(characters, maximum_width)
    local prefix = {}
    local suffix = {}
    local prefix_width = 0
    for character_index, character in ipairs(characters) do
        local character_width = display_width(character.text)
        if prefix_width + character_width <= maximum_width or #prefix == 0 then
            prefix[#prefix + 1] = character
            prefix_width = prefix_width + character_width
        else
            for suffix_index = character_index, #characters do
                suffix[#suffix + 1] = characters[suffix_index]
            end
            break
        end
    end
    return prefix, suffix
end

local function wrap_cell_characters(text, width)
    local cell_width = math.max(width, 1)
    local display_characters = cell_display_characters(text)
    if #display_characters == 0 then
        return { {} }
    end

    local wrapped_lines = {}
    local current_line = {}
    for _, source_word in ipairs(character_words(display_characters)) do
        local remaining_word = source_word
        local separator_width = #current_line > 0 and 1 or 0
        local candidate_width = characters_width(current_line)
            + separator_width
            + characters_width(remaining_word)
        if candidate_width <= cell_width then
            if separator_width > 0 then
                local preceding_character = current_line[#current_line]
                local following_character = remaining_word[1]
                current_line[#current_line + 1] = {
                    is_code = preceding_character.is_code
                        and following_character.is_code,
                    source_end = following_character.source_start,
                    source_start = preceding_character.source_end,
                    text = ' ',
                }
            end
            vim.list_extend(current_line, remaining_word)
        else
            if #current_line > 0 then
                wrapped_lines[#wrapped_lines + 1] = current_line
                current_line = {}
            end
            while characters_width(remaining_word) > cell_width do
                local word_prefix, word_suffix =
                    split_character_prefix(remaining_word, cell_width)
                wrapped_lines[#wrapped_lines + 1] = word_prefix
                remaining_word = word_suffix
            end
            current_line = remaining_word
        end
    end
    if #current_line > 0 then
        wrapped_lines[#wrapped_lines + 1] = current_line
    end
    return wrapped_lines
end

local function characters_text(characters)
    local text_parts = {}
    for _, character in ipairs(characters) do
        text_parts[#text_parts + 1] = character.text
    end
    return table.concat(text_parts)
end

local function characters_chunks(characters, base_highlight)
    local chunks = {}
    for _, character in ipairs(characters) do
        local character_highlight = character.is_code and table_highlights.code
            or base_highlight
        local previous_chunk = chunks[#chunks]
        if previous_chunk and previous_chunk[2] == character_highlight then
            previous_chunk[1] = previous_chunk[1] .. character.text
        else
            chunks[#chunks + 1] = { character.text, character_highlight }
        end
    end
    return chunks
end

---@param text string
---@param width integer
---@return string[]
function M.wrap_cell(text, width)
    return vim.tbl_map(characters_text, wrap_cell_characters(text, width))
end

---@param text string
---@param width integer
---@param base_highlight string
---@return [string, string][][]
function M.wrap_cell_chunks(text, width, base_highlight)
    return vim.tbl_map(function(characters)
        return characters_chunks(characters, base_highlight)
    end, wrap_cell_characters(text, width))
end

local function cursor_location(wrapped_lines, source_offset)
    local fragment = 1
    local character_index = 1
    for line_index, characters in ipairs(wrapped_lines) do
        for index, character in ipairs(characters) do
            if
                character.source_start
                and source_offset >= character.source_start
            then
                fragment = line_index
                character_index = index
            end
        end
    end
    return fragment, character_index
end

local function cursor_fragment(wrapped_lines, source_offset)
    local fragment = cursor_location(wrapped_lines, source_offset)
    return fragment
end

---@param text string
---@param source_offset integer
---@param width integer
---@return integer
function M.cell_fragment(text, source_offset, width)
    return cursor_fragment(
        wrap_cell_characters(text, width),
        math.max(math.min(source_offset, #text), 0)
    )
end

---@param available_width integer
---@param column_count integer
---@param preferred_widths? integer[]
---@return integer[], integer
function M.allocate_widths(available_width, column_count, preferred_widths)
    if column_count <= 0 then
        return {}, 0
    end
    local preferred_gap_width = 2
    local minimum_cell_width = 1
    local preferred_minimum = column_count * minimum_cell_width
        + (column_count - 1) * preferred_gap_width
    local gap_width = available_width >= preferred_minimum
            and preferred_gap_width
        or 1
    local content_width =
        math.max(available_width - (column_count - 1) * gap_width, column_count)
    local requested_widths = {}
    local requested_total = 0
    for column_index = 1, column_count do
        local preferred_width = preferred_widths
                and preferred_widths[column_index]
            or content_width
        local requested_width = math.max(preferred_width, minimum_cell_width)
        requested_widths[column_index] = requested_width
        requested_total = requested_total + requested_width
    end
    if requested_total <= content_width then
        return requested_widths, gap_width
    end

    local column_widths = {}
    local pending_columns = {}
    for column_index = 1, column_count do
        pending_columns[#pending_columns + 1] = column_index
    end
    local remaining_width = content_width
    while #pending_columns > 0 do
        local fair_width = math.floor(remaining_width / #pending_columns)
        local oversized_columns = {}
        for _, column_index in ipairs(pending_columns) do
            if requested_widths[column_index] <= fair_width then
                column_widths[column_index] = requested_widths[column_index]
                remaining_width = remaining_width
                    - requested_widths[column_index]
            else
                oversized_columns[#oversized_columns + 1] = column_index
            end
        end
        if #oversized_columns == #pending_columns then
            local base_width = math.floor(remaining_width / #oversized_columns)
            local extra_columns = remaining_width % #oversized_columns
            for pending_index, column_index in ipairs(oversized_columns) do
                column_widths[column_index] = base_width
                    + (pending_index <= extra_columns and 1 or 0)
            end
            break
        end
        pending_columns = oversized_columns
    end
    return column_widths, gap_width
end

---@param available_width integer
---@return integer
function M.table_width_limit(available_width)
    local usable_ratio = 1 - M.table_layout.outer_right_ratio
    local proportional_width = math.floor(available_width * usable_ratio)
    local responsive_width =
        math.max(proportional_width, M.table_layout.full_width_threshold)
    return math.max(math.min(available_width, responsive_width), 1)
end

local function node_children(node, child_type)
    local matching_children = {}
    for child in node:iter_children() do
        if child:type() == child_type then
            matching_children[#matching_children + 1] = child
        end
    end
    return matching_children
end

local function row_cells(buffer, row_node)
    local cell_nodes = node_children(row_node, 'pipe_table_cell')
    local cell_texts = {}
    local cell_ranges = {}
    for _, cell_node in ipairs(cell_nodes) do
        cell_texts[#cell_texts + 1] =
            vim.treesitter.get_node_text(cell_node, buffer)
        local _, start_column, _, end_column = cell_node:range()
        cell_ranges[#cell_ranges + 1] = {
            end_column = end_column,
            start_column = start_column,
        }
    end
    return cell_texts, cell_ranges
end

local function delimiter_alignment(buffer, delimiter_node)
    local delimiter_cells =
        node_children(delimiter_node, 'pipe_table_delimiter_cell')
    local alignments = {}
    for _, cell_node in ipairs(delimiter_cells) do
        local delimiter_text =
            vim.trim(vim.treesitter.get_node_text(cell_node, buffer))
        local has_left_marker = delimiter_text:sub(1, 1) == ':'
        local has_right_marker = delimiter_text:sub(-1) == ':'
        if has_left_marker and has_right_marker then
            alignments[#alignments + 1] = 'center'
        elseif has_right_marker then
            alignments[#alignments + 1] = 'right'
        else
            alignments[#alignments + 1] = 'left'
        end
    end
    return alignments
end

local function parse_table(buffer, table_node)
    local table_start_row, table_start_column, table_end_row, table_end_column =
        table_node:range()
    local table_end_exclusive = table_end_column > 0 and table_end_row + 1
        or table_end_row
    local header_node
    local delimiter_node
    local data_nodes = {}
    for child_node in table_node:iter_children() do
        local child_type = child_node:type()
        if child_type == 'pipe_table_header' then
            header_node = child_node
        elseif child_type == 'pipe_table_delimiter_row' then
            delimiter_node = child_node
        elseif child_type == 'pipe_table_row' then
            data_nodes[#data_nodes + 1] = child_node
        end
    end
    if not header_node or not delimiter_node then
        return nil
    end
    local header_cells, header_cell_ranges = row_cells(buffer, header_node)
    if #header_cells == 0 then
        return nil
    end
    local header_row = select(1, header_node:range())
    local rows = {
        {
            cell_ranges = header_cell_ranges,
            cells = header_cells,
            role = 'header',
            source_row = header_row,
        },
    }
    for _, data_node in ipairs(data_nodes) do
        local data_cells, data_cell_ranges = row_cells(buffer, data_node)
        if #data_cells == #header_cells then
            rows[#rows + 1] = {
                cell_ranges = data_cell_ranges,
                cells = data_cells,
                role = 'cell',
                source_row = select(1, data_node:range()),
            }
        end
    end
    return {
        alignments = delimiter_alignment(buffer, delimiter_node),
        column_count = #header_cells,
        delimiter_row = select(1, delimiter_node:range()),
        end_row = table_end_exclusive,
        rows = rows,
        start_column = table_start_column,
        start_row = table_start_row,
    }
end

local function padded_chunks(chunks, width, alignment, base_highlight)
    local remaining_width =
        math.max(width - markdown_features.chunks_width(chunks), 0)
    local left_padding = 0
    if alignment == 'right' then
        left_padding = remaining_width
    elseif alignment == 'center' then
        left_padding = math.floor(remaining_width / 2)
    end
    local right_padding = remaining_width - left_padding
    local padded = { { string.rep(' ', left_padding), base_highlight } }
    vim.list_extend(padded, chunks)
    padded[#padded + 1] = { string.rep(' ', right_padding), base_highlight }
    return padded, left_padding
end

local function preferred_column_widths(rows, column_count)
    local widths = {}
    for column = 1, column_count do
        widths[column] = 1
        for _, row in ipairs(rows) do
            widths[column] = math.max(
                widths[column],
                display_width(cell_display_text(row.cells[column]))
            )
        end
    end
    return widths
end

local function render_table(parsed_table, width)
    local indentation = string.rep(' ', parsed_table.start_column)
    local limit =
        M.table_width_limit(math.max(width - parsed_table.start_column, 1))
    local content_width =
        math.max(limit - M.cell_margins.left - M.cell_margins.right, 1)
    local widths, gap = M.allocate_widths(
        content_width,
        parsed_table.column_count,
        preferred_column_widths(parsed_table.rows, parsed_table.column_count)
    )
    local total_width = M.cell_margins.left
        + M.cell_margins.right
        + (#widths - 1) * gap
    for _, column_width in ipairs(widths) do
        total_width = total_width + column_width
    end
    local rows = {}
    local function decoration(text, highlight, source_row)
        rows[#rows + 1] = {
            chunks = { { indentation .. text, highlight } },
            source_row = source_row,
        }
    end
    local title_chunks = {
        { indentation .. '󰈙 ', table_highlights.icon },
        { 'table', table_highlights.label },
    }
    local title_padding = parsed_table.start_column
        + total_width
        - markdown_features.chunks_width(title_chunks)
    if title_padding > 0 then
        title_chunks[#title_chunks + 1] =
            { string.rep(' ', title_padding), table_highlights.label }
    end
    rows[#rows + 1] = {
        chunks = title_chunks,
        source_row = parsed_table.start_row,
    }
    for row_index, row in ipairs(parsed_table.rows) do
        local cells = {}
        local height = 1
        for column, cell in ipairs(row.cells) do
            cells[column] = wrap_cell_characters(cell, widths[column])
            height = math.max(height, #cells[column])
        end
        for fragment = 1, height do
            local chunks = {
                {
                    indentation .. string.rep(' ', M.cell_margins.left),
                    table_highlights[row.role],
                },
            }
            local spans = {}
            local output_byte = #chunks[1][1]
            for column, cell_lines in ipairs(cells) do
                local characters = cell_lines[fragment] or {}
                local alignment = row_index == 1 and 'center'
                    or parsed_table.alignments[column]
                local padded, left_padding = padded_chunks(
                    characters_chunks(characters, table_highlights[row.role]),
                    widths[column],
                    alignment,
                    table_highlights[row.role]
                )
                local character_byte = output_byte + left_padding
                for _, character in ipairs(characters) do
                    spans[#spans + 1] = {
                        first = character_byte,
                        last = character_byte + #character.text,
                        source_column = row.cell_ranges[column].start_column
                            + (character.source_start or 0),
                    }
                    character_byte = character_byte + #character.text
                end
                for _, chunk in ipairs(padded) do
                    chunks[#chunks + 1] = chunk
                    output_byte = output_byte + #chunk[1]
                end
                if column < #widths then
                    chunks[#chunks + 1] =
                        { string.rep(' ', gap), table_highlights[row.role] }
                    output_byte = output_byte + gap
                end
            end
            chunks[#chunks + 1] = {
                string.rep(' ', M.cell_margins.right),
                table_highlights[row.role],
            }
            rows[#rows + 1] =
                { chunks = chunks, source_row = row.source_row, spans = spans }
        end
        if row_index == 1 then
            decoration(
                string.rep('─', total_width),
                table_highlights.rule,
                parsed_table.delimiter_row
            )
        elseif row_index < #parsed_table.rows then
            decoration(
                string.rep('┈', total_width),
                table_highlights.row_rule,
                row.source_row
            )
        end
    end
    decoration(
        string.rep('─', total_width),
        table_highlights.rule,
        parsed_table.end_row - 1
    )
    return {
        start_row = parsed_table.start_row,
        end_row = parsed_table.end_row,
        rows = rows,
        layout = {
            width = parsed_table.start_column + total_width,
            height = #rows,
            estimated = false,
        },
    }
end

M.name = 'table'

function M.project(context)
    local changedtick = vim.api.nvim_buf_get_changedtick(context.buf)
    local layout = {
        context.width,
        M.table_width_limit(context.width),
        M.cell_margins.left,
        M.cell_margins.right,
    }
    local cached = context.cache and context.cache.tables
    if
        cached
        and cached.changedtick == changedtick
        and vim.deep_equal(cached.layout, layout)
    then
        return cached.blocks
    end
    local query = table_query()
    if not query then
        return {}
    end
    local blocks = {}
    local objects = cached and cached.objects or {}
    local retained = {}
    for _, node in query:iter_captures(context.root, context.buf, 0, -1) do
        if not node:has_error() then
            local start_row, start_column = node:range()
            local key = markdown_features.block_key(
                vim.treesitter.get_node_text(node, context.buf),
                { layout, start_column }
            )
            local block = markdown_features.cached_projection(
                objects,
                key,
                start_row,
                function()
                    local parsed_table = parse_table(context.buf, node)
                    return parsed_table
                            and render_table(parsed_table, context.width)
                        or nil
                end
            )
            if block then
                blocks[#blocks + 1] = block
                retained[key] = objects[key]
            end
        end
    end
    if context.cache then
        context.cache.tables = {
            changedtick = changedtick,
            layout = layout,
            blocks = blocks,
            objects = retained,
        }
    end
    return blocks
end

-- Tables measure and render synchronously from the same cached cell layout.
M.layout = M.project

return M
