-- Run with: nvim --headless -u NONE -i NONE -l tests/preview/run.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.getcwd() .. '/after')

for _, path in ipairs({
    'tests/preview/features.lua',
    'tests/preview/table/cells.lua',
    'tests/preview/table/rendering.lua',
}) do
    dofile(path)
end
vim.api.nvim_out_write('Projection and table tests passed\n')
