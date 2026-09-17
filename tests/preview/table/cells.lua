-- Focused cell allocation and wrapping tests for render-markdown.preview.table.
local markdown = require('render-markdown.preview.table')

local allocated_widths, gap_width = markdown.allocate_widths(80, 3)
assert(
    gap_width == 2,
    'Markdown table columns lost their restrained whitespace gap'
)
assert(
    allocated_widths[1] == 26
        and allocated_widths[2] == 25
        and allocated_widths[3] == 25,
    'Markdown table did not distribute available width evenly from the first column'
)
assert(
    allocated_widths[1] - allocated_widths[3] <= 1,
    'Markdown table columns differ by more than one display cell'
)

local compact_widths, compact_gap =
    markdown.allocate_widths(80, 3, { 8, 12, 5 })
assert(
    compact_gap == 2 and vim.deep_equal(compact_widths, { 8, 12, 5 }),
    'Markdown table stretched columns beyond their maximum visible content'
)
local redistributed_widths = markdown.allocate_widths(40, 3, { 5, 50, 30 })
assert(
    vim.deep_equal(redistributed_widths, { 5, 16, 15 }),
    'Markdown table did not redistribute unused short-column capacity fairly'
)

local wrapped_cell = markdown.wrap_cell(
    '[visible label](https://example.com/a/long/hidden/destination) followed by text',
    16
)
assert(
    vim.deep_equal(wrapped_cell, { 'visible label', 'followed by text' }),
    'Markdown table wrapping measured a concealed link destination or crossed its column'
)
assert(
    vim.deep_equal(markdown.wrap_cell('abcdefgh', 3), { 'abc', 'def', 'gh' }),
    'Markdown table did not split an over-width word inside its allocated column'
)
assert(
    vim.deep_equal(
        markdown.wrap_cell('![label](image.png) and a\\|b', 20),
        { 'label and a|b' }
    ),
    'Markdown table cursor mapping changed image labels or escaped pipes'
)
assert(
    markdown.cell_fragment('alpha beta gamma', 0, 5) == 1
        and markdown.cell_fragment('alpha beta gamma', 5, 5) == 1
        and markdown.cell_fragment('alpha beta gamma', 6, 5) == 2
        and markdown.cell_fragment('alpha beta gamma', 11, 5) == 3,
    'Markdown table cursor does not follow raw word offsets across wrapped fragments'
)
assert(
    markdown.cell_fragment('甲乙丙', 0, 2) == 1
        and markdown.cell_fragment('甲乙丙', 3, 2) == 2
        and markdown.cell_fragment('甲乙丙', 6, 2) == 3,
    'Markdown table cursor does not follow UTF-8 byte offsets across wrapped fragments'
)

local linked_cell = 'one [visible](hidden) tail'
local hidden_link_offset = assert(
    linked_cell:find('hidden', 1, true),
    'Expected preview test condition'
) - 1
local trailing_text_offset = assert(
    linked_cell:find('tail', 1, true),
    'Expected preview test condition'
) - 1
assert(
    markdown.cell_fragment(linked_cell, hidden_link_offset, 7) == 2
        and markdown.cell_fragment(linked_cell, trailing_text_offset, 7)
            == 3,
    'Markdown table cursor fragment counts concealed link syntax as visible text'
)

local inline_code_chunks = markdown.wrap_cell_chunks(
    'press `Enter` now',
    20,
    'RenderMarkdownTableCell'
)
assert(
    vim.deep_equal(inline_code_chunks, {
        {
            { 'press ', 'RenderMarkdownTableCell' },
            { 'Enter', 'RenderMarkdownTableCode' },
            { ' now', 'RenderMarkdownTableCell' },
        },
    }),
    'Markdown table dropped the inline-code key mark'
)
assert(
    vim.deep_equal(markdown.wrap_cell_chunks('`abcdef`', 3, 'Cell'), {
        { { 'abc', 'RenderMarkdownTableCode' } },
        { { 'def', 'RenderMarkdownTableCode' } },
    }),
    'Markdown table lost inline-code styling across a wrapped key mark'
)
assert(
    vim.deep_equal(markdown.wrap_cell_chunks('`Enter key`', 20, 'Cell'), {
        { { 'Enter key', 'RenderMarkdownTableCode' } },
    }),
    'Markdown table split one spaced inline-code mark into separate badges'
)
assert(
    vim.deep_equal(markdown.wrap_cell_chunks('`a\\|b`', 20, 'Cell'), {
        { { 'a|b', 'RenderMarkdownTableCode' } },
    }),
    'Markdown table cursor mapping changed escaped pipes in inline code'
)

local snapshot_key =
    '/oplog/<cluster>/snapshot/{maintenance,latest,fallback,compaction_floor}'
local snapshot_key_chunks = markdown.wrap_cell_chunks(
    '`' .. snapshot_key .. '`',
    24,
    'RenderMarkdownTableCell'
)
local snapshot_key_parts = {}
for _, wrapped_key_line in ipairs(snapshot_key_chunks) do
    for _, wrapped_key_chunk in ipairs(wrapped_key_line) do
        assert(
            wrapped_key_chunk[2] == 'RenderMarkdownTableCode',
            'wrapped snapshot key contains an unbadged fragment'
        )
        snapshot_key_parts[#snapshot_key_parts + 1] = wrapped_key_chunk[1]
    end
end
assert(
    table.concat(snapshot_key_parts) == snapshot_key,
    'wrapped snapshot key lost visible content'
)
