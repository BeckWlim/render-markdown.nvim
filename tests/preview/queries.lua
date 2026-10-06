local renderer = require('render-markdown')
local preview = require('render-markdown.preview')
local original = vim.api.nvim_get_current_buf()
local runtimepath = vim.o.runtimepath
local directory = vim.fn.tempname()
for index, path in ipairs({ directory, directory .. '/second', directory .. '/third' }) do
    vim.fn.mkdir(path .. '/queries/markdown', 'p')
    vim.fn.writefile({ '; extends', '; query replacement fixture ' .. index },
        path .. '/queries/markdown/highlights.scm')
end
renderer.setup({ preview = { auto_open = false, mermaid = { enabled = false } } })
local source = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(source)
vim.api.nvim_buf_set_lines(source, 0, -1, false, {
    '# Query lifecycle', 'ordinary prose', '', '```text', 'payload', '```',
})
vim.bo[source].filetype = 'markdown'
local display = preview.open(source)
local function concealed_lines(query)
    local count = 0
    local parser = vim.treesitter.get_parser(display, 'markdown')
    parser:parse(true)
    for _, tree in ipairs(parser:trees()) do
        for id, _, metadata in query:iter_captures(tree:root(), display) do
            if metadata.conceal_lines ~= nil
                or (metadata[id] or {}).conceal_lines ~= nil then
                count = count + 1
            end
        end
    end
    return count
end
local initial = assert(vim.treesitter.query.get('markdown', 'highlights'))
assert(concealed_lines(initial) == 0, 'Initial query hides the code language line')

-- Lazy-loading another plugin invalidates queries through runtimepath changes.
vim.opt.runtimepath:append(directory)
local replaced = assert(vim.treesitter.query.get('markdown', 'highlights'))
assert(replaced ~= initial and concealed_lines(replaced) > 0,
    'Runtime change did not replace the adjusted Markdown query')
vim.api.nvim_buf_set_lines(source, 1, 2, false, { 'unsaved prose edit' })
preview.refresh(source)
assert(concealed_lines(replaced) == 0,
    'Preview restarted its highlighter with a query hiding language labels')

-- Attachment after initialization must also prepare the new query instance.
vim.opt.runtimepath:append(directory .. '/second')
local attached = assert(vim.treesitter.query.get('markdown', 'highlights'))
assert(attached ~= replaced and concealed_lines(attached) > 0,
    'Second runtime change did not replace the adjusted query')
require('render-markdown.core.ts').init()
assert(concealed_lines(attached) == 0,
    'Repeated renderer attachment left the replacement query unprepared')

-- Preserve an explicit opt-out from the configured query adjustments.
renderer.setup({ patterns = { markdown = { disable = false } },
    preview = { auto_open = false, mermaid = { enabled = false } } })
vim.o.runtimepath = runtimepath
vim.opt.runtimepath:append(directory .. '/third')
display = preview.open(source)
local unadjusted = assert(vim.treesitter.query.get('markdown', 'highlights'))
assert(concealed_lines(unadjusted) > 0, 'Query preparation ignored the configured opt-out')
preview.toggle()
vim.api.nvim_set_current_buf(original)
vim.api.nvim_buf_delete(source, { force = true })
vim.o.runtimepath = runtimepath
vim.fn.delete(directory, 'rf')
renderer.setup({ preview = { auto_open = false, mermaid = { enabled = false } } })
