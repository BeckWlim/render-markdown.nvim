-- Focused projection, fallback, and process-budget tests for Mermaid.
local markdown_features = require('render-markdown.preview.features')
local mermaid = require('render-markdown.preview.mermaid')
local function message_history()
    return vim.api.nvim_exec2('messages', { output = true }).output
end
vim.cmd('messages clear')

-- Resolve the managed checkout, including a custom lazy root, before any PATH tool.
local saved_lazy_config = package.loaded['lazy.core.config']
local saved_command = mermaid.command
local saved_search_path = vim.env.PATH
local resolver_directory = vim.fn.tempname() .. ' lazy root'
local managed_directory = resolver_directory .. '/termaid'
local managed_executable = managed_directory .. '/.venv/bin/termaid'
local external_executable = resolver_directory .. '/bin/termaid'
vim.fn.mkdir(resolver_directory .. '/bin', 'p')
vim.fn.writefile({ '#!/bin/sh', 'exit 0' }, external_executable)
vim.fn.setfperm(external_executable, 'rwx------')
vim.env.PATH = resolver_directory .. '/bin:' .. (saved_search_path or '')
package.loaded['lazy.core.config'] = nil
local default_managed_path = vim.fs.joinpath(
    vim.fn.stdpath('data'),
    'lazy',
    'termaid',
    '.venv/bin/termaid'
)
local expected_default = vim.fn.executable(default_managed_path) == 1
        and default_managed_path
    or external_executable
assert(
    mermaid.find_executable() == expected_default,
    'Default lazy checkout was not resolved'
)
package.loaded['lazy.core.config'] =
    { plugins = { termaid = { dir = managed_directory } } }
assert(
    mermaid.find_executable() == nil,
    'Missing managed Termaid fell back to an unrelated installation'
)
vim.fn.mkdir(managed_directory .. '/.venv/bin', 'p')
vim.fn.writefile({ '#!/bin/sh', 'exit 0' }, managed_executable)
vim.fn.setfperm(managed_executable, 'rwx------')
assert(
    mermaid.find_executable() == managed_executable,
    'Custom lazy root or newly installed executable was ignored'
)
mermaid.command = resolver_directory .. '/missing/termaid'
assert(
    mermaid.find_executable() == nil,
    'Missing explicit executable fell back to managed Termaid'
)
mermaid.command = external_executable
assert(
    mermaid.find_executable() == external_executable,
    'Explicit executable path was ignored'
)
mermaid.command = 'sh'
assert(
    mermaid.find_executable() == vim.fn.exepath('sh'),
    'Explicit PATH command was ignored'
)
mermaid.command = saved_command
package.loaded['lazy.core.config'] = saved_lazy_config
vim.env.PATH = saved_search_path
vim.fn.delete(resolver_directory, 'rf')

local original = {
    arrow_position = mermaid.arrow_position,
    buffer = vim.api.nvim_get_current_buf(),
    find_executable = mermaid.find_executable,
    guicursor = vim.o.guicursor,
    max_concurrent = mermaid.max_concurrent,
    feature_request_render = markdown_features.request_render,
    start_process = mermaid.start_process,
    timeout = mermaid.timeout_ms,
    width_ratio = mermaid.width_ratio,
}

local refreshes = 0
markdown_features.request_render = function(buffer, event)
    assert(
        vim.api.nvim_buf_is_valid(buffer),
        'Mermaid requested an invalid buffer'
    )
    assert(
        event == 'MermaidRender',
        'Mermaid used the wrong shared render event'
    )
    refreshes = refreshes + 1
end

local function fixture(lines)
    local buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
    vim.bo[buffer].filetype = 'markdown'
    vim.api.nvim_set_current_buf(buffer)
    local parser = vim.treesitter.get_parser(buffer, 'markdown')
    local tree = assert(parser:parse()[1], 'Expected preview test condition')
    return buffer, { buf = buffer, root = tree:root() }
end

local buffer, context = fixture({
    '',
    '```mermaid',
    'graph LR',
    '  A --> B',
    '```',
    '```python',
    'print("not mermaid")',
    '```',
})

local fitted_lines = assert(
    mermaid.fit_lines({
        '    ABCD',
        '    你好',
    }, 4),
    'Expected preview test condition'
)
assert(
    vim.deep_equal(fitted_lines, { 'ABCD', '你好' }),
    'Mermaid output was not validated and left-aligned'
)
for _, line in ipairs(fitted_lines) do
    assert(
        vim.fn.strdisplaywidth(line) <= 4,
        'Mermaid width validation accepted an oversized display line'
    )
end
assert(
    mermaid.fit_lines({ 'ABCDE' }, 4) == nil,
    'Mermaid accepted a canvas wider than the strict width contract'
)

local process_requests = {}
local killed_processes = 0
local function styled_output(lines)
    return vim.json.encode({ version = 1, lines = lines })
end

local colorful_output = styled_output({
    {
        { text = '┌', style = 'node' },
        { text = '─', style = 'edge' },
        { text = '►', style = 'arrow' },
    },
    {
        { text = '│ ', style = 'node' },
        { text = 'A', style = 'label' },
        { text = ' │', style = 'node' },
    },
    { { text = '└───┘', style = 'node' } },
})

local decoded_colorful = assert(
    mermaid.decode_styled_output(colorful_output, 8),
    'Expected preview test condition'
)
assert(
    decoded_colorful[1].chunks[1][2] == 'RenderMarkdownMermaidNode'
        and decoded_colorful[1].chunks[2][2] == 'RenderMarkdownMermaidEdge'
        and decoded_colorful[1].chunks[3][2] == 'RenderMarkdownMermaidArrow'
        and decoded_colorful[2].chunks[2][2]
            == 'RenderMarkdownMermaidContentLabel',
    'Mermaid semantic output did not map to its bounded color palette'
)
assert(
    mermaid.decode_styled_output('{"version":2,"lines":[]}', 8) == nil
        and mermaid.decode_styled_output(
                styled_output({
                    {
                        { text = 'too wide', style = 'node' },
                    },
                }),
                3
            )
            == nil,
    'Mermaid accepted an unknown styled schema or oversized semantic row'
)

mermaid.find_executable = function()
    return nil
end
mermaid.start_process = function()
    error('Missing Termaid fallback started a process')
end
assert(
    #mermaid.parse(context) == 0,
    'Missing Termaid support did not leave Mermaid source as raw text'
)
assert(#process_requests == 0, 'Missing Termaid support queued a renderer')

mermaid.detach(buffer)
mermaid.find_executable = function()
    return '/test/bin/termaid'
end
mermaid.start_process = function(command, options, callback)
    process_requests[#process_requests + 1] = {
        callback = callback,
        command = command,
        options = options,
    }
    return {
        kill = function(_, signal)
            assert(
                signal == 15,
                'Mermaid renderer did not terminate with SIGTERM'
            )
            killed_processes = killed_processes + 1
        end,
    }
end
mermaid.timeout_ms = 4321

assert(
    #mermaid.parse(context) == 0 and #process_requests == 1,
    'Initial Markdown parsing did not automatically try the Mermaid renderer'
)
local render_request = process_requests[1]
local window_info = vim.fn.getwininfo(0)[1] or { textoff = 0 }
local expected_width = math.max(
    1,
    math.floor((vim.api.nvim_win_get_width(0) - window_info.textoff) * 0.85)
)
assert(
    render_request.command[1] == '/test/bin/termaid'
        and render_request.command[2] == '--width'
        and tonumber(render_request.command[3]) == expected_width,
    'Mermaid renderer did not receive the expanded near-80-percent view width'
)
assert(
    render_request.command[4] == '--strict-width'
        and render_request.command[5] == '--fit-mode'
        and render_request.command[6] == 'reflow'
        and render_request.command[7] == '--max-height'
        and tonumber(render_request.command[8]) == mermaid.max_rendered_lines
        and render_request.command[15] == '--format'
        and render_request.command[16] == 'styled-json',
    'Mermaid renderer did not request strict bounded semantic output'
)
assert(
    render_request.command[9] == '--gap'
        and render_request.command[11] == '--padding-x'
        and render_request.command[13] == '--padding-y'
        and render_request.command[14] == '0',
    'Mermaid renderer did not receive explicit spacing parameters'
)
assert(
    not vim.tbl_contains(render_request.command, '--uniform-nodes'),
    'Mermaid overrode row/column sizing with diagram-wide uniform boxes'
)
assert(
    not vim.tbl_contains(render_request.command, '--arrow-position'),
    'Mermaid changed the default endpoint arrow placement'
)
assert(
    render_request.options.stdin == 'graph LR\n  A --> B'
        and render_request.options.text == true
        and render_request.options.timeout == 4321,
    'Mermaid renderer lost its source, text mode, or timeout budget'
)
render_request.callback({
    code = 0,
    stderr = '',
    stdout = colorful_output,
})
assert(
    vim.wait(100, function()
        return refreshes == 1
    end, 1),
    'Completed Mermaid rendering did not use the shared refresh pipeline'
)

local source_tick = vim.api.nvim_buf_get_changedtick(buffer)
local blocks = mermaid.project(context)
assert(
    #blocks == 1 and blocks[1].start_row == 1 and blocks[1].end_row == 5,
    'Mermaid projection lost its complete source range'
)
assert(
    #blocks[1].rows == 4 and blocks[1].rows[1].chunks[1][1] == '󰙅 ',
    'Mermaid projection lost its label or real rendered rows'
)
local rendered_lines = {}
local semantic_highlights = {}
for index, row in ipairs(blocks[1].rows) do
    local parts = {}
    for _, chunk in ipairs(row.chunks) do
        parts[#parts + 1] = chunk[1]
        semantic_highlights[chunk[2]] = true
    end
    if index > 1 then
        rendered_lines[#rendered_lines + 1] = table.concat(parts)
        assert(
            row.source_row >= 2 and row.source_row < 4,
            'Diagram row lost its source position'
        )
    end
end
local expected_diagram_width =
    math.max(vim.fn.strdisplaywidth('󰙅 mermaid'), 5)
for index, content in ipairs({ '┌─►', '│ A │', '└───┘' }) do
    assert(
        rendered_lines[index]
            == content
                .. string.rep(
                    ' ',
                    expected_diagram_width - vim.fn.strdisplaywidth(content)
                ),
        'Mermaid projection did not fill the shorter row to the title or diagram right edge'
    )
end
assert(
    markdown_features.chunks_width(blocks[1].rows[1].chunks)
        == expected_diagram_width,
    'Mermaid title did not share the filled rectangle'
)
assert(
    blocks[1].rows[2].chunks[#blocks[1].rows[2].chunks][2]
        == 'RenderMarkdownMermaid',
    'Mermaid padding lost its canvas highlight'
)
assert(
    semantic_highlights.RenderMarkdownMermaidNode
        and semantic_highlights.RenderMarkdownMermaidEdge
        and semantic_highlights.RenderMarkdownMermaidArrow
        and semantic_highlights.RenderMarkdownMermaidContentLabel,
    'Mermaid projection flattened semantic colors'
)
assert(
    #mermaid.project(context) == 1 and #process_requests == 1,
    'Cached projection restarted the renderer'
)
assert(
    source_tick == vim.api.nvim_buf_get_changedtick(buffer)
        and vim.o.guicursor == original.guicursor,
    'Mermaid projection changed source text or the native cursor'
)
mermaid.detach(buffer)
assert(
    #mermaid.stage(buffer) == 0,
    'Mermaid detach retained its rendered output'
)

refreshes = 0
process_requests = {}
mermaid.find_executable = function()
    return '/test/bin/old-termaid'
end
assert(
    #mermaid.parse(context) == 0 and #process_requests == 1,
    'Expected preview test condition'
)
process_requests[1].callback({
    code = 2,
    stderr = 'error: unrecognized arguments: --format styled-json',
    stdout = '',
})
assert(
    vim.wait(100, function()
        return #process_requests == 2
    end, 1),
    'Older Termaid did not receive a bounded plain-output retry'
)
assert(
    not vim.tbl_contains(process_requests[2].command, '--format'),
    'Mermaid plain fallback retained the unsupported styled-output option'
)
process_requests[2].callback({ code = 0, stdout = 'plain fallback\n\n你好' })
assert(
    vim.wait(100, function()
        return refreshes == 1
    end, 1),
    'Mermaid plain fallback did not settle through the shared pipeline'
)
assert(#mermaid.stage(buffer) == 1, 'Mermaid plain fallback was not rendered')
local fallback_rows = mermaid.stage(buffer)[1].rows
for index = 2, #fallback_rows do
    assert(
        markdown_features.chunks_width(fallback_rows[index].chunks) == 14,
        'Mermaid blank or wide-character row did not fill the rectangle in display cells'
    )
end
assert(
    not message_history():find('Mermaid line ', 1, true),
    'Successful renders or a recovered compatibility retry logged a render failure'
)

mermaid.detach(buffer)
refreshes = 0
process_requests = {}
local renderer_available = true
mermaid.find_executable = function()
    return renderer_available and '/test/bin/termaid' or nil
end
assert(#mermaid.parse(context) == 0, 'A fresh Mermaid render was not pending')
vim.api.nvim_buf_set_name(buffer, '/tmp/termaid-errors.md')
local error_before_failure = vim.v.errmsg
local tick_before_failure = vim.api.nvim_buf_get_changedtick(buffer)
process_requests[1].callback({
    code = 1,
    stderr = 'Error rendering diagram: invalid graph\nparse detail',
    stdout = '',
})
assert(
    vim.wait(100, function()
        return refreshes == 1
    end, 1),
    'Failed Mermaid rendering did not settle through the shared pipeline'
)
assert(
    #mermaid.parse(context) == 0 and #process_requests == 1,
    'Failed Mermaid rendering did not retain raw source without retrying'
)
local failure_history = message_history()
assert(
    failure_history:find('Mermaid line 2:', 1, true)
        and failure_history:find('exit 1', 1, true)
        and not failure_history:find('\n', 1, true)
        and not failure_history:find('parse detail', 1, true),
    'Mermaid failure did not produce a single-line warning without stderr'
)
assert(
    vim.v.errmsg == error_before_failure
        and not vim.api.nvim_get_mode().blocking,
    'Optional Mermaid failure raised an editor error or blocked input'
)
assert(
    vim.api.nvim_buf_get_changedtick(buffer) == tick_before_failure
        and vim.bo[buffer].modifiable,
    'Optional Mermaid failure changed source text or disabled editing'
)
mermaid.parse(context)
assert(
    message_history() == failure_history,
    'A cached failed render repeated its error log'
)

mermaid.detach(buffer)
refreshes = 0
process_requests = {}
mermaid.parse(context)
process_requests[1].callback({ code = 124, stderr = '', stdout = '' })
assert(
    vim.wait(100, function()
        return refreshes == 1
    end, 1),
    'Timed-out render did not settle'
)
assert(
    message_history():find('timed out after 4321 ms', 1, true),
    'Timeout without stderr was lost from :messages'
)

mermaid.detach(buffer)
process_requests = {}
assert(
    #mermaid.parse(context) == 0 and #process_requests == 1,
    'Expected preview test condition'
)
vim.api.nvim_buf_set_lines(buffer, 3, 4, false, { '  A --> Changed' })
local changed_tree = assert(
    vim.treesitter.get_parser(buffer, 'markdown'):parse()[1],
    'Expected preview test condition'
)
local changed_context = { buf = buffer, root = changed_tree:root() }
assert(
    #mermaid.parse(changed_context) == 0 and #process_requests == 2,
    'Expected preview test condition'
)
assert(
    killed_processes >= 1,
    'Editing Mermaid source did not cancel the stale renderer generation'
)
local history_before_stale = message_history()
process_requests[1].callback({
    code = 1,
    stderr = 'stale render failure',
    stdout = '',
})
vim.wait(20)
assert(refreshes == 1, 'A stale Mermaid callback requested another render')
assert(
    message_history() == history_before_stale,
    'A canceled render logged a stale error'
)

-- A source edit can arrive before the preview has reparsed the buffer.
vim.api.nvim_buf_set_lines(buffer, 3, 4, false, { '  A --> Newer' })
process_requests[2].callback({
    code = 1,
    stderr = 'failure before reparse',
    stdout = '',
})
vim.wait(20)
assert(
    message_history() == history_before_stale,
    'An edited source logged an obsolete render error'
)

mermaid.detach(buffer)
process_requests = {}
for _, view in ipairs({
    { width = 48, gap = '1', padding = '1' },
    { width = 100, gap = '2', padding = '2' },
    { width = 160, gap = '3', padding = '2' },
    { width = 240, gap = '4', padding = '2' },
}) do
    mermaid.parse({
        buf = buffer,
        root = changed_tree:root(),
        width = view.width,
    })
    local resized_request = process_requests[#process_requests]
    assert(
        tonumber(resized_request.command[3]) == math.floor(view.width * 0.85)
            and resized_request.command[10] == view.gap
            and resized_request.command[12] == view.padding,
        'Mermaid resize did not recalculate its width and spacing budget'
    )
end
assert(
    #process_requests == 4,
    'Mermaid resize reused a render with stale dimensions'
)

local position_context =
    { buf = buffer, root = changed_tree:root(), width = 240 }
mermaid.arrow_position = 'middle'
mermaid.parse(position_context)
assert(
    #process_requests == 5,
    'Changing arrow placement reused the previous diagram'
)
local middle_request = process_requests[5]
assert(
    middle_request.command[#middle_request.command - 1] == '--arrow-position'
        and middle_request.command[#middle_request.command] == 'middle',
    'Mermaid did not forward the middle arrow placement choice'
)
mermaid.parse(position_context)
assert(
    #process_requests == 5,
    'Unchanged arrow placement bypassed the render cache'
)
mermaid.arrow_position = 'end'
mermaid.parse(position_context)
assert(
    #process_requests == 6
        and not vim.tbl_contains(
            process_requests[6].command,
            '--arrow-position'
        ),
    'Returning to endpoint arrows retained the middle placement option'
)
middle_request.callback({ code = 0, stdout = 'stale middle arrows' })
vim.wait(20)
assert(refreshes == 1, 'A stale arrow-placement callback requested a render')

mermaid.detach(buffer)
vim.api.nvim_buf_delete(buffer, { force = true })

local budget_buffer, budget_context = fixture({
    '```mermaid',
    'graph LR',
    'A --> B',
    '```',
    '```mermaid',
    'graph LR',
    'C --> D',
    '```',
    '```mermaid',
    'graph LR',
    'E --> F',
    '```',
})
process_requests = {}
mermaid.max_concurrent = 2
assert(#mermaid.parse(budget_context) == 0, 'Expected preview test condition')
assert(
    #process_requests == 2,
    'Mermaid render concurrency exceeded or failed to fill its two-job budget'
)
process_requests[1].callback({
    code = 0,
    stdout = styled_output({
        {
            { text = 'first', style = 'label' },
        },
    }),
})
assert(
    vim.wait(100, function()
        return #process_requests == 3
    end, 1),
    'Mermaid render queue did not start the next bounded job'
)

mermaid.detach(budget_buffer)
vim.api.nvim_buf_delete(budget_buffer, { force = true })

-- Content identities survive prose edits and movement, including completions
-- that arrive before the edited document is projected again.
local incremental_buffer = fixture({
    'Prose',
    '',
    '```mermaid',
    'graph LR',
    'A --> B',
    '```',
    '',
    '```mermaid',
    'graph LR',
    'C --> D',
    '```',
    '',
    'Tail',
})
process_requests = {}
local function project_incremental()
    local current_tree = assert(
        vim.treesitter.get_parser(incremental_buffer, 'markdown'):parse()[1],
        'Expected preview test condition'
    )
    return mermaid.project({
        buf = incremental_buffer,
        root = current_tree:root(),
        width = 100,
    })
end
local initial_tree = assert(
    vim.treesitter.get_parser(incremental_buffer, 'markdown'):parse()[1],
    'Expected preview test condition'
)
local reserved_diagrams, layout_tasks = mermaid.layout({
    buf = incremental_buffer,
    root = initial_tree:root(),
    width = 100,
})
assert(
    #process_requests == 0
        and #reserved_diagrams == 2
        and reserved_diagrams[1].layout.estimated
        and reserved_diagrams[1].layout.height == #reserved_diagrams[1].rows,
    'Provider layout started rendering before returning a measured reservation'
)
local frame_committed = false
markdown_features.dispatch(layout_tasks, function()
    return frame_committed
end)
frame_committed = true
assert(
    vim.wait(100, function()
        return #process_requests == 2
    end, 1),
    'Committed layout did not dispatch diagram jobs'
)
assert(
    #process_requests == 2,
    'Incremental fixture did not queue both diagrams'
)
local kills_before_prose = killed_processes
vim.api.nvim_buf_set_lines(
    incremental_buffer,
    0,
    1,
    false,
    { 'Changed prose while rendering' }
)
local refreshes_before_completion = refreshes
process_requests[1].callback({ code = 0, stdout = 'first diagram' })
process_requests[2].callback({ code = 0, stdout = 'second diagram' })
assert(
    vim.wait(100, function()
        return refreshes == refreshes_before_completion + 2
    end, 1),
    'Unrelated edits discarded in-flight Mermaid results'
)
local initial_diagrams = project_incremental()
assert(
    #initial_diagrams == 2
        and #process_requests == 2
        and killed_processes == kills_before_prose,
    'Prose-only edits canceled or restarted diagram jobs'
)
vim.api.nvim_buf_set_lines(
    incremental_buffer,
    0,
    0,
    false,
    { 'Inserted before diagrams' }
)
local moved_diagrams = project_incremental()
assert(
    #process_requests == 2
        and moved_diagrams[2].start_row == initial_diagrams[2].start_row + 1
        and moved_diagrams[2].rows[2].source_row == initial_diagrams[2].rows[2].source_row + 1
        and moved_diagrams[2].rows[2].chunks
            == initial_diagrams[2].rows[2].chunks,
    'Moving a Mermaid block rerendered it or lost its source mapping'
)
vim.api.nvim_buf_set_lines(incremental_buffer, 5, 6, false, { 'A --> Changed' })
local pending_diagrams = project_incremental()
assert(
    #process_requests == 3
        and #pending_diagrams == 2
        and pending_diagrams[2].rows[2].chunks
            == initial_diagrams[2].rows[2].chunks,
    'Editing one diagram invalidated the other diagram'
)
assert(
    pending_diagrams[1].pending
        and pending_diagrams[1].layout.estimated
        and pending_diagrams[1].layout.height == initial_diagrams[1].layout.height
        and pending_diagrams[1].rows[2].chunks[1][1]
            == initial_diagrams[1].rows[2].chunks[1][1],
    'Updating a diagram lost its last completed canvas or reserved height'
)
process_requests[3].callback({ code = 0, stdout = 'updated first diagram' })
assert(
    vim.wait(100, function()
        return not mermaid.stage(incremental_buffer)[1].pending
    end, 1),
    'Changed diagram did not settle alongside its cached neighbor'
)
vim.api.nvim_buf_set_lines(incremental_buffer, 8, 12, false, {})
assert(
    #project_incremental() == 1 and #process_requests == 3,
    'Deleted diagram retained a stale projection'
)
local before_resize = project_incremental()[1]
local resize_tree = assert(
    vim.treesitter.get_parser(incremental_buffer, 'markdown'):parse()[1],
    'Expected preview test condition'
)
local resized_reservations, resize_tasks = mermaid.layout({
    buf = incremental_buffer,
    root = resize_tree:root(),
    width = 50,
})
assert(
    resized_reservations[1].pending
        and resized_reservations[1].layout.basis == 'scaled'
        and resized_reservations[1].layout.height > before_resize.layout.height
        and #process_requests == 3,
    'Narrowing the pane did not reserve scaled cached geometry before dispatch'
)
local baseline_scale = { width = 80, height = 11, source = 'graph LR\nA --> B' }
local scaled_layout =
    mermaid.estimate_layout(baseline_scale.source, 40, baseline_scale)
local replaced_layout = mermaid.estimate_layout(
    string.rep('Entirely different document\n', 20),
    40,
    baseline_scale
)
assert(
    scaled_layout.height == 21
        and scaled_layout.basis == 'scaled'
        and replaced_layout.height == 11
        and replaced_layout.basis == 'previous',
    'Large replacements speculatively scaled the last measured height'
)
vim.api.nvim_buf_set_lines(
    incremental_buffer,
    5,
    6,
    false,
    { string.rep('A --> EntirelyNewNode; ', 30) }
)
local replacement_tree = assert(
    vim.treesitter.get_parser(incremental_buffer, 'markdown'):parse()[1],
    'Expected preview test condition'
)
local replacement_layout = mermaid.layout({
    buf = incremental_buffer,
    root = replacement_tree:root(),
    width = 50,
})
assert(
    replacement_layout[1].layout.basis == 'previous'
        and replacement_layout[1].layout.height == before_resize.layout.height
        and #process_requests == 3,
    'A large diagram replacement did not retain its last completed dimensions'
)
vim.api.nvim_buf_set_lines(incremental_buffer, 5, 6, false, { 'A --> Newer' })
markdown_features.dispatch(resize_tasks, function()
    return true
end)
vim.wait(20)
assert(
    #process_requests == 3,
    'Stale layout dispatched work for an obsolete source revision'
)
local function layout_incremental()
    local current_tree = assert(
        vim.treesitter.get_parser(incremental_buffer, 'markdown'):parse()[1],
        'Expected preview test condition'
    )
    return mermaid.layout({
        buf = incremental_buffer,
        root = current_tree:root(),
        width = 50,
    })
end
local _, newer_tasks = layout_incremental()
markdown_features.dispatch(newer_tasks, function()
    return true
end)
assert(
    vim.wait(100, function()
        return #process_requests == 4
    end, 1),
    'Expected preview test condition'
)
vim.api.nvim_buf_set_lines(incremental_buffer, 5, 6, false, { 'A --> Newest' })
process_requests[4].callback({ code = 0, stdout = 'obsolete result' })
vim.wait(20)
assert(
    #process_requests == 4,
    'A stale completion launched replacement work before the next layout commit'
)
local _, newest_tasks = layout_incremental()
markdown_features.dispatch(newest_tasks, function()
    return true
end)
assert(
    vim.wait(100, function()
        return #process_requests == 5
    end, 1),
    'Expected preview test condition'
)
mermaid.detach(incremental_buffer)
renderer_available = false
local unavailable_layout, unavailable_tasks = layout_incremental()
assert(
    #unavailable_layout == 0 and #unavailable_tasks == 0,
    'An unavailable optional renderer reserved rows or queued work'
)
markdown_features.dispatch(unavailable_tasks, function()
    return true
end)
assert(
    vim.wait(100, function()
        return #mermaid.stage(incremental_buffer) == 0
    end, 1),
    'Unavailable renderer left a permanent loading reservation'
)
mermaid.detach(incremental_buffer)
vim.api.nvim_buf_delete(incremental_buffer, { force = true })
mermaid.find_executable = original.find_executable
mermaid.max_concurrent = original.max_concurrent
mermaid.start_process = original.start_process
mermaid.timeout_ms = original.timeout
mermaid.width_ratio = original.width_ratio
mermaid.arrow_position = original.arrow_position
markdown_features.request_render = original.feature_request_render
vim.o.guicursor = original.guicursor
vim.api.nvim_set_current_buf(original.buffer)

local decoded_scope_roles = assert(
    mermaid.decode_styled_output(
        styled_output({
            {
                { text = '[par]', style = 'subgraph_label' },
                { text = '│', style = 'subgraph' },
                { text = 'strong', style = 'bold_label' },
            },
        }),
        20
    ),
    'Expected preview test condition'
)
assert(
    decoded_scope_roles[1].chunks[1][2] == 'RenderMarkdownMermaidSubgraphLabel'
        and decoded_scope_roles[1].chunks[2][2] == 'RenderMarkdownMermaidSubgraph'
        and decoded_scope_roles[1].chunks[3][2]
            == 'RenderMarkdownMermaidBoldLabel',
    'Scope hints and explicit bold labels lost their separate semantic roles'
)
