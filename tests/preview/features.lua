local features = require('render-markdown.preview.features')
local buffer = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(
    buffer,
    0,
    -1,
    false,
    { 'before', 'table source', 'mermaid source', 'after' }
)
local rows = features.project({
    {
        project = function()
            return {
                {
                    start_row = 1,
                    end_row = 2,
                    rows = {
                        {
                            chunks = { { 'wrapped first', 'Normal' } },
                            source_row = 1,
                            spans = {
                                { first = 0, last = 7, source_column = 0 },
                            },
                        },
                        {
                            chunks = { { 'wrapped second', 'Normal' } },
                            source_row = 1,
                            spans = {
                                { first = 0, last = 7, source_column = 6 },
                            },
                        },
                    },
                },
            }
        end,
    },
    {
        project = function()
            return {
                {
                    start_row = 2,
                    end_row = 3,
                    rows = {
                        {
                            chunks = { { 'diagram', 'Normal' } },
                            source_row = 2,
                        },
                    },
                },
            }
        end,
    },
}, { buf = buffer })
assert(
    #rows == 5 and rows[1].identity and rows[5].identity,
    'Shared projection lost surrounding prose'
)
assert(
    vim.deep_equal(features.source_position(rows[3], 2), { 2, 6 }),
    'Wrapped row lost its source byte mapping'
)
assert(
    vim.deep_equal(features.source_position(rows[5], 2), { 4, 2 }),
    'Prose source mapping changed its column'
)
assert(
    vim.deep_equal(features.preview_position(rows, 1, 6), { 3, 0 }),
    'Source navigation did not select the matching continuation'
)
local cached_objects = {}
local builds = 0
local function build_object()
    builds = builds + 1
    return { start_row = 1, end_row = 2, rows = { rows[2], rows[3] } }
end
local object_key = features.block_key('object', { 80 })
local original_object = assert(
    features.cached_projection(cached_objects, object_key, 1, build_object),
    'Expected preview test condition'
)
local moved_object = assert(
    features.cached_projection(cached_objects, object_key, 3, build_object),
    'Expected preview test condition'
)
assert(
    builds == 1
        and moved_object.start_row == 3
        and moved_object.end_row == 4
        and moved_object.rows[2].source_row == 3
        and original_object.rows[2].source_row == 1,
    'Moving an unchanged object rebuilt it or changed its cached source mapping'
)
assert(
    moved_object.rows[2].chunks == original_object.rows[2].chunks
        and moved_object.rows[2].spans == original_object.rows[2].spans,
    'Moving an unchanged object copied its rendered content'
)
assert(
    #features.changed_ranges(original_object.rows, moved_object.rows) == 0,
    'Source-only mapping changes invalidated the rendered buffer'
)
local changed_rows = vim.deepcopy(rows)
changed_rows[1].chunks = { { 'new before' } }
changed_rows[5].chunks = { { 'new after' } }
local changed_ranges = features.changed_ranges(rows, changed_rows)
assert(
    #changed_ranges == 2
        and changed_ranges[1].old_count == 1
        and changed_ranges[2].old_count == 1,
    'Separate prose edits included unchanged objects in the buffer patch'
)
local element_plan = features.plan_elements({
    { key = 'completed', start_row = 10 },
    { key = 'running' },
    { key = 'new' },
    { key = 'new' },
    { key = 'over limit' },
}, { completed = true, removed = true }, { running = true }, 3)
assert(
    element_plan.by_key.completed.start_row == 10
        and not element_plan.by_key.removed
        and not element_plan.by_key['over limit']
        and #element_plan.render == 1
        and element_plan.render[1].key == 'new',
    'Element plan rerendered cached/running objects, retained removed objects, or exceeded its budget'
)
local refreshes = 0
features.subscribe(buffer, function()
    refreshes = refreshes + 1
end)
features.request_render(buffer, 'table')
features.request_render(buffer, 'mermaid')
assert(
    vim.wait(100, function()
        return refreshes == 1
    end),
    'Feature refreshes were not coalesced'
)
features.request_render(buffer)
features.forget_buffer(buffer)
vim.wait(10)
assert(refreshes == 1, 'Closed preview accepted a stale refresh')
vim.api.nvim_buf_delete(buffer, { force = true })
