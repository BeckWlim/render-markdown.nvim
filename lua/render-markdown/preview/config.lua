local M = {}

---@class (exact) render.md.preview.Config
---@field enabled boolean
---@field auto_open boolean
---@field mermaid render.md.preview.mermaid.Config

---@class (exact) render.md.preview.mermaid.Config
---@field enabled boolean
---@field command string
---@field arrow_position 'end'|'middle'

---@type render.md.preview.Config
M.default = {
    enabled = true,
    auto_open = true,
    mermaid = {
        enabled = true,
        command = 'termaid',
        arrow_position = 'end',
    },
}

---@return render.md.Schema
function M.schema()
    return {
        record = {
            enabled = { type = 'boolean' },
            auto_open = { type = 'boolean' },
            mermaid = {
                record = {
                    enabled = { type = 'boolean' },
                    command = { type = 'string' },
                    arrow_position = { enum = { 'end', 'middle' } },
                },
            },
        },
    }
end

return M
