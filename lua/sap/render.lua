local config = require("sap.config")
local parser = require("sap.parser")
local constants = require("sap.constants")

local M = {}

local ns = vim.api.nvim_create_namespace("sap")
local ns_icons = vim.api.nvim_create_namespace("sap_icons") -- Separate namespace for inline icons

-- Pre-computed guide info per buffer: bufnr -> { [row] = { guide = "...", is_expanded = bool } }
---@type table<integer, table<integer, { guide: string, is_expanded: boolean?, is_dir: boolean }>>
M.line_info = {}

---@return integer
local function get_indent_size()
    return config.options.indent_size or 4
end

---@return string
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
    vim.api.nvim_set_hl(0, "SapGuide", { link = "Comment", default = true })
    vim.api.nvim_set_hl(0, "SapExpanded", { link = "Directory", default = true })
    vim.api.nvim_set_hl(0, "SapCollapsed", { link = "Directory", default = true })
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
    if icons_cfg.use_devicons ~= false and has_devicons then
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
---@param states table<integer, State>
function M.setup_decoration_provider(states)
    vim.api.nvim_set_decoration_provider(ns, {
        on_start = function(_, tick)
            -- Clear non-ephemeral icon extmarks before redraw
            -- We track which buffers we've cleared this tick to avoid redundant clears
            return true -- Continue with on_line calls
        end,
        on_win = function(_, _, bufnr, toprow, botrow)
            -- Clear icon extmarks for visible range before redrawing
            if states[bufnr] then
                vim.api.nvim_buf_clear_namespace(bufnr, ns_icons, toprow, botrow + 1)
            end
        end,
        on_line = function(_, _, bufnr, row)
            local state = states[bufnr]
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
            local prefix_len = id and #string.format(constants.ID_FORMAT, id) or 0
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

            -- Tree guides (overlay on indentation)
            -- Only show guide if it fits within actual indentation (don't hide user text)
            local guides_cfg = config.options.guides
            if guides_cfg and guides_cfg.enabled and indent > 0 then
                local line_info = M.line_info[bufnr] and M.line_info[bufnr][row]
                if line_info and line_info.guide and line_info.guide ~= "" then
                    local guide = line_info.guide
                    local guide_width = vim.fn.strdisplaywidth(guide)
                    -- Truncate guide if it would extend beyond actual indentation
                    if guide_width > indent then
                        -- Truncate by display width (handles unicode)
                        local chars = vim.fn.split(guide, "\\zs")
                        local truncated = {}
                        local width = 0
                        for _, char in ipairs(chars) do
                            local char_width = vim.fn.strdisplaywidth(char)
                            if width + char_width > indent then
                                break
                            end
                            truncated[#truncated + 1] = char
                            width = width + char_width
                        end
                        guide = table.concat(truncated)
                    end
                    if guide ~= "" then
                        vim.api.nvim_buf_set_extmark(bufnr, ns, row, prefix_len, {
                            virt_text = { { guide, "SapGuide" } },
                            virt_text_pos = "overlay",
                            ephemeral = true,
                        })
                    end
                end
            end

            -- Expand/collapse indicator for directories
            -- NOTE: inline + ephemeral doesn't work in Neovim, so we use
            -- non-ephemeral extmarks in a separate namespace, cleared in on_win
            if guides_cfg and guides_cfg.enabled and ftype == "directory" then
                local line_info = M.line_info[bufnr] and M.line_info[bufnr][row]
                local is_expanded = line_info and line_info.is_expanded
                local indicator = is_expanded and guides_cfg.icons.expanded
                    or guides_cfg.icons.collapsed
                local indicator_hl = is_expanded and "SapExpanded" or "SapCollapsed"
                if indicator and indicator ~= "" then
                    vim.api.nvim_buf_set_extmark(bufnr, ns_icons, row, col, {
                        virt_text = { { indicator .. " ", indicator_hl } },
                        virt_text_pos = "inline",
                    })
                    icon = nil -- HACK: Discard icon when we use directory icons
                end
            end

            -- File type icon (inline virtual text)
            if icon and icon ~= "" then
                vim.api.nvim_buf_set_extmark(bufnr, ns_icons, row, col, {
                    virt_text = { { icon .. " ", icon_hl } },
                    virt_text_pos = "inline",
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
---@field is_last boolean  -- Is this the last child of its parent?
---@field ancestors_last boolean[]  -- For each ancestor depth, was it the last child?
---@field is_expanded boolean?  -- For directories: is it expanded?

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
            is_last = true,
            ancestors_last = {},
            is_expanded = state:is_expanded(root_entry),
        }
    end

    ---@param parent_path string
    ---@param depth integer
    ---@param ancestors_last boolean[]
    local function visit(parent_path, depth, ancestors_last)
        local children = state:get_children(parent_path)
        for i, entry in ipairs(children) do
            local is_last = (i == #children)
            local is_expanded = entry.type == "directory" and state:is_expanded(entry)

            result[#result + 1] = {
                entry = entry,
                depth = depth,
                is_last = is_last,
                ancestors_last = vim.deepcopy(ancestors_last),
                is_expanded = is_expanded,
            }

            if is_expanded then
                local new_ancestors = vim.deepcopy(ancestors_last)
                new_ancestors[depth] = is_last
                visit(entry.path, depth + 1, new_ancestors)
            end
        end
    end

    visit(state.root_path, 1, {})
    return result
end

--- Pad an icon to indent_size width
---@param icon string
---@return string
local function pad_icon(icon)
    local indent_size = get_indent_size()
    local icon_width = vim.fn.strdisplaywidth(icon)
    if icon_width < indent_size then
        return icon .. string.rep(" ", indent_size - icon_width)
    end
    return icon
end

--- Build guide string for an entry based on its tree position
---@param flat_entry FlatEntry
---@return string
local function build_guide(flat_entry)
    local guides_cfg = config.options.guides
    if not guides_cfg or not guides_cfg.enabled then
        return ""
    end

    local icons = guides_cfg.icons
    local parts = {}

    -- Build ancestor connectors
    for d = 1, flat_entry.depth - 1 do
        if flat_entry.ancestors_last[d] then
            parts[#parts + 1] = pad_icon(icons.space)
        else
            parts[#parts + 1] = pad_icon(icons.pipe)
        end
    end

    -- Add this entry's connector (if not root)
    if flat_entry.depth > 0 then
        if flat_entry.is_last then
            parts[#parts + 1] = pad_icon(icons.last)
        else
            parts[#parts + 1] = pad_icon(icons.middle)
        end
    end

    return table.concat(parts)
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
        local prefix = e.entry.id and string.format(constants.ID_FORMAT, e.entry.id) or ""
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
    local indent = string.rep(" ", indent_level)
    for _, child in ipairs(children) do
        local suffix = child.type == "directory" and "/" or ""
        local prefix = child.id and string.format(constants.ID_FORMAT, child.id) or ""
        lines[#lines + 1] = prefix .. indent .. child.name .. suffix
    end
    return lines
end

--- Compute line_info from parsed buffer entries
--- Called after sync to keep guides current with user edits
---@param bufnr integer
---@param parsed table[] -- From parser.parse_buffer
---@param state State
function M.update_line_info_from_parsed(bufnr, parsed, state)
    local guides_cfg = config.options.guides
    if not guides_cfg or not guides_cfg.enabled then
        M.line_info[bufnr] = {}
        return
    end

    local icons = guides_cfg.icons
    M.line_info[bufnr] = {}

    if #parsed == 0 then
        return
    end

    -- Use paths from parse_buffer to determine tree structure
    -- Group entries by parent path
    local children_of = {} -- parent_path -> list of {idx, path, ...}
    local root_path = nil

    for i, p in ipairs(parsed) do
        local parent_path = vim.fs.dirname(p.path)
        if i == 1 then
            root_path = p.path
            parent_path = "__ROOT__"
        elseif parent_path == vim.fs.dirname(root_path) then
            parent_path = "__ROOT__"
        end

        children_of[parent_path] = children_of[parent_path] or {}
        table.insert(children_of[parent_path], { idx = i, parsed = p })
    end

    -- Recursive function to compute guides (mirrors flatten + build_guide)
    local function visit(parent_path, depth, ancestors_last)
        local children = children_of[parent_path] or {}

        for i, child in ipairs(children) do
            local p = child.parsed
            local is_last = (i == #children)

            -- Build guide string
            local parts = {}
            for d = 1, depth - 1 do
                if ancestors_last[d] then
                    parts[#parts + 1] = pad_icon(icons.space)
                else
                    parts[#parts + 1] = pad_icon(icons.pipe)
                end
            end
            if depth > 0 then
                if is_last then
                    parts[#parts + 1] = pad_icon(icons.last)
                else
                    parts[#parts + 1] = pad_icon(icons.middle)
                end
            end

            -- Determine is_expanded from state
            local is_expanded = false
            if p.id and p.type == "directory" then
                local entry = state:get_by_id(p.id)
                if entry then
                    is_expanded = state:is_expanded(entry)
                end
            end

            local row = p.linenr - 1
            M.line_info[bufnr][row] = {
                guide = table.concat(parts),
                is_expanded = is_expanded,
                is_dir = p.type == "directory",
            }

            -- Recurse into children
            if p.type == "directory" then
                local new_ancestors = vim.deepcopy(ancestors_last)
                new_ancestors[depth] = is_last
                visit(p.path, depth + 1, new_ancestors)
            end
        end
    end

    -- Start from root
    visit("__ROOT__", 0, {})
end

--- Full render: flatten, write lines (decoration provider handles extmarks)
---@param bufnr integer
---@param state State
function M.render(bufnr, state)
    local entries = M.flatten(state)
    local lines = M.to_lines(entries)

    -- Pre-compute guide info for decoration provider
    M.line_info[bufnr] = {}
    for i, e in ipairs(entries) do
        local row = i - 1 -- 0-indexed
        M.line_info[bufnr][row] = {
            guide = build_guide(e),
            is_expanded = e.is_expanded,
            is_dir = e.entry.type == "directory",
        }
    end

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

    vim.bo[bufnr].modified = false
end

--- Find line number of an entry by ID
---@param bufnr integer
---@param id integer
---@return integer? linenr (1-indexed)
function M.find_linenr_by_id(bufnr, id)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    -- PERF: O(n) scan. Could use extmarks for O(1) lookup.
    for i, line in ipairs(lines) do
        local line_id = parser.parse_line(line)
        if line_id == id then
            return i
        end
    end
    return nil
end

--- Count lines belonging to a directory's children (for collapse)
--- Returns range [start_line, end_line] (1-indexed, inclusive)
---@param bufnr integer
---@param dir_line integer (1-indexed)
---@param dir_indent integer
---@return integer start_line
---@return integer end_line
function M.find_children_range(bufnr, dir_line, dir_indent)
    local lines = vim.api.nvim_buf_get_lines(bufnr, dir_line, -1, false)
    local end_line = dir_line

    for i, line in ipairs(lines) do
        local _, indent = parser.parse_line(line)
        if indent and indent > dir_indent then
            end_line = dir_line + i
        else
            break
        end
    end

    if end_line > dir_line then
        return dir_line + 1, end_line
    else
        return 0, 0 -- No children
    end
end

--- Surgical collapse: remove children lines, store in cached_content
---@param bufnr integer
---@param state State
---@param entry Entry
---@return boolean success
function M.collapse(bufnr, state, entry)
    local entry_line = M.find_linenr_by_id(bufnr, entry.id)
    if not entry_line then
        return false
    end

    -- Parse BEFORE modifying buffer to get computed paths
    local parsed = parser.parse_buffer(bufnr, state.root_path)

    -- Find children in parsed data (entries whose path starts with entry.path/)
    local entries_to_cache = {}
    local line_to_parsed = {}
    for _, p in ipairs(parsed) do
        line_to_parsed[p.linenr] = p
        -- Check if this entry is under the directory being collapsed
        if p.path:match("^" .. vim.pesc(entry.path) .. "/") then
            entries_to_cache[#entries_to_cache + 1] = p
        end
    end

    if #entries_to_cache == 0 then
        -- No children, just mark collapsed
        state:collapse(entry)
        return true
    end

    -- Get line range from parsed entries
    local start_line = entries_to_cache[1].linenr
    local end_line = entries_to_cache[#entries_to_cache].linenr

    -- Get raw lines for restoration
    local raw_lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)

    -- Build CachedEntry list with both parsed data and raw lines
    local to_store = {}
    for i, p in ipairs(entries_to_cache) do
        to_store[#to_store + 1] = {
            id = p.id,
            name = p.name,
            type = p.type,
            path = p.path,
            line = raw_lines[i], -- Raw line for exact restoration
        }
    end

    state:cache_content(entry.path, to_store)

    -- Delete children from buffer
    vim.api.nvim_buf_set_lines(bufnr, start_line - 1, end_line, false, {})

    -- Mark collapsed in state
    state:collapse(entry)

    -- Update line_info for guides
    parsed = parser.parse_buffer(bufnr, state.root_path)
    M.update_line_info_from_parsed(bufnr, parsed, state)

    return true
end

--- Surgical expand: restore from cached_content or load fresh, insert lines
---@param bufnr integer
---@param state State
---@param entry Entry
---@return boolean success
---@return string? err
function M.expand(bufnr, state, entry)
    local entry_line = M.find_linenr_by_id(bufnr, entry.id)
    if not entry_line then
        return false
    end

    -- Get entry's indent and compute child indent
    local line = vim.api.nvim_buf_get_lines(bufnr, entry_line - 1, entry_line, false)[1]
    local _, entry_indent = parser.parse_line(line)
    local child_indent = entry_indent + get_indent_size()

    -- Mark expanded first (so get_children works)
    local ok, err = state:expand(entry)
    if not ok then
        return false, err
    end

    -- Check for cached content
    local cached = state:get_cached_content(entry.path)
    local new_lines

    if cached and #cached > 0 then
        -- Restore from cache (preserves user edits)
        new_lines = {}
        for _, c in ipairs(cached) do
            new_lines[#new_lines + 1] = c.line
        end
        state:clear_cached_content(entry.path)
    else
        -- Load fresh from state/filesystem
        local children = state:get_children(entry.path)
        new_lines = M.entries_to_lines(children, child_indent)
    end

    -- Insert lines after the directory line
    if #new_lines > 0 then
        vim.api.nvim_buf_set_lines(bufnr, entry_line, entry_line, false, new_lines)
    end

    -- Update line_info for guides
    local parsed = parser.parse_buffer(bufnr, state.root_path)
    M.update_line_info_from_parsed(bufnr, parsed, state)

    return true
end

--- Shift indentation of all lines in a range
--- Shift indentation of lines while preserving ID prefix
---@param bufnr integer
---@param start_line integer (1-indexed)
---@param end_line integer (1-indexed)
---@param delta integer (positive = indent, negative = unindent)
function M.shift_lines(bufnr, start_line, end_line, delta)
    for lnum = start_line, end_line do
        local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
        if line and line ~= "" then
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
end

--- Surgical go to parent: insert new root + siblings, shift existing content
--- Restores from cached_content if available (preserves edits from previous set_root)
---@param bufnr integer
---@param state State
---@return boolean success
---@return string? err
function M.go_to_parent(bufnr, state)
    local old_root_path = state.root_path
    local new_root_path = vim.fs.dirname(old_root_path)

    if new_root_path == old_root_path then
        return false, "already at filesystem root"
    end

    -- Check for cached content BEFORE updating state (stored under new_root_path)
    local cached = state:get_cached_content(new_root_path)

    -- Get current line count
    local old_line_count = vim.api.nvim_buf_line_count(bufnr)

    -- Update state
    local ok, err = state:go_to_parent()
    if not ok then
        return false, err
    end

    if cached and (cached.before or cached.after) then
        -- Restore from cache with before/after structure (from set_root)
        local indent_size = get_indent_size()
        M.shift_lines(bufnr, 1, old_line_count, indent_size)

        -- Extract lines from before/after entries
        local before_lines = {}
        local after_lines = {}

        if cached.before then
            for _, c in ipairs(cached.before) do
                before_lines[#before_lines + 1] = c.line
            end
        end
        if cached.after then
            for _, c in ipairs(cached.after) do
                after_lines[#after_lines + 1] = c.line
            end
        end

        -- Insert lines before old root at top
        if #before_lines > 0 then
            vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, before_lines)
        end

        -- Find end of old root's subtree (now shifted in buffer)
        local old_root_line = #before_lines + 1
        local subtree_end = old_root_line
        local lines = vim.api.nvim_buf_get_lines(bufnr, old_root_line, -1, false)
        for i, line in ipairs(lines) do
            local _, line_indent = parser.parse_line(line)
            if line_indent and line_indent > indent_size then
                subtree_end = old_root_line + i
            else
                break
            end
        end

        -- Insert lines after old root's subtree
        if #after_lines > 0 then
            vim.api.nvim_buf_set_lines(bufnr, subtree_end, subtree_end, false, after_lines)
        end

        -- Clear the cached content we just restored
        state:clear_cached_content(new_root_path)
    else
        -- No cached content - generate fresh from state
        local indent_size = get_indent_size()
        M.shift_lines(bufnr, 1, old_line_count, indent_size)

        local new_root_entry = state:get_by_path(new_root_path)
        local siblings = state:get_children(new_root_path)

        -- Build lines for new root (at depth 0) and siblings (at depth 1)
        local new_lines = {}
        if new_root_entry then
            local suffix = new_root_entry.type == "directory" and "/" or ""
            local prefix = string.format(constants.ID_FORMAT, new_root_entry.id)
            new_lines[#new_lines + 1] = prefix .. new_root_entry.name .. suffix
        end

        -- Find position where old root will be after siblings are inserted
        local old_root_will_be_at = 2 -- After new root line

        -- Add siblings that come BEFORE old root (alphabetically)
        for _, sibling in ipairs(siblings) do
            if sibling.path == old_root_path then
                break
            end
            local suffix = sibling.type == "directory" and "/" or ""
            local prefix = sibling.id and string.format(constants.ID_FORMAT, sibling.id) or ""
            new_lines[#new_lines + 1] = prefix .. get_indent() .. sibling.name .. suffix
            old_root_will_be_at = old_root_will_be_at + 1
        end

        -- Insert new root and preceding siblings at top
        vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, new_lines)

        -- Find siblings that come AFTER old root
        local after_siblings = {}
        local past_old_root = false
        for _, sibling in ipairs(siblings) do
            if sibling.path == old_root_path then
                past_old_root = true
            elseif past_old_root then
                local suffix = sibling.type == "directory" and "/" or ""
                local prefix = sibling.id and string.format(constants.ID_FORMAT, sibling.id) or ""
                after_siblings[#after_siblings + 1] = prefix
                    .. get_indent()
                    .. sibling.name
                    .. suffix
            end
        end

        -- Find end of old root's subtree
        local old_root_line = old_root_will_be_at
        local subtree_end = old_root_line
        local lines = vim.api.nvim_buf_get_lines(bufnr, old_root_line, -1, false)
        for i, line in ipairs(lines) do
            local _, line_indent = parser.parse_line(line)
            if line_indent and line_indent > indent_size then
                subtree_end = old_root_line + i
            else
                break
            end
        end

        -- Insert siblings that come after old root
        if #after_siblings > 0 then
            vim.api.nvim_buf_set_lines(bufnr, subtree_end, subtree_end, false, after_siblings)
        end
    end

    -- Update line_info for guides
    local parsed = parser.parse_buffer(bufnr, state.root_path)
    M.update_line_info_from_parsed(bufnr, parsed, state)

    return true
end

--- Surgical set root: remove lines above and siblings below, shift remaining content
---@param bufnr integer
---@param state State
---@param entry Entry
---@return boolean success
---@return string? err
function M.set_root(bufnr, state, entry)
    if entry.type ~= "directory" then
        return false, "not a directory"
    end

    -- Find entry's line
    local entry_line = M.find_linenr_by_id(bufnr, entry.id)
    if not entry_line then
        return false, "entry not found in buffer"
    end

    -- Get entry's current indent
    local line = vim.api.nvim_buf_get_lines(bufnr, entry_line - 1, entry_line, false)[1]
    local _, entry_indent = parser.parse_line(line)

    -- Find end of entry's subtree (lines with greater indent)
    local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local subtree_end = entry_line -- At minimum, includes the entry itself
    for i = entry_line + 1, #all_lines do
        local _, line_indent = parser.parse_line(all_lines[i])
        if line_indent and line_indent > entry_indent then
            subtree_end = i
        else
            break
        end
    end

    -- Parse buffer to get paths for caching
    local parsed = parser.parse_buffer(bufnr, state.root_path)

    -- Cache lines that will no longer be visible, split into before/after new root
    local before_entries = {}
    local after_entries = {}
    for _, p in ipairs(parsed) do
        if p.linenr < entry_line then
            before_entries[#before_entries + 1] = {
                id = p.id,
                name = p.name,
                type = p.type,
                path = p.path,
                line = all_lines[p.linenr],
            }
        elseif p.linenr > subtree_end then
            after_entries[#after_entries + 1] = {
                id = p.id,
                name = p.name,
                type = p.type,
                path = p.path,
                line = all_lines[p.linenr],
            }
        end
    end

    -- Store under old root with before/after structure
    if #before_entries > 0 or #after_entries > 0 then
        state:cache_content(state.root_path, {
            before = before_entries,
            after = after_entries,
        })
    end

    -- Update state
    state:set_root(entry)

    -- Delete lines below subtree first (so line numbers stay valid)
    if subtree_end < #all_lines then
        vim.api.nvim_buf_set_lines(bufnr, subtree_end, #all_lines, false, {})
    end

    -- Delete lines above new root
    if entry_line > 1 then
        vim.api.nvim_buf_set_lines(bufnr, 0, entry_line - 1, false, {})
    end

    -- Shift all remaining lines to reduce indent
    local new_line_count = vim.api.nvim_buf_line_count(bufnr)
    M.shift_lines(bufnr, 1, new_line_count, -entry_indent)

    -- If directory was collapsed (no children in buffer), expand it now
    if new_line_count == 1 then
        local children = state:get_children(entry.path)
        if #children > 0 then
            local child_lines = M.entries_to_lines(children, get_indent_size())
            vim.api.nvim_buf_set_lines(bufnr, 1, 1, false, child_lines)
        end
    end

    -- Update line_info for guides
    parsed = parser.parse_buffer(bufnr, state.root_path)
    M.update_line_info_from_parsed(bufnr, parsed, state)

    return true
end

return M
