local buffer = require("sap.buffer")
local parser = require("sap.parser")
local render = require("sap.render")

local M = {}

local function get_context()
    local bufnr = vim.api.nvim_get_current_buf()
    local linenr = vim.api.nvim_win_get_cursor(0)[1]
    local state = buffer.get_state(bufnr)
    local entry = buffer.get_entry_at_line(bufnr, linenr)
    return bufnr, linenr, state, entry
end

--- Open file or toggle directory
function M.open()
    local bufnr, linenr, state, entry = get_context()
    if not entry or not state then
        return
    end

    if entry.type == "directory" then
        if state:is_expanded(entry) then
            M.collapse()
        else
            M.expand()
        end
    else
        vim.cmd("edit " .. vim.fn.fnameescape(entry.path))
    end
end

--- Go to parent directory (in place)
function M.parent()
    local bufnr, _, state, _ = get_context()
    if not state then
        return
    end

    local old_root = state.root_path

    local ok, err = state:go_to_parent()
    if not ok then
        vim.notify("sap: " .. (err or "cannot go to parent"), vim.log.levels.WARN)
        return
    end

    local indent_size = require("sap.config").options.indent_size or 4
    local indent_str = string.rep(" ", indent_size)

    -- Indent all existing lines (they're now one level deeper)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i, line in ipairs(lines) do
        local prefix_end = line:find(":") or 0
        local before = line:sub(1, prefix_end)
        local after = line:sub(prefix_end + 1)
        lines[i] = before .. indent_str .. after
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

    -- Get new root entry
    local new_root_entry = state:get_by_path(state.root_path)

    -- Get siblings from state (excludes pending deletes, applies pending moves)
    local siblings = {}
    for _, s in ipairs(state:get_children(state.root_path)) do
        if s.path ~= old_root then
            siblings[#siblings + 1] = s
        end
    end

    -- Build lines to insert at top: new root + siblings
    local new_lines = {}

    -- New root line (depth 0)
    if new_root_entry then
        local suffix = new_root_entry.type == "directory" and "/" or ""
        local prefix = string.format("///%d:", new_root_entry.id)
        new_lines[#new_lines + 1] = prefix .. new_root_entry.name .. suffix
    end

    -- Sibling lines (depth 1)
    for _, sibling in ipairs(siblings) do
        local suffix = sibling.type == "directory" and "/" or ""
        local prefix = sibling.id and string.format("///%d:", sibling.id) or ""
        new_lines[#new_lines + 1] = prefix .. indent_str .. sibling.name .. suffix
    end

    -- Insert at top
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, new_lines)

    -- Sync to detect any changes from the buffer manipulation
    buffer.sync(bufnr)
end

--- Set current entry as root (in place)
function M.set_root()
    local bufnr, linenr, state, entry = get_context()
    if not entry or not state then
        return
    end

    if entry.type ~= "directory" then
        vim.notify("sap: not a directory", vim.log.levels.WARN)
        return
    end

    -- Parse buffer to find line ranges
    local parsed = parser.parse_buffer(bufnr, state.root_path)

    -- Find the line number of the new root
    local new_root_linenr = nil
    for _, p in ipairs(parsed) do
        if p.path == entry.path then
            new_root_linenr = p.linenr
            break
        end
    end

    state:set_root(entry)

    if not new_root_linenr then
        return
    end

    -- Get indent of new root to calculate shift
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local _, new_root_indent = parser.parse_line(lines[new_root_linenr])

    -- Delete lines before new root
    if new_root_linenr > 1 then
        vim.api.nvim_buf_set_lines(bufnr, 0, new_root_linenr - 1, false, {})
    end

    -- Unindent all remaining lines
    if new_root_indent > 0 then
        lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        for i, line in ipairs(lines) do
            local prefix_end = line:find(":") or 0
            local before = line:sub(1, prefix_end)
            local after = line:sub(prefix_end + 1)
            -- Remove indent
            local spaces_to_remove = math.min(new_root_indent, #(after:match("^%s*") or ""))
            lines[i] = before .. after:sub(spaces_to_remove + 1)
        end
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    end

    -- Sync to update pending edits after buffer manipulation
    buffer.sync(bufnr)
end

--- Refresh from filesystem (discards pending edits)
function M.refresh()
    local bufnr, _, state, _ = get_context()
    if not state then
        return
    end

    -- Refresh clears pending edits and reloads from filesystem
    state:refresh()
    buffer.render(bufnr)
end

--- Toggle hidden files visibility
function M.toggle_hidden()
    local bufnr, _, state, _ = get_context()
    if not state then
        return
    end

    -- Sync before toggling to capture any pending edits
    buffer.sync(bufnr)

    state.show_hidden = not state.show_hidden
    buffer.render(bufnr)
end

--- Find line range of children under a directory (by indentation)
---@param bufnr integer
---@param dir_linenr integer
---@return integer start_line (1-indexed, first child)
---@return integer end_line (1-indexed, last child)
local function find_child_line_range(bufnr, dir_linenr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local dir_line = lines[dir_linenr]
    if not dir_line then
        return dir_linenr, dir_linenr - 1  -- empty range
    end

    -- Get indent of directory line
    local _, dir_indent = parser.parse_line(dir_line)

    -- Find children (lines with greater indent until we hit same/less)
    local start_line = dir_linenr + 1
    local end_line = dir_linenr  -- no children yet

    for i = start_line, #lines do
        local _, indent = parser.parse_line(lines[i])
        if indent > dir_indent then
            end_line = i
        else
            break
        end
    end

    return start_line, end_line
end

--- Expand directory (in place)
function M.expand()
    local bufnr, linenr, state, entry = get_context()
    if not entry or not state then
        return
    end

    if entry.type ~= "directory" then
        return
    end

    local ok, err = state:expand(entry)
    if not ok then
        vim.notify("sap: " .. err, vim.log.levels.WARN)
        return
    end

    -- Get children from state (respects pending deletes/moves/creates)
    local children = state:get_children(entry.path)

    if #children == 0 then
        return
    end

    -- Get current line's indent level to calculate child indent
    local line = vim.api.nvim_buf_get_lines(bufnr, linenr - 1, linenr, false)[1]
    local _, parent_indent = parser.parse_line(line)
    local indent_size = require("sap.config").options.indent_size or 4
    local child_indent_level = (parent_indent / indent_size) + 1

    -- Generate and insert lines
    local new_lines = render.entries_to_lines(children, child_indent_level)
    vim.api.nvim_buf_set_lines(bufnr, linenr, linenr, false, new_lines)

    -- Sync to detect any changes
    buffer.sync(bufnr)
end

--- Collapse directory (in place)
function M.collapse()
    local bufnr, linenr, state, entry = get_context()
    if not entry or not state then
        return
    end

    if entry.type ~= "directory" then
        return
    end

    -- Sync before collapsing to capture any pending edits from children
    buffer.sync(bufnr)

    -- Find child lines in buffer
    local start_line, end_line = find_child_line_range(bufnr, linenr)

    if end_line >= start_line then
        -- Delete child lines
        vim.api.nvim_buf_set_lines(bufnr, start_line - 1, end_line, false, {})
    end

    state:collapse(entry)

    -- Sync again to update pending edits after buffer manipulation
    buffer.sync(bufnr)
end

-- Helper for indent/unindent
local function shift_lines(bufnr, start_line, end_line, delta)
    for lnum = start_line, end_line do
        local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
        local prefix_end = line:find(":") or 0
        local before = line:sub(1, prefix_end)
        local after = line:sub(prefix_end + 1)

        local new_line
        if delta > 0 then
            new_line = before .. string.rep(" ", delta) .. after
        else
            local spaces = math.min(-delta, #(after:match("^%s*") or ""))
            new_line = before .. after:sub(spaces + 1)
        end

        vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { new_line })
    end
end

--- Indent lines (normal or visual mode)
---@param visual boolean
function M.indent(visual)
    return function()
        local bufnr = vim.api.nvim_get_current_buf()
        local start_line, end_line

        if visual then
            start_line = vim.fn.line("'<")
            end_line = vim.fn.line("'>")
        else
            start_line = vim.fn.line(".")
            end_line = start_line
        end

        shift_lines(bufnr, start_line, end_line, vim.bo.shiftwidth)
    end
end

--- Unindent lines (normal or visual mode)
---@param visual boolean
function M.unindent(visual)
    return function()
        local bufnr = vim.api.nvim_get_current_buf()
        local start_line, end_line

        if visual then
            start_line = vim.fn.line("'<")
            end_line = vim.fn.line("'>")
        else
            start_line = vim.fn.line(".")
            end_line = start_line
        end

        shift_lines(bufnr, start_line, end_line, -vim.bo.shiftwidth)
    end
end

return M
