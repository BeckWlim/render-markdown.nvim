-- Exercise actual quit commands in child editors so successful exit is observable.
for _, scenario in ipairs({ 'clean', 'dirty', 'force', 'hidden' }) do
    local script = vim.fn.tempname() .. '.lua'
    local fixture = vim.fn.tempname() .. '.md'
    vim.fn.writefile({ '# Quit fixture', '', 'Original text' }, fixture)
    local setup = ([=[
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.hidden = true
require('render-markdown').setup({ preview = { enabled = true } })
vim.cmd.edit(%q)
local source = vim.api.nvim_get_current_buf()
vim.bo.filetype = 'markdown'
local preview = require('render-markdown.preview')
local rendered = preview.open(source)
assert(vim.api.nvim_buf_line_count(rendered) == 3)
]=]):format(fixture)
    if scenario ~= 'clean' then
        setup = setup .. [[
vim.api.nvim_buf_set_lines(source, 2, 3, false, { 'Unsaved edit' })
preview.refresh(source)
assert(vim.bo[rendered].modified)
]]
    end
    if scenario == 'dirty' then
        setup = setup .. [[
local ok, err = pcall(vim.cmd.quit)
assert(not ok and tostring(err):find('E37'), 'Plain quit discarded unsaved source edits')
assert(vim.api.nvim_get_current_buf() == source and vim.bo[source].modified)
assert(not vim.api.nvim_buf_is_valid(rendered), 'Quit retained the generated mirror')
vim.wait(50)
assert(vim.api.nvim_get_current_buf() == source, 'Queued callback reopened preview after failed quit')
vim.cmd('q!')
]]
    elseif scenario == 'hidden' then
        setup = setup .. "vim.cmd.enew()\nvim.cmd('qa!')\n"
    else
        setup = setup .. (scenario == 'force' and "vim.cmd('q!')\n" or "vim.cmd('q')\n")
    end
    setup = setup .. "error('Quit did not exit the editor')\n"
    vim.fn.writefile(vim.split(setup, '\n'), script)
    local result = vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE', '-l', script }, { text = true }):wait(5000)
    vim.fn.delete(script)
    vim.fn.delete(fixture)
    assert(result.code == 0, scenario .. ': ' .. (result.stderr or ''))
end
