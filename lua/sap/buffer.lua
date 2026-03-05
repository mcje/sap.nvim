local State = require("sap.state")
local parser = require("sap.parser")
local diff = require("sap.diff")
local render = require("sap.render")
local fs = require("sap.fs")
local config = require("sap.config")

local M = {}

---@type table<integer, State>
M.states = {}

render.setup_highlights()
render.setup_decoration_provider()

local function setup_buffer_options(bufnr, bufname)
    vim.api.nvim_buf_set_name(bufnr, bufname)
    vim.bo[bufnr].buftype = "acwrite"
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = "sap"

    -- Syntax for concealing ID prefix
    vim.api.nvim_buf_call(bufnr, function()
        vim.cmd([[syntax match sapEntryId "^///\d\+:" conceal]])
    end)
end

local function setup_autocmds(bufnr)
    -- Window options when buffer displayed
    vim.api.nvim_create_autocmd("BufWinEnter", {
        buffer = bufnr,
        callback = function()
            vim.wo.conceallevel = 2
            vim.wo.concealcursor = "nvic"
        end,
    })

    -- Cleanup on wipe
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = bufnr,
        callback = function()
            M.states[bufnr] = nil
        end,
    })

    -- Save handler
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = bufnr,
        callback = function()
            M.save(bufnr)
        end,
    })

    -- Cursor constraint (prevent entering hidden prefix)
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        buffer = bufnr,
        callback = function()
            local line = vim.api.nvim_get_current_line()
            local min_col = line:find(":") or 0
            local col = vim.fn.col(".")
            if col <= min_col then
                vim.api.nvim_win_set_cursor(0, { vim.fn.line("."), min_col })
            end
        end,
    })

    -- Sync buffer changes to pending edits
    vim.api.nvim_create_autocmd("TextChanged", {
        buffer = bufnr,
        callback = function()
            M.sync(bufnr)
        end,
    })
end

---@param path string
---@return integer? bufnr
---@return string? error
function M.create(path)
    path = vim.fn.fnamemodify(vim.fn.expand(path), ":p"):gsub("/$", "")
    local bufname = "sap:///" .. path

    -- Check for existing buffer
    local existing = vim.fn.bufnr(bufname)
    if existing ~= -1 then
        if M.states[existing] then
            -- Reuse existing buffer with state
            vim.api.nvim_set_current_buf(existing)
            return existing
        else
            -- Stale buffer (e.g., after module reload), wipe it
            vim.api.nvim_buf_delete(existing, { force = true })
        end
    end

    -- Create state
    local state = State.new(path, config.options.show_hidden)

    -- Create buffer
    local bufnr = vim.api.nvim_create_buf(false, false)
    M.states[bufnr] = state

    setup_buffer_options(bufnr, bufname)
    setup_autocmds(bufnr)

    render.render(bufnr, state, { clear_undo = true })

    return bufnr
end

---@param bufnr integer
function M.render(bufnr)
    local state = M.states[bufnr]
    if not state then
        return
    end
    render.render(bufnr, state)
end

--- Sync buffer edits to state's pending edits
--- Called on TextChanged to detect deletions, moves, and creates
--- Only updates pending edits for entries that SHOULD be visible (under root, expanded, not hidden)
--- Preserves pending edits for entries outside the current view
---@param bufnr integer
function M.sync(bufnr)
    local state = M.states[bufnr]
    if not state then
        return
    end

    local parsed = parser.parse_buffer(bufnr, state.root_path)

    -- Build set of IDs in buffer and their intended paths
    local buffer_ids = {}
    for _, p in ipairs(parsed) do
        if p.id then
            buffer_ids[p.id] = p
        end
    end

    -- Only clear pending edits for entries that SHOULD be visible
    -- Keep pending edits for entries outside the current root
    local old_deletes = vim.tbl_extend("force", {}, state.pending_deletes)
    local old_moves = vim.tbl_extend("force", {}, state.pending_moves)
    local old_creates = vim.tbl_extend("force", {}, state.pending_creates)

    state:clear_pending()

    -- Restore pending edits for entries outside current root
    for path, _ in pairs(old_deletes) do
        local entry = state:get_by_path(path)
        if entry and state:is_intentionally_hidden(entry) then
            state.pending_deletes[path] = true
        end
    end
    for from_path, to_path in pairs(old_moves) do
        local entry = state:get_by_path(from_path)
        if entry and state:is_intentionally_hidden(entry) then
            state.pending_moves[from_path] = to_path
        end
    end
    for path, create in pairs(old_creates) do
        -- Check if create's parent is outside root
        local parent_entry = state:get_by_path(create.parent_path)
        if parent_entry and state:is_intentionally_hidden(parent_entry) then
            state.pending_creates[path] = create
        end
    end

    -- Check each entry in state against buffer
    for id, entry in pairs(state.entries) do
        -- Skip entries that are intentionally hidden (outside root, collapsed, hidden)
        if state:is_intentionally_hidden(entry) then
            goto continue
        end

        local parsed_entry = buffer_ids[id]

        if not parsed_entry then
            -- Entry should be visible but isn't in buffer -> deleted
            state:mark_delete(entry.path)
        elseif parsed_entry.path ~= entry.path then
            -- Path changed -> moved/renamed
            state:mark_move(entry.path, parsed_entry.path)
        end

        ::continue::
    end

    -- Check for new entries (lines without IDs)
    for _, p in ipairs(parsed) do
        if not p.id then
            -- New entry (no ID) -> create
            state:mark_create(p.path, p.type)
        end
    end
end

local function format_path(path, ftype)
    return path .. (ftype == "directory" and "/" or "")
end

local function confirm_changes(changes)
    local lines = {}

    for _, c in ipairs(changes.creates) do
        lines[#lines + 1] = "  [CREATE] " .. format_path(c.path, c.type)
    end
    for _, c in ipairs(changes.copies) do
        lines[#lines + 1] = "  [COPY] " .. format_path(c.from, c.type) .. " -> " .. format_path(c.to, c.type)
    end
    for _, m in ipairs(changes.moves) do
        lines[#lines + 1] = "  [MOVE] " .. format_path(m.from, m.type) .. " -> " .. format_path(m.to, m.type)
    end
    for _, d in ipairs(changes.deletes) do
        lines[#lines + 1] = "  [DELETE] " .. format_path(d.path, d.type)
    end

    if #lines == 0 then
        return false
    end

    local msg = "Apply changes?\n" .. table.concat(lines, "\n")
    local choice = vim.fn.confirm(msg, "&Yes\n&No", 2)
    return choice == 1
end

local function apply_changes(changes)
    local errors = {}

    -- Order: create -> copy -> move -> delete
    for _, c in ipairs(changes.creates) do
        local ok, err = fs.create(c.path, c.type == "directory")
        if not ok then
            errors[#errors + 1] = "create " .. c.path .. ": " .. err
        end
    end

    for _, c in ipairs(changes.copies) do
        local ok, err = fs.copy(c.from, c.to)
        if not ok then
            errors[#errors + 1] = "copy " .. c.from .. ": " .. err
        end
    end

    for _, m in ipairs(changes.moves) do
        local ok, err = fs.move(m.from, m.to)
        if not ok then
            errors[#errors + 1] = "move " .. m.from .. ": " .. err
        end
    end

    for _, d in ipairs(changes.deletes) do
        local ok, err = fs.remove(d.path)
        if not ok then
            errors[#errors + 1] = "delete " .. d.path .. ": " .. err
        end
    end

    return errors
end

---@param bufnr integer
function M.save(bufnr)
    local state = M.states[bufnr]
    if not state then
        return
    end

    local parsed = parser.parse_buffer(bufnr, state.root_path)
    local changes = diff.calculate(state, parsed)

    if diff.is_empty(changes) then
        vim.notify("sap: no changes", vim.log.levels.INFO)
        vim.bo[bufnr].modified = false
        return
    end

    if not confirm_changes(changes) then
        return
    end

    local errors = apply_changes(changes)

    if #errors > 0 then
        for _, e in ipairs(errors) do
            vim.notify("sap: " .. e, vim.log.levels.ERROR)
        end
    end

    -- Refresh state and re-render
    state:refresh()
    render.render(bufnr, state, { clear_undo = true })
end

---@param bufnr integer
---@return State?
function M.get_state(bufnr)
    return M.states[bufnr]
end

---@param bufnr integer
---@param linenr integer (1-indexed)
---@return Entry?
function M.get_entry_at_line(bufnr, linenr)
    local state = M.states[bufnr]
    if not state then
        return nil
    end

    local lines = vim.api.nvim_buf_get_lines(bufnr, linenr - 1, linenr, false)
    if #lines == 0 then
        return nil
    end

    local id = parser.parse_line(lines[1])
    if not id then
        return nil
    end

    return state:get_by_id(id)
end

function M.close(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local alt = vim.fn.bufnr("#")
    if alt > 0 and alt ~= bufnr and vim.fn.buflisted(alt) == 1 then
        vim.api.nvim_set_current_buf(alt)
    else
        vim.cmd("enew")
    end
end

return M
