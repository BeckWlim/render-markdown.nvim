local map = require('render-markdown.preview.projection')
local rows = {
    { chunks = { { 'one 两🙂' } }, source_row = 0, identity = true },
    { chunks = { { '  两  tail' } }, source_row = 2, spans = {
        { first = 2, last = 5, source_column = 4, source_end = 7 },
        { first = 7, last = 11, source_column = 12, source_end = 16 },
    } },
    { chunks = { { '  next' } }, source_row = 2, spans = {
        { first = 2, last = 6, source_column = 20, source_end = 24 },
    } },
    { chunks = { { 'border' } }, source_row = 3 },
    { chunks = { { '|' } }, source_row = 4, spans = {
        { first = 0, last = 1, source_column = 8, source_end = 10 },
    } },
}
local point, quality = map.to_source(rows, { 2, 2 })
assert(vim.deep_equal(point, { 3, 4 }) and quality == 'exact', 'UTF-8 cell lost byte mapping')
point, quality = map.to_source(rows, { 2, 0 })
assert(quality == 'anchor', 'Padding claimed an exact source byte')
point, quality = map.to_source(rows, { 5, 0 })
assert(quality == 'anchor', 'Escaped pipe claimed an exact mapping')
point, quality = map.to_display(rows, { 3, 22 })
assert(vim.deep_equal(point, { 3, 4 }) and quality == 'exact', 'Wrapped cell did not map back')
local fragments = map.display_ranges(rows, { start = { 3, 4 }, finish = { 3, 24 } })
assert(#fragments == 3 and fragments[3].start[1] == 3, 'Range lost wrapped fragments')
local range
range, quality = map.source_range(rows, { start = { 2, 2 }, finish = { 3, 4 } })
assert(range and quality == 'anchor', 'Generated interval claimed contiguous source text')
range, quality = map.source_range(rows, { start = { 1, 0 }, finish = { 1, 4 } })
assert(range and quality == 'exact', 'Identity range lost exact mapping')
point, quality = map.to_source(rows, { 99, 0 })
assert(not point and quality == 'unmapped', 'Invalid row mapped to arbitrary source')
