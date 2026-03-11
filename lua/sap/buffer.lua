local State = require("sap.state")
local parser = require("sap.parser")
local diff = require("sap.diff")
local render = require("sap.render")
local fs = require("sap.fs")
local config = require("sap.config")
local constants = require("sap.constants")

local M = {}

---@type table<integer, State>
M.states = {}

render.setup_highlights()
render.setup_decoration_provider(M.states)

local function setup_buffer_options(bufnr, bufname)
    vim.api.nvim_buf_set_name(bufnr, bufname)
    vim.bo[bufnr].buftype = "acwrite"
    vim.bo[bufnr].bufhidden = "hide"  -- Keep buffer alive when switching to files
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = "sap"

    -- Syntax for concealing ID prefix
    vim.api.nvim_buf_call(bufnr, function()
        vim.cmd(string.format([[syntax match sapEntryId "%s" conceal]], constants.ID_SYNTAX_PATTERN))
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
            render.line_info[bufnr] = nil
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

    -- Update tree guides on text changes (debounced)
    local guide_timer = nil
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        buffer = bufnr,
        callback = function()
            if guide_timer then
                guide_timer:stop()
                guide_timer:close()
            end
            guide_timer = vim.uv.new_timer()
            guide_timer:start(100, 0, vim.schedule_wrap(function()
                if guide_timer then
                    guide_timer:close()
                    guide_timer = nil
                end
                if vim.api.nvim_buf_is_valid(bufnr) and M.states[bufnr] then
                    local state = M.states[bufnr]
                    local parsed = parser.parse_buffer(bufnr, state.root_path)
                    render.update_line_info_from_parsed(bufnr, parsed, state)
                    vim.cmd("redraw!")
                end
            end))
        end,
    })
end

---@param path string
---@return integer? bufnr
---@return string? error
function M.create(path)
    path = vim.fn.fnamemodify(vim.fn.expand(path), ":p"):gsub("/$", "")
    local bufname = constants.BUFFER_SCHEME .. path

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

--- Convert cached content to ParsedEntry format for diff calculation
---@param cached CachedEntry[]
---@return ParsedEntry[]
local function cached_to_parsed(cached)
    local result = {}
    for _, c in ipairs(cached) do
        result[#result + 1] = {
            id = c.id,
            path = c.path,
            name = c.name,
            type = c.type,
            indent = 0,  -- Not used for diff
            linenr = 0,  -- Not in visible buffer
        }
    end
    return result
end

---@param bufnr integer
function M.save(bufnr)
    local state = M.states[bufnr]
    if not state then
        return
    end

    -- Get visible entries from buffer
    local parsed = parser.parse_buffer(bufnr, state.root_path)

    -- Add cached entries if save_scope is "global"
    if config.options.save_scope == "global" then
        -- Pass "/" to get ALL cached content, not just under current root
        -- HACK: "" matches all absolute paths (pattern becomes "^/")
local cached = state:get_all_cached_content("")
        local cached_parsed = cached_to_parsed(cached)
        for _, cp in ipairs(cached_parsed) do
            parsed[#parsed + 1] = cp
        end
    end

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
---@return Entry|ParsedEntry|nil
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
    if id then
        return state:get_by_id(id)
    end

    -- No ID - parse buffer to compute path for new entries
    local parsed = parser.parse_buffer(bufnr, state.root_path)
    for _, p in ipairs(parsed) do
        if p.linenr == linenr then
            -- Populate Entry-compatible fields
            p.parent_path = vim.fs.dirname(p.path)
            p.hidden = p.name:sub(1, 1) == "."
            return p
        end
    end
    return nil
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

--- Clear undo history for buffer (prevents undoing past structural changes)
---@param bufnr integer
function M.clear_undo(bufnr)
    local old_undolevels = vim.bo[bufnr].undolevels
    vim.bo[bufnr].undolevels = -1
    -- Make a no-op change to create undo break
    local line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { line })
    vim.bo[bufnr].undolevels = old_undolevels
end

return M
