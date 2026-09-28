local markdown_table = require('render-markdown.preview.table')
local buffer = vim.api.nvim_create_buf(false, true)
local source_lines = {
    '| heading | description |',
    '|---|---|',
    '| `Enter` | alpha bravo charlie delta echo foxtrot golf hotel india juliet |',
}
vim.api.nvim_buf_set_lines(buffer, 0, -1, false, source_lines)
local tree = assert(
    vim.treesitter.get_parser(buffer, 'markdown'):parse()[1],
    'Expected preview test condition'
)
local blocks =
    markdown_table.project({ buf = buffer, root = tree:root(), width = 27 })
assert(
    #blocks == 1 and blocks[1].start_row == 0 and blocks[1].end_row == 3,
    'Table projection lost its source range'
)
local feature_rows = blocks[1].rows
local chunks_width = require('render-markdown.preview.features').chunks_width
assert(
    chunks_width(feature_rows[1].chunks)
        == chunks_width(feature_rows[#feature_rows].chunks),
    'Table title does not span the full table background'
)
assert(
    feature_rows[1].chunks[1][2] == 'RenderMarkdownTableIcon'
        and feature_rows[1].chunks[2][2] == 'RenderMarkdownTableLabel'
        and feature_rows[1].chunks[#feature_rows[1].chunks][2]
            == 'RenderMarkdownTableLabel',
    'Table title or its padding lost semantic highlights'
)
local continuations = 0
local styled_code = false
local mapped_tail = false
for _, row in ipairs(blocks[1].rows) do
    local parts = {}
    for _, chunk in ipairs(row.chunks) do
        parts[#parts + 1] = chunk[1]
        styled_code = styled_code or chunk[2] == 'RenderMarkdownTableCode'
    end
    local text = table.concat(parts)
    assert(vim.trim(text) ~= '', 'Table projection reserved a blank source row')
    assert(
        vim.fn.strdisplaywidth(text) <= 27,
        'Table cell layout exceeded its own width'
    )
    if row.source_row == 2 and row.spans then
        continuations = continuations + 1
    end
    for _, span in ipairs(row.spans or {}) do
        mapped_tail = mapped_tail or span.source_column > 40
    end
end
assert(
    continuations > 1 and styled_code and mapped_tail,
    'Table lost wrapped cells, code styling, or source offsets'
)
assert(
    vim.deep_equal(
        vim.api.nvim_buf_get_lines(buffer, 0, -1, false),
        source_lines
    ),
    'Rendering changed table source'
)
local cache = {}
local cached_blocks = markdown_table.project({
    buf = buffer,
    root = tree:root(),
    width = 27,
    cache = cache,
})
assert(
    markdown_table.project({
        buf = buffer,
        root = tree:root(),
        width = 27,
        cache = cache,
    }) == cached_blocks,
    'Unchanged tables are rebuilt when another feature completes'
)
local resized_blocks = markdown_table.project({
    buf = buffer,
    root = tree:root(),
    width = 60,
    cache = cache,
})
assert(resized_blocks ~= cached_blocks, 'Table cache ignored the pane width')
vim.api.nvim_buf_set_lines(buffer, 2, 3, false, { '| changed | value |' })
local edited_tree = vim.treesitter.get_parser(buffer, 'markdown'):parse()[1]
assert(markdown_table.project({
    buf = buffer,
    root = edited_tree:root(),
    width = 60,
    cache = cache,
}) ~= resized_blocks, 'Table cache ignored source edits')
vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
    'Before',
    '',
    '| One | Value |',
    '|---|---|',
    '| first | value |',
    '',
    '| Two | Value |',
    '|---|---|',
    '| second | value |',
    '',
    'After',
})
local function project_tables(width)
    local current_tree = assert(
        vim.treesitter.get_parser(buffer, 'markdown'):parse()[1],
        'Expected preview test condition'
    )
    return markdown_table.project({
        buf = buffer,
        root = current_tree:root(),
        width = width,
        cache = cache,
    })
end
local initial_tables = project_tables(60)
vim.api.nvim_buf_set_lines(buffer, 0, 1, false, { 'Updated prose' })
local prose_tables = project_tables(60)
assert(
    prose_tables[1] == initial_tables[1]
        and prose_tables[2] == initial_tables[2],
    'Prose-only edits rebuilt table objects'
)
vim.api.nvim_buf_set_lines(buffer, 4, 5, false, { '| updated first | value |' })
local changed_tables = project_tables(60)
assert(
    changed_tables[1] ~= initial_tables[1]
        and changed_tables[2] == initial_tables[2],
    'Editing one table invalidated the other table'
)
vim.api.nvim_buf_set_lines(buffer, 0, 0, false, { 'Inserted above' })
local moved_tables = project_tables(60)
assert(
    moved_tables[2].start_row == changed_tables[2].start_row + 1
        and moved_tables[2].rows[2].source_row == changed_tables[2].rows[2].source_row + 1
        and moved_tables[2].rows[2].chunks
            == changed_tables[2].rows[2].chunks,
    'An insertion above a table rebuilt its content or lost its source mapping'
)
local wider_tables = project_tables(90)
assert(
    wider_tables[1].rows[2].chunks ~= moved_tables[1].rows[2].chunks
        and wider_tables[2].rows[2].chunks ~= moved_tables[2].rows[2].chunks,
    'Resizing reused table layouts for the old width'
)
local emphasized_source = {
    '| **Key** | *Value* |',
    '|---|---|',
    '| **alpha beta** | ~~gone~~ |',
}
vim.api.nvim_buf_set_lines(buffer, 0, -1, false, emphasized_source)
local emphasized_blocks = project_tables(18)
local bold_fragments = 0
for _, row in ipairs(emphasized_blocks[1].rows) do
    local parts = {}
    for _, chunk in ipairs(row.chunks) do
        parts[#parts + 1] = chunk[1]
        if
            row.source_row == 2
            and type(chunk[2]) == 'table'
            and vim.tbl_contains(chunk[2], 'RenderMarkdownTableBold')
        then
            bold_fragments = bold_fragments + 1
        end
    end
    local rendered_text = table.concat(parts)
    assert(not rendered_text:find('[*~]'), 'Table retained emphasis markers')
    for _, span in ipairs(row.spans or {}) do
        local source_text = emphasized_source[row.source_row + 1]
        assert(
            rendered_text:sub(span.first + 1, span.last)
                == source_text:sub(
                    span.source_column + 1,
                    span.source_column + span.last - span.first
                ),
            'Emphasized table character maps to the wrong source byte'
        )
    end
end
assert(bold_fragments == 2, 'Table lost bold styling on wrapped content')
vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
    '| Key | Value |',
    '|---|---|',
    '| alpha beta | gone |',
})
local plain_blocks = project_tables(18)
assert(
    vim.deep_equal(emphasized_blocks[1].layout, plain_blocks[1].layout),
    'Concealed emphasis markers changed table dimensions'
)
vim.api.nvim_buf_delete(buffer, { force = true })
