-- Run with: nvim --headless -u NONE -i NONE -l tests/preview/run.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.getcwd() .. '/after')
vim.o.hidden = true
vim.api.nvim_buf_set_name(0, 'preview-test-origin')

for _, path in ipairs({
    'tests/preview/features.lua',
    'tests/preview/table/cells.lua',
    'tests/preview/table/rendering.lua',
    'tests/preview/mermaid.lua',
    'tests/preview/jumps.lua',
    'tests/preview/preview.lua',
    'tests/preview/api.lua',
}) do
    dofile(path)
end
vim.api.nvim_out_write('Projected preview tests passed\n')
