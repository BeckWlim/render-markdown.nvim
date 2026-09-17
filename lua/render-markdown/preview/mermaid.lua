local M = {
    name = 'mermaid',
    command = 'termaid',
    max_blocks = 8,
    max_concurrent = 2,
    max_output_bytes = 1024 * 1024,
    max_rendered_chunks = 65536,
    max_rendered_lines = 4096,
    max_source_bytes = 256 * 1024,
    timeout_ms = 8000,
    width_ratio = 0.85,
    arrow_position = 'end',
}
local markdown_features = require('render-markdown.preview.features')

local states_by_buffer = {}
local element_namespace =
    vim.api.nvim_create_namespace('markdown_mermaid_elements')
local block_query
local block_query_resolved = false
local styled_support_by_executable = {}

local style_highlights = {
    active = 'RenderMarkdownMermaidActive',
    arrow = 'RenderMarkdownMermaidArrow',
    bold_label = 'RenderMarkdownMermaidBoldLabel',
    crit = 'RenderMarkdownMermaidCritical',
    default = 'RenderMarkdownMermaid',
    done = 'RenderMarkdownMermaidDone',
    edge = 'RenderMarkdownMermaidEdge',
    edge_label = 'RenderMarkdownMermaidEdgeLabel',
    italic_label = 'RenderMarkdownMermaidItalicLabel',
    label = 'RenderMarkdownMermaidContentLabel',
    milestone = 'RenderMarkdownMermaidMilestone',
    node = 'RenderMarkdownMermaidNode',
    normal = 'RenderMarkdownMermaidNode',
    subgraph = 'RenderMarkdownMermaidSubgraph',
    subgraph_label = 'RenderMarkdownMermaidSubgraphLabel',
}

local section_highlights = {
    'RenderMarkdownMermaidSection1',
    'RenderMarkdownMermaidSection2',
    'RenderMarkdownMermaidSection3',
    'RenderMarkdownMermaidSection4',
    'RenderMarkdownMermaidSection5',
    'RenderMarkdownMermaidSection6',
    'RenderMarkdownMermaidSection7',
    'RenderMarkdownMermaidSection8',
}

local function query()
    if block_query_resolved then
        return block_query
    end
    block_query_resolved = true
    pcall(function()
        block_query =
            vim.treesitter.query.parse('markdown', '(fenced_code_block) @block')
    end)
    return block_query
end

local function child_of_type(node, node_type)
    for child in node:iter_children() do
        if child:named() and child:type() == node_type then
            return child
        end
    end
    return nil
end

local function is_mermaid(info)
    local language = vim.trim(info):match('^(%S+)')
    return language ~= nil and language:lower() == 'mermaid'
end

local function line_end_exclusive(node)
    local _, _, end_row, end_column = node:range()
    return end_row + (end_column > 0 and 1 or 0)
end

local function block_from_node(buffer, node, width)
    local info_node = child_of_type(node, 'info_string')
    local content_node = child_of_type(node, 'code_fence_content')
    local info = info_node and vim.treesitter.get_node_text(info_node, buffer)
        or ''
    if not content_node or not is_mermaid(info) then
        return nil
    end

    local source = vim.treesitter
        .get_node_text(content_node, buffer)
        :gsub('\r\n', '\n')
        :gsub('\r', '\n')
        :gsub('\n+$', '')
    local block_start = node:range()
    local content_start = content_node:range()
    local content_end = line_end_exclusive(content_node)
    local block_end = line_end_exclusive(node)
    local key = markdown_features.block_key(source, { width })
    return {
        block_end = block_end,
        block_start = block_start,
        content_end = content_end,
        content_start = content_start,
        key = key,
        source = source,
        width = width,
    }
end

local function text_lines(text)
    local normalized = text:gsub('\r\n', '\n'):gsub('\r', '\n'):gsub('\n+$', '')
    if normalized == '' then
        return nil
    end
    return vim.split(normalized, '\n', { plain = true })
end

local function common_indent(lines)
    local indent
    for _, line in ipairs(lines) do
        if line:find('%S') then
            local line_indent = #(line:match('^ *') or '')
            indent = math.min(indent or line_indent, line_indent)
        end
    end
    return indent or 0
end

---@param lines string[]
---@param width integer
---@return string[]?
function M.fit_lines(lines, width)
    local fitted = {}
    local indent = common_indent(lines)
    local limit = math.max(2, math.floor(width))
    for _, raw_line in ipairs(lines) do
        local line = indent > 0 and raw_line:sub(indent + 1) or raw_line
        if vim.fn.strdisplaywidth(line) > limit then
            return nil
        end
        fitted[#fitted + 1] = line
    end
    return fitted
end

local function style_highlight(style)
    local direct = style_highlights[style]
    if direct then
        return direct
    end
    if style:find('^class:') or style:find('^nodestyle:') then
        return style_highlights.node
    end
    if style:find('^linkstyle:') then
        return style_highlights.edge
    end
    local section = tonumber(style:match('^section:(%d+)'))
        or tonumber(style:match('^sectionfg:(%d+)'))
    if section then
        return section_highlights[(section % #section_highlights) + 1]
    end
    return style_highlights.default
end

local function valid_chunk_text(text)
    return type(text) == 'string' and not text:find('[%z\1-\31\127]')
end

---@param output string
---@param width integer
---@return table[]?
function M.decode_styled_output(output, width)
    local decoded_ok, decoded = pcall(vim.json.decode, output)
    if
        not decoded_ok
        or type(decoded) ~= 'table'
        or decoded.version ~= 1
        or type(decoded.lines) ~= 'table'
        or #decoded.lines == 0
        or #decoded.lines > M.max_rendered_lines
    then
        return nil
    end
    local rendered_lines = {}
    local chunk_count = 0
    for _, raw_line in ipairs(decoded.lines) do
        if type(raw_line) ~= 'table' then
            return nil
        end
        local chunks = {}
        local text_parts = {}
        for _, raw_chunk in ipairs(raw_line) do
            if
                type(raw_chunk) ~= 'table'
                or not valid_chunk_text(raw_chunk.text)
                or raw_chunk.text:find('\n', 1, true)
                or type(raw_chunk.style) ~= 'string'
                or #raw_chunk.style > 128
                or not raw_chunk.style:match('^[%w_:%-%.]+$')
            then
                return nil
            end
            if raw_chunk.text ~= '' then
                chunk_count = chunk_count + 1
                if chunk_count > M.max_rendered_chunks then
                    return nil
                end
                text_parts[#text_parts + 1] = raw_chunk.text
                chunks[#chunks + 1] = {
                    raw_chunk.text,
                    style_highlight(raw_chunk.style),
                }
            end
        end
        local line_text = table.concat(text_parts)
        if
            vim.fn.strdisplaywidth(line_text) > math.max(2, math.floor(width))
        then
            return nil
        end
        rendered_lines[#rendered_lines + 1] = {
            chunks = chunks,
            text = line_text,
        }
    end
    return rendered_lines
end

local function plain_rendered_lines(output, width)
    local lines = text_lines(output)
    if not lines then
        return nil
    end
    local fitted_lines = M.fit_lines(lines, width)
    if not fitted_lines or #fitted_lines > M.max_rendered_lines then
        return nil
    end
    return vim.tbl_map(function(line)
        return {
            chunks = {
                { line == '' and ' ' or line, style_highlights.default },
            },
            text = line,
        }
    end, fitted_lines)
end

local function content_width(buffer)
    local width
    for _, window in ipairs(vim.api.nvim_list_wins()) do
        if
            vim.api.nvim_win_is_valid(window)
            and vim.api.nvim_win_get_buf(window) == buffer
        then
            local window_info = vim.fn.getwininfo(window)[1] or { textoff = 0 }
            local text_width = vim.api.nvim_win_get_width(window)
                - window_info.textoff
            local available = math.floor(text_width * M.width_ratio)
            width = math.min(width or available, available)
        end
    end
    return math.max(1, width or math.floor((vim.o.columns - 4) * M.width_ratio))
end

local function stop_request(request)
    if request.process then
        pcall(function()
            request.process:kill(15)
        end)
        request.process = nil
    end
end

local function retire_state(state, keep_layout)
    state.generation = state.generation + 1
    for _, request in pairs(state.jobs) do
        stop_request(request)
    end
    state.active = 0
    state.jobs = {}
    state.queue = {}
    if not keep_layout and vim.api.nvim_buf_is_valid(state.buffer) then
        vim.api.nvim_buf_clear_namespace(state.buffer, element_namespace, 0, -1)
    end
end

local function new_state(buffer, changedtick, width, generation, settings)
    return {
        buffer = buffer,
        active = 0,
        arrow_position = M.arrow_position == 'middle' and 'middle' or 'end',
        blocks = {},
        changedtick = changedtick,
        generation = generation,
        jobs = {},
        projections = {},
        queue = {},
        results = {},
        settings = settings,
        width = width,
    }
end

local function state_for(buffer, width)
    local changedtick = vim.api.nvim_buf_get_changedtick(buffer)
    local arrow_position = M.arrow_position == 'middle' and 'middle' or 'end'
    local settings = {
        M.command,
        M.max_rendered_lines,
        M.max_source_bytes,
        M.max_output_bytes,
        M.max_rendered_chunks,
        M.timeout_ms,
        M.max_blocks,
    }
    local current_state = states_by_buffer[buffer]
    if
        current_state
        and current_state.width == width
        and current_state.arrow_position == arrow_position
        and vim.deep_equal(current_state.settings, settings)
    then
        return current_state
    end
    if current_state then
        for _, block in ipairs(current_state.blocks) do
            local result = current_state.results[block.key]
            if result and result.status == 'rendered' then
                block.fallback, block.fallback_key = result, block.key
            end
        end
        retire_state(current_state, true)
        current_state.results = {}
        current_state.projections = {}
        current_state.width = width
        current_state.arrow_position = arrow_position
        current_state.settings = settings
        return current_state
    end
    local next_state = new_state(buffer, changedtick, width, 1, settings)
    states_by_buffer[buffer] = next_state
    return next_state
end

local function reconcile_blocks(buffer, state, root)
    local parsed_query = query()
    local blocks = {}
    local previous_by_row = {}
    for _, previous in ipairs(state.blocks) do
        if previous.anchor then
            local position = vim.api.nvim_buf_get_extmark_by_id(
                buffer,
                element_namespace,
                previous.anchor,
                { details = true }
            )
            if #position > 0 then
                local row = position[1]
                local candidates = previous_by_row[row] or {}
                candidates[#candidates + 1] =
                    { block = previous, end_row = position[3].end_row }
                previous_by_row[row] = candidates
            end
        end
    end
    if parsed_query then
        for _, node in parsed_query:iter_captures(root, buffer, 0, -1) do
            local block = block_from_node(buffer, node, state.width)
            if block then
                blocks[#blocks + 1] = block
            end
        end
    end
    local plan = markdown_features.plan_elements(
        blocks,
        state.results,
        state.jobs,
        M.max_blocks
    )
    local retained_anchors = {}
    for _, block in ipairs(blocks) do
        if plan.by_key[block.key] then
            local candidates = previous_by_row[block.block_start] or {}
            local previous = #candidates == 1 and candidates[1] or nil
            if previous and previous.end_row == block.block_end then
                block.anchor = previous.block.anchor
                local result = state.results[previous.block.key]
                if result and result.status == 'rendered' then
                    block.fallback, block.fallback_key =
                        result, previous.block.key
                else
                    block.fallback, block.fallback_key =
                        previous.block.fallback, previous.block.fallback_key
                end
            end
            block.anchor = vim.api.nvim_buf_set_extmark(
                buffer,
                element_namespace,
                block.block_start,
                0,
                {
                    id = block.anchor,
                    end_row = block.block_end,
                    end_col = 0,
                    right_gravity = true,
                    end_right_gravity = false,
                }
            )
            retained_anchors[block.anchor] = true
        end
    end
    for _, previous in ipairs(state.blocks) do
        if previous.anchor and not retained_anchors[previous.anchor] then
            vim.api.nvim_buf_del_extmark(
                buffer,
                element_namespace,
                previous.anchor
            )
        end
    end
    for key, request in pairs(state.jobs) do
        if not plan.by_key[key] then
            stop_request(request)
            state.jobs[key] = nil
            state.active = state.active - 1
        else
            request.block = plan.by_key[key]
        end
    end
    for key in pairs(state.results) do
        if not plan.by_key[key] then
            state.results[key] = nil
        end
    end
    state.queue = plan.render
    state.elements = plan.by_key
    state.blocks = blocks
    state.changedtick = vim.api.nvim_buf_get_changedtick(buffer)
end

---@return string?
function M.find_executable()
    local configured_path = vim.fn.expand(M.command)
    if configured_path == 'termaid' then
        local lazy_config = package.loaded['lazy.core.config']
        local plugin = lazy_config
            and lazy_config.plugins
            and lazy_config.plugins.termaid
        local plugin_directory = plugin and plugin.dir
            or vim.fs.joinpath(vim.fn.stdpath('data'), 'lazy', 'termaid')
        local managed_path =
            vim.fs.joinpath(plugin_directory, '.venv', 'bin', 'termaid')
        if vim.fn.executable(managed_path) == 1 then
            return managed_path
        end
        if plugin then
            return nil
        end
    end
    if configured_path:find('/', 1, true) then
        return vim.fn.executable(configured_path) == 1 and configured_path
            or nil
    end
    local executable_path = vim.fn.exepath(configured_path)
    if executable_path ~= '' then
        return executable_path
    end
    return nil
end

function M.start_process(command, options, callback)
    return vim.system(command, options, callback)
end

local function request_render(buffer)
    markdown_features.request_render(buffer, 'MermaidRender')
end

local function report_failure(block, reason)
    local message = ('Mermaid line %d: %s; showing source.'):format(
        block.block_start + 1,
        reason
    )
    vim.api.nvim_echo({ { message, 'WarningMsg' } }, true, {})
end

local pump
local launch_request

local function finish_request(buffer, state, request, completed_process)
    if
        states_by_buffer[buffer] ~= state
        or state.generation ~= request.generation
        or not vim.api.nvim_buf_is_valid(buffer)
        or state.jobs[request.block.key] ~= request
    then
        return
    end
    if vim.api.nvim_buf_get_changedtick(buffer) ~= state.changedtick then
        -- A completion may arrive while the source is being edited and preview is
        -- hidden. Revalidate object identities before accepting it or starting work.
        local parser = vim.treesitter.get_parser(buffer, 'markdown')
        local tree = parser:parse()[1]
        if not tree then
            return
        end
        reconcile_blocks(buffer, state, tree:root())
        if state.jobs[request.block.key] ~= request then
            if state.requires_layout then
                request_render(buffer)
            else
                pump(buffer, state)
            end
            return
        end
    end
    request.process = nil

    local stdout = completed_process.stdout or ''
    local rendered_lines
    if completed_process.code == 0 and #stdout <= M.max_output_bytes then
        rendered_lines = request.styled
                and M.decode_styled_output(stdout, request.block.width)
            or plain_rendered_lines(stdout, request.block.width)
    end
    if request.styled and rendered_lines then
        styled_support_by_executable[request.executable] = true
    elseif request.styled then
        local stderr = completed_process.stderr or ''
        local unsupported = completed_process.code == 2
            and (
                stderr:find('--format', 1, true)
                or stderr:find('unrecognized arguments', 1, true)
            )
        if completed_process.code == 0 or unsupported then
            styled_support_by_executable[request.executable] = unsupported
                    and false
                or nil
            request.styled = false
            launch_request(buffer, state, request)
            return
        end
    end
    state.jobs[request.block.key] = nil
    state.active = math.max(0, state.active - 1)
    state.results[request.block.key] = rendered_lines
            and {
                lines = rendered_lines,
                width = request.block.width,
                height = #rendered_lines + 1,
                source = request.block.source,
                status = 'rendered',
            }
        or {
            status = completed_process.code == 124 and 'timeout' or 'failed',
        }
    if completed_process.code ~= 0 then
        local reason = completed_process.code == 124
                and ('render timed out after %d ms'):format(M.timeout_ms)
            or ('render failed (exit %s)'):format(
                tostring(completed_process.code)
            )
        report_failure(request.block, reason)
    end
    pump(buffer, state)
    request_render(buffer)
end

launch_request = function(buffer, state, request)
    -- Spend narrow-view space on labels first. Wider views can afford more
    -- separation. Termaid's default grid aligns rows/columns and caps extra
    -- same-layer matching; keep node heights local to their content rows.
    local gap = math.max(1, math.min(4, math.floor(request.block.width / 40)))
    local command = {
        request.executable,
        '--width',
        tostring(request.block.width),
        '--strict-width',
        '--fit-mode',
        'reflow',
        '--max-height',
        tostring(M.max_rendered_lines),
        '--gap',
        tostring(gap),
        '--padding-x',
        tostring(math.min(gap, 2)),
        '--padding-y',
        '0',
    }
    if request.styled then
        vim.list_extend(command, { '--format', 'styled-json' })
    end
    if state.arrow_position == 'middle' then
        vim.list_extend(command, { '--arrow-position', 'middle' })
    end
    local started, process = pcall(M.start_process, command, {
        stdin = request.block.source,
        text = true,
        timeout = M.timeout_ms,
    }, function(completed_process)
        vim.schedule(function()
            local handled =
                pcall(finish_request, buffer, state, request, completed_process)
            if
                not handled
                and states_by_buffer[buffer] == state
                and state.jobs[request.block.key] == request
            then
                finish_request(buffer, state, request, { code = 1 })
            end
        end)
    end)
    if not started then
        state.jobs[request.block.key] = nil
        state.active = math.max(0, state.active - 1)
        state.results[request.block.key] = { status = 'unavailable' }
        return
    end
    request.process = process
end

local function start_request(buffer, state, block)
    local executable = M.find_executable()
    if not executable then
        state.results[block.key] = { status = 'unavailable' }
        return
    end
    if #block.source > M.max_source_bytes then
        state.results[block.key] = { status = 'limit' }
        return
    end

    local request = {
        block = block,
        executable = executable,
        generation = state.generation,
        styled = styled_support_by_executable[executable] ~= false,
    }
    state.jobs[block.key] = request
    state.active = state.active + 1
    launch_request(buffer, state, request)
end

pump = function(buffer, state)
    if state.requires_layout and state.layout_tick ~= state.changedtick then
        return false
    end
    local settled = false
    while
        states_by_buffer[buffer] == state
        and state.active < M.max_concurrent
        and #state.queue > 0
    do
        local block = table.remove(state.queue, 1)
        start_request(buffer, state, block)
        settled = settled or state.results[block.key] ~= nil
    end
    return settled
end

local function line_chunks(line)
    if type(line) == 'table' then
        if #line.chunks == 0 then
            return { { ' ', style_highlights.default } }
        end
        return vim.deepcopy(line.chunks)
    end
    return { { line == '' and ' ' or line, style_highlights.default } }
end

-- Provider-owned estimation. Large replacements keep the last measured height;
-- smaller changes scale it with the available width, not with source line count.
function M.estimate_layout(source, width, previous)
    if not previous then
        return { width = width, height = 4, estimated = true, basis = 'initial' }
    end
    local old_source = previous.source
    local prefix = 0
    local common_limit = math.min(#source, #old_source)
    while
        prefix < common_limit
        and source:byte(prefix + 1) == old_source:byte(prefix + 1)
    do
        prefix = prefix + 1
    end
    local suffix = 0
    while
        suffix < common_limit - prefix
        and source:byte(#source - suffix)
            == old_source:byte(#old_source - suffix)
    do
        suffix = suffix + 1
    end
    local changed_fraction = 1
        - (prefix + suffix) / math.max(1, #source, #old_source)
    local height = previous.height
    if changed_fraction <= 0.5 then
        height = math.max(
            2,
            math.ceil(
                (previous.height - 1) * previous.width / math.max(1, width)
            ) + 1
        )
    end
    return {
        width = width,
        height = math.min(M.max_rendered_lines + 1, height),
        estimated = true,
        basis = changed_fraction > 0.5 and 'previous' or 'scaled',
    }
end

local function bounded_chunks(chunks, width)
    local fitted = {}
    local remaining = width
    for _, chunk in ipairs(chunks) do
        if remaining <= 0 then
            break
        end
        local text = chunk[1]
        local count = vim.fn.strchars(text)
        local low, high = 0, count
        while low < high do
            local middle = math.ceil((low + high) / 2)
            if
                vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, middle))
                <= remaining
            then
                low = middle
            else
                high = middle - 1
            end
        end
        local clipped = vim.fn.strcharpart(text, 0, low)
        fitted[#fitted + 1] = { clipped, chunk[2] }
        remaining = remaining - vim.fn.strdisplaywidth(clipped)
        if low < count then
            break
        end
    end
    return fitted
end

function M.parse(context)
    local parsed_query = query()
    if not parsed_query then
        return {}
    end
    local width = context.width
            and math.max(1, math.floor(context.width * M.width_ratio))
        or content_width(context.buf)
    local state = state_for(context.buf, width)
    reconcile_blocks(context.buf, state, context.root)
    state.requires_layout = context.defer_render ~= nil
    if context.defer_render then
        local generation = state.generation
        local changedtick = state.changedtick
        context.defer_render(function()
            if
                states_by_buffer[context.buf] == state
                and vim.api.nvim_buf_is_valid(context.buf)
                and state.generation == generation
                and vim.api.nvim_buf_get_changedtick(context.buf)
                    == changedtick
            then
                state.layout_tick = changedtick
                if pump(context.buf, state) then
                    request_render(context.buf)
                end
            end
        end)
    else
        pump(context.buf, state)
    end
    return {}
end

function M.stage(buffer)
    local state = states_by_buffer[buffer]
    if not state then
        return {}
    end
    local blocks = {}
    local retained = {}
    for _, block in ipairs(state.blocks) do
        local result = state.results[block.key]
        local pending = result == nil and state.elements[block.key] ~= nil
        local displayed_result = result or block.fallback
        if
            (displayed_result and displayed_result.status == 'rendered')
            or pending
        then
            local phase = pending
                    and ('pending:' .. (block.fallback_key or 'new'))
                or 'ready'
            local key = table.concat({
                block.key,
                phase,
                block.block_end - block.block_start,
                block.content_start - block.block_start,
                block.content_end - block.content_start,
            }, ':')
            local projected = markdown_features.cached_projection(
                state.projections,
                key,
                block.block_start,
                function()
                    local rows = {
                        {
                            chunks = {
                                { '󰙅 ', 'RenderMarkdownMermaidIcon' },
                                {
                                    pending and 'mermaid ↻' or 'mermaid',
                                    'RenderMarkdownMermaidLabel',
                                },
                            },
                            source_row = block.block_start,
                        },
                    }
                    local source_count = block.content_end - block.content_start
                    local rendered_lines = displayed_result
                            and displayed_result.lines
                        or {}
                    local layout = pending
                            and M.estimate_layout(
                                block.source,
                                block.width,
                                block.fallback
                            )
                        or {
                            width = block.width,
                            height = #rendered_lines + 1,
                            estimated = false,
                        }
                    local diagram_width =
                        markdown_features.chunks_width(rows[1].chunks)
                    for index = 1, layout.height - 1 do
                        local line = rendered_lines[index]
                            or (
                                index == 1
                                    and not displayed_result
                                    and (block.width >= 10 and 'Rendering…' or '…')
                                or ''
                            )
                        local chunks = pending
                                and bounded_chunks(
                                    line_chunks(line),
                                    block.width
                                )
                            or line_chunks(line)
                        if pending then
                            local padding = math.max(
                                0,
                                block.width
                                    - markdown_features.chunks_width(chunks)
                            )
                            chunks[#chunks + 1] = {
                                string.rep(' ', padding),
                                style_highlights.default,
                            }
                        end
                        diagram_width = math.max(
                            diagram_width,
                            markdown_features.chunks_width(chunks)
                        )
                        rows[#rows + 1] = {
                            chunks = chunks,
                            source_row = block.content_start
                                + math.min(
                                    source_count - 1,
                                    math.floor(
                                        (index - 1)
                                            * source_count
                                            / (layout.height - 1)
                                    )
                                ),
                        }
                    end
                    -- Fill one rectangle for the title and diagram, retaining semantic spans.
                    for _, row in ipairs(rows) do
                        local chunks = row.chunks
                        local padding_width = diagram_width
                            - markdown_features.chunks_width(chunks)
                        if padding_width > 0 then
                            chunks[#chunks + 1] = {
                                string.rep(' ', padding_width),
                                style_highlights.default,
                            }
                        end
                    end
                    return {
                        start_row = block.block_start,
                        end_row = block.block_end,
                        rows = rows,
                        pending = pending,
                        layout = vim.tbl_extend(
                            'force',
                            layout,
                            { width = diagram_width }
                        ),
                    }
                end
            )
            blocks[#blocks + 1] = projected
            retained[key] = state.projections[key]
        end
    end
    state.projections = retained
    return blocks
end

function M.project(context)
    M.parse(context)
    return M.stage(context.buf)
end

-- Return provider-owned geometry and deferred work. Layout never starts jobs.
function M.layout(context)
    -- Termaid is optional. Missing executables leave fences untouched and do
    -- not create loading placeholders or notifications.
    if not M.find_executable() then
        M.detach(context.buf)
        return {}, {}
    end
    local tasks = {}
    local layout_context = vim.tbl_extend('force', context, {
        defer_render = function(task)
            tasks[#tasks + 1] = task
        end,
    })
    M.parse(layout_context)
    return M.stage(context.buf), tasks
end

function M.detach(buffer)
    local state = states_by_buffer[buffer]
    if state then
        retire_state(state)
        states_by_buffer[buffer] = nil
    end
end

return M
