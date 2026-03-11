local buffer = require("sap.buffer")
local render = require("sap.render")
local opts = require("sap.config").options

local M = {}

local function get_context()
    local bufnr = vim.api.nvim_get_current_buf()
    local linenr = vim.api.nvim_win_get_cursor(0)[1]
    local state = buffer.get_state(bufnr)
    local entry = buffer.get_entry_at_line(bufnr, linenr)
    return bufnr, linenr, state, entry
end

--- Open file or toggle directory
--- If on root, go to parent instead
function M.open()
    local bufnr, linenr, state, entry = get_context()
    if not entry or not state then
        return
    end

    --- If on root, go to parent instead
    if entry.path == state.root_path then
        M.parent()
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

--- Go to parent directory (in place, surgical)
function M.parent()
    local bufnr, linenr, state, entry = get_context()
    if not state then
        return
    end

    -- Save current entry's path to restore cursor
    local old_path = entry and entry.path

    -- Use surgical go_to_parent (preserves user edits)
    local ok, err = render.go_to_parent(bufnr, state)
    if not ok then
        vim.notify("sap: " .. (err or "cannot go to parent"), vim.log.levels.WARN)
        return
    end

    -- Restore cursor to the same entry (now one level deeper)
    if old_path then
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        for i, line in ipairs(lines) do
            local id = parser.parse_line(line)
            if id then
                local e = state:get_by_id(id)
                if e and e.path == old_path then
                    local _, indent = parser.parse_line(line)
                    vim.api.nvim_win_set_cursor(0, { i, indent })
                    return
                end
            end
        end
    end

    -- Fallback: go to line 1
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
end

--- Set current entry as root (in place, surgical)
function M.set_root()
    local bufnr, _, state, entry = get_context()
    if not entry or not state then
        return
    end

    if entry.type ~= "directory" then
        vim.notify("sap: not a directory", vim.log.levels.WARN)
        return
    end

    -- Block if save_scope is "view" and there are unsaved changes
    if opts.save_scope == "view" and buffer.has_unsaved_changes(bufnr) then
        vim.notify("sap: save changes before navigating (:w)", vim.log.levels.WARN)
        return
    end

    -- Use surgical set_root (preserves user edits)
    local ok, err = render.set_root(bufnr, state, entry)
    if not ok then
        vim.notify("sap: " .. (err or "cannot set root"), vim.log.levels.WARN)
        return
    end

    -- Cursor moves to line 1 (the new root)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
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
    buffer.clear_undo(bufnr)
end

--- Toggle hidden files visibility
--- TODO: Make surgical like collapse/expand instead of blocking
function M.toggle_hidden()
    local bufnr, _, state, _ = get_context()
    if not state then
        return
    end

    if buffer.has_unsaved_changes(bufnr) then
        vim.notify("sap: save changes before toggling hidden (:w)", vim.log.levels.WARN)
        return
    end

    state.show_hidden = not state.show_hidden
    buffer.render(bufnr)
    buffer.clear_undo(bufnr)
end

--- Expand directory (in place, surgical)
function M.expand()
    local bufnr, linenr, state, entry = get_context()
    if not entry or not state then
        return
    end

    if entry.type ~= "directory" then
        return
    end

    -- Use surgical expand (preserves user edits via cached_content)
    local ok, err = render.expand(bufnr, state, entry)
    if not ok then
        vim.notify("sap: " .. (err or "cannot expand"), vim.log.levels.WARN)
        return
    end

    -- Cursor stays on same line (the directory)
    vim.api.nvim_win_set_cursor(0, { linenr, vim.fn.col(".") - 1 })
end

--- Collapse directory (in place, surgical)
function M.collapse()
    local bufnr, linenr, state, entry = get_context()
    if not entry or not state then
        return
    end

    if entry.type ~= "directory" then
        return
    end

    -- Use surgical collapse (stores lines in cached_content)
    render.collapse(bufnr, state, entry)

    -- Cursor stays on same line (the directory)
    vim.api.nvim_win_set_cursor(0, { linenr, vim.fn.col(".") - 1 })
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

--- Smart paste after cursor (preserves IDs for sap copies)
function M.paste()
    buffer.smart_paste(false)
end

--- Smart paste before cursor (preserves IDs for sap copies)
function M.paste_before()
    buffer.smart_paste(true)
end

return M
