local M = {}
local all_features = {
    require('render-markdown.preview.table'),
    require('render-markdown.preview.mermaid'),
}
local features = all_features

function M.setup(options)
    features = { all_features[1] }
    if options.mermaid.enabled then
        features[#features + 1] = all_features[2]
    end
    for key, value in pairs(options.mermaid) do
        if key ~= 'enabled' then
            all_features[2][key] = value
        end
    end
end

function M.project(context)
    return require('render-markdown.preview.features').project(
        features,
        context
    )
end

function M.detach(buffer)
    for _, feature in ipairs(all_features) do
        if feature.detach then
            feature.detach(buffer)
        end
    end
end

return M
