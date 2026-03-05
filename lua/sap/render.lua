local config = require("sap.config")
local parser = require("sap.parser")

local M = {}

local ns = vim.api.nvim_create_namespace("sap")

-- Lazy reference to avoid circular dependency
local function get_buffer_state(bufnr)
    local ok, buffer = pcall(require, "sap.buffer")
    if ok and buffer.states then
        return buffer.states[bufnr]
    end
    return nil
end

local function get_indent_size()
    return config.options.indent_size or 4
end

local function get_indent()
    return string.rep(" ", get_indent_size())
end

--- Setup highlight groups
function M.setup_highlights()
    vim.api.nvim_set_hl(0, "SapDirectory", { link = "Directory", default = true })
    vim.api.nvim_set_hl(0, "SapFile", { link = "Normal", default = true })
    vim.api.nvim_set_hl(0, "SapLink", { link = "Constant", default = true })
    vim.api.nvim_set_hl(0, "SapExecutable", { link = "String", default = true })
    vim.api.nvim_set_hl(0, "SapHidden", { link = "Comment", default = true })
    vim.api.nvim_set_hl(0, "SapError", { link = "DiagnosticError", default = true })
end

--- Get icon and highlight for an entry
---@param entry table  -- Entry or entry-like table with name, type, hidden, stat
---@param state State
---@param icons_cfg table
---@return string? icon
---@return string? icon_hl
---@return string name_hl
local function get_icon_and_hl(entry, state, icons_cfg)
    local has_devicons, devicons = pcall(require, "nvim-web-devicons")

    local icon, icon_hl
    if icons_cfg.use_devicons and has_devicons then
        if entry.type == "directory" then
            icon, icon_hl = devicons.get_icon(entry.name, nil, { default = false })
        else
            local ext = entry.name:match("%.(%w+)$")
            icon, icon_hl = devicons.get_icon(entry.name, ext, { default = true })
        end
    end

    icon = icon or (entry.type == "directory" and icons_cfg.directory or icons_cfg.file)
    icon_hl = icon_hl or (entry.type == "directory" and "SapDirectory" or "SapFile")

    -- Name highlight priority: hidden > link > dir > exec > file
    local name_hl
    if entry.hidden then
        name_hl = "SapHidden"
    elseif entry.type == "link" then
        name_hl = "SapLink"
    elseif entry.type == "directory" then
        name_hl = "SapDirectory"
    elseif entry.stat and state:is_exec(entry) then
        name_hl = "SapExecutable"
    else
        name_hl = "SapFile"
    end

    return icon, icon_hl, name_hl
end

--- Setup decoration provider for icons and highlights
function M.setup_decoration_provider()
    vim.api.nvim_set_decoration_provider(ns, {
        on_line = function(_, _, bufnr, row)
            local state = get_buffer_state(bufnr)
            if not state then
                return
            end

            local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
            if not line or line == "" then
                return
            end

            local id, indent, name, ftype = parser.parse_line(line)
            if not name or name == "" then
                return
            end

            -- Calculate column after prefix
            local prefix_len = id and #string.format("///%d:", id) or 0
            local col = prefix_len + indent

            -- Get entry info from state
            local entry = id and state:get_by_id(id)
            local hidden = name:sub(1, 1) == "."

            local entry_like = {
                name = name,
                type = ftype,
                hidden = hidden,
                stat = entry and entry.stat,
            }

            local icons_cfg = config.options.icons
            local icon, icon_hl, name_hl = get_icon_and_hl(entry_like, state, icons_cfg)
            local suffix = ftype == "directory" and "/" or ""

            -- Icon (inline virtual text, ephemeral)
            if icon and icon ~= "" then
                vim.api.nvim_buf_set_extmark(bufnr, ns, row, col, {
                    virt_text = { { icon .. " ", icon_hl } },
                    virt_text_pos = "inline",
                    ephemeral = true,
                })
            end

            -- Name highlight (ephemeral)
            vim.api.nvim_buf_set_extmark(bufnr, ns, row, col, {
                end_col = col + #name + #suffix,
                hl_group = name_hl,
                ephemeral = true,
            })
        end,
    })
end

---@class FlatEntry
---@field entry Entry
---@field depth integer

--- Flatten state into ordered list for rendering
---@param state State
---@return FlatEntry[]
function M.flatten(state)
    local result = {}

    -- Add root as first entry (depth 0)
    local root_entry = state:get_by_path(state.root_path)
    if root_entry then
        result[#result + 1] = {
            entry = root_entry,
            depth = 0,
        }
    end

    local function visit(parent_path, depth)
        for _, entry in ipairs(state:get_children(parent_path)) do
            result[#result + 1] = {
                entry = entry,
                depth = depth,
            }

            if entry.type == "directory" and state:is_expanded(entry) then
                visit(entry.path, depth + 1)
            end
        end
    end

    visit(state.root_path, 1)
    return result
end

--- Convert flat entries to buffer lines
---@param entries FlatEntry[]
---@return string[]
function M.to_lines(entries)
    local lines = {}
    local indent_str = get_indent()
    for _, e in ipairs(entries) do
        local indent = string.rep(indent_str, e.depth)
        local suffix = e.entry.type == "directory" and "/" or ""
        -- Entries without ID are new (pending creates)
        local prefix = e.entry.id and string.format("///%d:", e.entry.id) or ""
        lines[#lines + 1] = prefix .. indent .. e.entry.name .. suffix
    end
    return lines
end

--- Convert entry-like objects to buffer lines at a given indent level
--- Used for in-place expansion (not full re-render)
---@param children table[] -- Entry or entry-like objects with id, name, type
---@param indent_level integer
---@return string[]
function M.entries_to_lines(children, indent_level)
    local lines = {}
    local indent_str = get_indent()
    local indent = string.rep(indent_str, indent_level)
    for _, child in ipairs(children) do
        local suffix = child.type == "directory" and "/" or ""
        local prefix = child.id and string.format("///%d:", child.id) or ""
        lines[#lines + 1] = prefix .. indent .. child.name .. suffix
    end
    return lines
end

--- Clear undo history (prevent undoing past render)
---@param bufnr integer
local function clear_undo(bufnr)
    local old_undolevels = vim.bo[bufnr].undolevels
    vim.bo[bufnr].undolevels = -1
    -- Make a no-op change to create undo break
    local line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { line })
    vim.bo[bufnr].undolevels = old_undolevels
end

--- Full render: flatten, write lines (decoration provider handles extmarks)
---@param bufnr integer
---@param state State
---@param opts? { clear_undo: boolean }
function M.render(bufnr, state, opts)
    opts = opts or {}
    local entries = M.flatten(state)
    local lines = M.to_lines(entries)

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

    vim.bo[bufnr].modified = false

    if opts.clear_undo then
        clear_undo(bufnr)
    end
end

return M
