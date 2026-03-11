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

--- Shadow registers for smart yank/paste
--- Maps register name -> { full = "///{id}:...", hash = "..." }
---@type table<string, { full: string[], hash: string }>
M.shadow_registers = {}

--- Simple hash for comparing register contents
---@param lines string[]
---@return string
local function hash_lines(lines)
    return table.concat(lines, "\n")
end

--- Strip ID prefix from line, return clean content
---@param line string
---@return string
local function strip_id_prefix(line)
    return line:gsub("^///%d+:", "")
end

--- Strip ID prefix from all lines
---@param lines string[]
---@return string[]
local function strip_id_prefixes(lines)
    local clean = {}
    for _, line in ipairs(lines) do
        clean[#clean + 1] = strip_id_prefix(line)
    end
    return clean
end

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

    -- Smart yank: populate shadow register with full content (including ID)
    -- Vim register gets clean content (without ID) for external paste
    vim.api.nvim_create_autocmd("TextYankPost", {
        buffer = bufnr,
        callback = function()
            local event = vim.v.event
            local reg = event.regname
            if reg == "" then
                reg = vim.v.register -- default register
            end

            -- Store full content in shadow register
            local full_lines = event.regcontents
            local clean_lines = strip_id_prefixes(full_lines)

            M.shadow_registers[reg] = {
                full = full_lines,
                hash = hash_lines(clean_lines),
            }

            -- Replace vim register with clean content (no ID prefix)
            vim.fn.setreg(reg, clean_lines, event.regtype)
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
    local delete_label = config.options.delete_method == "trash" and "[TRASH]" or "[DELETE]"
    for _, d in ipairs(changes.deletes) do
        lines[#lines + 1] = "  " .. delete_label .. " " .. format_path(d.path, d.type)
    end

    if #lines == 0 then
        return false
    end

    local msg = "Apply changes?\n" .. table.concat(lines, "\n")
    local choice = vim.fn.confirm(msg, "&Yes\n&No", 2)
    return choice == 1
end

---@class ApplyResult
---@field succeeded string[]  -- descriptions of successful operations
---@field error string?       -- first error encountered, nil if all succeeded

--- Apply filesystem changes, stopping on first error
---@param changes Changes
---@return ApplyResult
local function apply_changes(changes)
    local succeeded = {}

    -- Order: create -> copy -> move -> delete
    for _, c in ipairs(changes.creates) do
        local ok, err = fs.create(c.path, c.type == "directory")
        if not ok then
            return { succeeded = succeeded, error = "create " .. c.path .. ": " .. err }
        end
        succeeded[#succeeded + 1] = "created " .. format_path(c.path, c.type)
    end

    for _, c in ipairs(changes.copies) do
        local ok, err = fs.copy(c.from, c.to)
        if not ok then
            return { succeeded = succeeded, error = "copy " .. c.from .. ": " .. err }
        end
        succeeded[#succeeded + 1] = "copied " .. format_path(c.from, c.type)
    end

    for _, m in ipairs(changes.moves) do
        local ok, err = fs.move(m.from, m.to)
        if not ok then
            return { succeeded = succeeded, error = "move " .. m.from .. ": " .. err }
        end
        succeeded[#succeeded + 1] = "moved " .. format_path(m.from, m.type)
    end

    local delete_verb = config.options.delete_method == "trash" and "trashed" or "deleted"
    for _, d in ipairs(changes.deletes) do
        local ok, err
        if config.options.delete_method == "trash" then
            ok, err = fs.trash(d.path, config.options.trash_dir)
        else
            ok, err = fs.remove(d.path)
        end
        if not ok then
            return { succeeded = succeeded, error = "delete " .. d.path .. ": " .. err }
        end
        succeeded[#succeeded + 1] = delete_verb .. " " .. format_path(d.path, d.type)
    end

    return { succeeded = succeeded, error = nil }
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

    local result = apply_changes(changes)

    -- Report what succeeded
    for _, msg in ipairs(result.succeeded) do
        vim.notify("sap: " .. msg, vim.log.levels.INFO)
    end

    if result.error then
        -- Error occurred - report it and don't refresh (buffer still shows remaining changes)
        vim.notify("sap: " .. result.error, vim.log.levels.ERROR)
        vim.notify("sap: stopped, buffer shows remaining changes", vim.log.levels.WARN)
    else
        -- All succeeded - refresh state and re-render
        state:refresh()
        render.render(bufnr, state, { clear_undo = true })
    end
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

--- Check if buffer has unsaved changes (always includes cached/global changes)
---@param bufnr integer
---@return boolean
function M.has_unsaved_changes(bufnr)
    local state = M.states[bufnr]
    if not state then
        return false
    end
    local parsed = parser.parse_buffer(bufnr, state.root_path)

    -- Always include cached content (collapsed dirs, outside root)
    local cached = state:get_all_cached_content("")
    local cached_parsed = cached_to_parsed(cached)
    for _, cp in ipairs(cached_parsed) do
        parsed[#parsed + 1] = cp
    end

    local changes = diff.calculate(state, parsed)
    return not diff.is_empty(changes)
end

function M.close(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()

    if M.has_unsaved_changes(bufnr) then
        local choice = vim.fn.confirm("Unsaved changes. Close anyway?", "&Yes\n&No", 2)
        if choice ~= 1 then
            return
        end
    end

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

--- Smart paste: use shadow register if content matches, otherwise use vim register
--- This preserves IDs for internal sap copy operations while allowing external paste
---@param before boolean paste before cursor (P) or after (p)
---@param reg string? register to paste from (default: v:register)
function M.smart_paste(before, reg)
    reg = reg or vim.v.register
    if reg == "" then
        reg = '"' -- default register
    end

    local shadow = M.shadow_registers[reg]
    local vim_content = vim.fn.getreg(reg)
    local vim_type = vim.fn.getregtype(reg)

    -- Check if shadow matches current vim register content
    if shadow and hash_lines(vim.split(vim_content, "\n", { plain = true })) == shadow.hash then
        -- Content matches - use shadow (preserves IDs)
        vim.fn.setreg(reg, shadow.full, vim_type)
    end

    -- Perform the paste
    local paste_cmd = before and "P" or "p"
    if reg == '"' then
        vim.cmd("normal! " .. paste_cmd)
    else
        vim.cmd("normal! \"" .. reg .. paste_cmd)
    end

    -- Restore clean content to vim register (for external use)
    if shadow and hash_lines(vim.split(vim_content, "\n", { plain = true })) == shadow.hash then
        vim.fn.setreg(reg, vim_content, vim_type)
    end
end

return M
