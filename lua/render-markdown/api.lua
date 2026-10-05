---@class render.md.render.Context
---@field buf integer
---@field win? integer|integer[]
---@field event? string
---@field config? render.md.partial.UserConfig

---@class render.md.Api
local M = {}

---@param ctx render.md.render.Context
function M.render(ctx)
    local env = require('render-markdown.lib.env')
    local list = require('render-markdown.lib.list')
    local state = require('render-markdown.state')
    local ui = require('render-markdown.core.ui')

    local buf = ctx.buf
    local wins = list.ensure(ctx.win or env.buf.wins(buf))
    local event = ctx.event or 'Api'

    state.get(buf, ctx.config)
    state.attach()

    for _, win in ipairs(wins) do
        ui.update(buf, win, event, true)
    end
end

---@return boolean
function M.get()
    return require('render-markdown.state').enabled
end

---@param enable? boolean
function M.set(enable)
    require('render-markdown.core.manager').set(enable)
end

---@param enable? boolean
function M.set_buf(enable)
    require('render-markdown.core.manager').set_buf(nil, enable)
end

function M.enable()
    M.set(true)
end

function M.buf_enable()
    M.set_buf(true)
end

function M.disable()
    M.set(false)
end

function M.buf_disable()
    M.set_buf(false)
end

function M.toggle()
    M.set()
end

function M.buf_toggle()
    M.set_buf()
end

function M.preview()
    require('render-markdown.preview').toggle()
end

---Canonical buffer identity for a source file or its projected display.
---@param buf? integer
---@return integer?
function M.source_buffer(buf)
    local buffer = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
    if not vim.api.nvim_buf_is_valid(buffer) then return end
    local projected = package.loaded['render-markdown.preview']
    local source = projected and projected.get(buffer)
    return source or buffer
end

---Source buffer and position under a projected preview cursor.
---@param win? integer
---@return integer?, integer[]?
function M.source_location(win)
    local projected = package.loaded['render-markdown.preview']
    if projected then
        local window = (win == nil or win == 0)
                and vim.api.nvim_get_current_win()
            or win
        return projected.source_location(window)
    end
end

---Map a source position into the generated preview rows.
---@param win integer
---@param position integer[]
---@return integer[]?
function M.display_position(win, position)
    local projected = package.loaded['render-markdown.preview']
    if projected then
        local window = win == 0 and vim.api.nvim_get_current_win() or win
        return projected.display_position(window, position)
    end
end

---Resolve a source-aware context in ordinary or projected buffers.
---Positions use one-based rows / zero-based bytes; ranges are half-open.
---@param win? integer
---@return render.md.interaction.Context?
function M.interaction(win)
    return require('render-markdown.preview.interaction').context(win)
end

---Cooperatively route a plugin operation to the source or displayed buffer.
---Async operations must call token:finish() or token:cancel().
---@param operation render.md.interaction.Operation
---@param opts? {window?: integer}
function M.dispatch(operation, opts)
    return require('render-markdown.preview.interaction').dispatch(operation, opts)
end

---Create a callback for user keymaps, commands, or plugin hooks.
---Invocation arguments follow context/token; returns match dispatch().
---@param operation render.md.interaction.Operation
---@param opts? {window?: integer}
---@return function
function M.wrap(operation, opts)
    return require('render-markdown.preview.interaction').wrap(operation, opts)
end

---Select a source syntax node without depending on a navigation plugin.
---Set options.preview = true to retain the selection in the projected view.
---@param index? integer Smallest source node is 1.
---@param opts? {window?: integer, preview?: boolean}
function M.select_node(index, opts)
    return require('render-markdown.preview.interaction').select_node(index, opts)
end

---Resolve an inline link from the original source under the rendered cursor.
---@param win? integer
---@return table?
function M.link_at_cursor(win)
    local context = M.interaction(win)
    return context and context:link() or nil
end

---Restore source before another UI takes over the window.
function M.leave_preview()
    local projected = package.loaded['render-markdown.preview']
    if projected then
        projected.leave()
    end
end

function M.log()
    require('render-markdown.core.log').open()
end

function M.expand()
    require('render-markdown.state').modify_anti_conceal(1)
    M.enable()
end

function M.contract()
    require('render-markdown.state').modify_anti_conceal(-1)
    M.enable()
end

function M.debug()
    require('render-markdown.debug.marks').show()
end

function M.config()
    local difference = require('render-markdown.state').difference()
    if not difference then
        -- selene: allow(deprecated)
        vim.print('default configuration')
    else
        -- selene: allow(deprecated)
        vim.print(difference)
    end
end

return M
