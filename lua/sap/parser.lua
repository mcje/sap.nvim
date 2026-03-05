local M = {}

---@class ParsedEntry
---@field id integer?
---@field path string -- intended path
---@field name string
---@field type "file"|"directory"
---@field indent integer
---@field linenr integer

--- Parse a single buffer line
---@param line string
---@return integer? id
---@return integer indent
---@return string name
---@return "file"|"directory" type
function M.parse_line(line)
    local id, rest = line:match("^///(%d+):(.*)$")
    local ftype = line:match("/$") and "directory" or "file"

    if not id then
        rest = line
    else
        id = tonumber(id)
    end

    local indent = rest:match("^(%s*)") or ""
    local name = rest:gsub("^%s*", ""):gsub("/$", "")
    return id, #indent, name, ftype
end

--- Parse entire buffer into entries with intended paths
---@param bufnr integer
---@param root_path string
---@return ParsedEntry[]
function M.parse_buffer(bufnr, root_path)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local result = {}

    -- Stack tracks parent directories: { path, indent }
    local stack = { { path = root_path, indent = -1 } }

    for i, line in ipairs(lines) do
        if line ~= "" then
            local id, indent, name, ftype = M.parse_line(line)

            if name ~= "" then
                local intended_path

                -- First entry at indent 0 is the root itself
                if indent == 0 and #result == 0 then
                    -- Calculate path based on parent of root (allows renaming root)
                    local root_parent = vim.fs.dirname(root_path)
                    if root_parent == "/" then
                        intended_path = "/" .. name
                    else
                        intended_path = root_parent .. "/" .. name
                    end
                    stack = { { path = intended_path, indent = 0 } }
                else
                    -- Pop stack until we find parent (indent < current)
                    while #stack > 1 and stack[#stack].indent >= indent do
                        table.remove(stack)
                    end

                    local parent_path = stack[#stack].path
                    intended_path = parent_path .. "/" .. name

                    -- Directories can be parents for subsequent lines
                    if ftype == "directory" then
                        stack[#stack + 1] = { path = intended_path, indent = indent }
                    end
                end

                result[#result + 1] = {
                    id = id,
                    path = intended_path,
                    name = name,
                    type = ftype,
                    indent = indent,
                    linenr = i,
                }
            end
        end
    end

    return result
end

return M
