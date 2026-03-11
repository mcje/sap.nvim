local fs = require("sap.fs")

---@class Entry
---@field id integer
---@field path string
---@field name string
---@field type "file"|"directory"|"link"
---@field stat uv.fs_stat.result?
---@field parent_path string?
---@field hidden boolean

---@class CachedEntry
---@field id integer?
---@field name string
---@field type "file"|"directory"
---@field path string
---@field line string  -- Raw line for exact restoration

---@class State
---@field root_path string
---@field entries table<integer, Entry>
---@field path_to_id table<string, integer>
---@field expanded table<string, boolean>
---@field show_hidden boolean
---@field next_id integer
---@field cached_content table<string, CachedEntry[]>  -- parent_path -> cached buffer lines
local State = {}
State.__index = State

local default_sort = function(a, b)
    -- Directories first, then alphabetical (case-insensitive)
    if a.type ~= b.type then
        return a.type == "directory"
    end
    return a.name:lower() < b.name:lower()
end

---@param root_path string
---@param show_hidden boolean?
---@return State
function State.new(root_path, show_hidden)
    root_path = vim.fn.fnamemodify(vim.fn.expand(root_path), ":p"):gsub("/$", "")

    local self = setmetatable({}, State)
    self.root_path = root_path
    self.entries = {}
    self.path_to_id = {}
    self.expanded = { [root_path] = true }
    self.show_hidden = show_hidden or false
    self.next_id = 1
    self.sort = default_sort
    self.cached_content = {}

    -- Add root itself as an entry (no parent)
    self:add_entry(root_path, nil)

    -- Load root's children
    self:load_children(root_path)

    return self
end

---@param path string
---@param parent_path string?
---@return Entry?
function State:add_entry(path, parent_path)
    -- Don't add duplicates
    if self.path_to_id[path] then
        return self.entries[self.path_to_id[path]]
    end

    local stat = fs.stat(path)
    if not stat then
        return nil
    end

    local name = fs.basename(path)
    local id = self.next_id
    self.next_id = id + 1

    local entry = {
        id = id,
        path = path,
        name = name,
        type = stat.type,
        stat = stat,
        parent_path = parent_path,
        hidden = name:sub(1, 1) == ".",
    }

    self.entries[id] = entry
    self.path_to_id[path] = id
    return entry
end

---@param parent_path string
---@return boolean? ok
---@return string? err
function State:load_children(parent_path)
    local files, err = fs.read_dir(parent_path)
    if not files then
        return nil, err
    end

    for _, file in ipairs(files) do
        self:add_entry(file.path, parent_path)
    end

    return true
end

--- Get visible children of a path
---@param parent_path string
---@return Entry[]
function State:get_children(parent_path)
    local children = {}

    for _, entry in pairs(self.entries) do
        -- Check if parent matches
        if entry.parent_path ~= parent_path then
            goto continue
        end

        -- Check hidden
        if not self.show_hidden and entry.hidden then
            goto continue
        end

        children[#children + 1] = entry

        ::continue::
    end

    table.sort(children, self.sort)
    return children
end

--- Get entry by original path
---@param path string
---@return Entry?
function State:get_by_path(path)
    local id = self.path_to_id[path]
    return id and self.entries[id] or nil
end

--- Get entry by ID
---@param id integer
---@return Entry?
function State:get_by_id(id)
    return self.entries[id]
end

---@param entry Entry
---@return boolean? ok
---@return string? err
function State:expand(entry)
    if entry.type ~= "directory" then
        return nil, "not a directory"
    end

    self.expanded[entry.path] = true

    -- Load children if not already loaded
    local has_children = false
    for _, e in pairs(self.entries) do
        if e.parent_path == entry.path then
            has_children = true
            break
        end
    end

    if not has_children then
        return self:load_children(entry.path)
    end

    return true
end

---@param entry Entry
function State:collapse(entry)
    self.expanded[entry.path] = false
end

---@param entry Entry
---@return boolean? ok
---@return string? err
function State:toggle(entry)
    if self.expanded[entry.path] then
        self:collapse(entry)
        return true
    else
        return self:expand(entry)
    end
end

---@param entry Entry
function State:set_root(entry)
    self.root_path = entry.path
    self.expanded[entry.path] = true
    entry.parent_path = nil  -- Root has no parent

    -- Load children if not already loaded
    local has_children = false
    for _, e in pairs(self.entries) do
        if e.parent_path == entry.path then
            has_children = true
            break
        end
    end

    if not has_children then
        self:load_children(entry.path)
    end
end

---@return boolean? ok
---@return string? err
function State:go_to_parent()
    local new_root = vim.fs.dirname(self.root_path)
    if new_root == self.root_path then
        return nil, "already at filesystem root"
    end

    local old_root = self.root_path

    -- Add new root as entry (no parent)
    self:add_entry(new_root, nil)

    -- Update old root's parent to point to new root (so it shows as child)
    local old_root_entry = self:get_by_path(old_root)
    if old_root_entry then
        old_root_entry.parent_path = new_root
    end

    -- Load parent's children (siblings of current root)
    local ok, err = self:load_children(new_root)
    if not ok then
        return nil, err
    end

    self.expanded[new_root] = true
    self.root_path = new_root
    return true
end

--- Refresh entries from filesystem
function State:refresh()
    -- Clear all entries
    self.entries = {}
    self.path_to_id = {}
    self.next_id = 1
    self.cached_content = {}

    -- Rebuild expanded paths
    local old_expanded = self.expanded
    self.expanded = { [self.root_path] = true }

    -- Add root entry
    self:add_entry(self.root_path, nil)

    -- Reload starting from root
    local function reload(parent_path)
        self:load_children(parent_path)
        for _, entry in ipairs(self:get_children(parent_path)) do
            if entry.type == "directory" and old_expanded[entry.path] then
                self.expanded[entry.path] = true
                reload(entry.path)
            end
        end
    end

    reload(self.root_path)
end

---@param entry Entry
---@return boolean
function State:is_expanded(entry)
    return self.expanded[entry.path] == true
end

---@param entry Entry
---@return boolean
function State:is_exec(entry)
    if not entry.stat or not entry.stat.mode then
        return false
    end
    return bit.band(entry.stat.mode, tonumber("111", 8)) ~= 0
end

--- Check if an entry is intentionally not visible (outside root, collapsed, or hidden)
--- Used to distinguish "user deleted this" from "this is just not shown right now"
---@param entry Entry
---@return boolean
function State:is_intentionally_hidden(entry)
    -- Entry is outside the current root (above or sibling of root)
    -- Entry is "under root" if its path starts with root_path/
    -- The root itself is also visible
    if entry.path ~= self.root_path and not entry.path:match("^" .. vim.pesc(self.root_path) .. "/") then
        return true
    end

    -- Entry itself is hidden and we're not showing hidden
    if entry.hidden and not self.show_hidden then
        return true
    end

    -- Entry is under a collapsed directory
    local path = entry.path
    local parent = vim.fs.dirname(path)
    while parent and parent ~= path do
        local parent_entry = self:get_by_path(parent)
        if parent_entry and parent_entry.type == "directory" then
            if not self:is_expanded(parent_entry) and parent ~= self.root_path then
                return true
            end
        end
        path = parent
        parent = vim.fs.dirname(path)
    end

    return false
end

--- Calculate depth of a path relative to current root
--- Example: root="/home/user", path="/home/user/foo/bar" → depth=2
---@param path string
---@return integer
function State:get_depth(path)
    if path == self.root_path then
        return 0
    end
    -- Count path components after root
    local rel = path:sub(#self.root_path + 2) -- +2 to skip trailing /
    local depth = 1
    for _ in rel:gmatch("/") do
        depth = depth + 1
    end
    return depth
end

--- Cache content for a path (when collapsing or navigating away)
---@param parent_path string
---@param entries CachedEntry[]
function State:cache_content(parent_path, entries)
    self.cached_content[parent_path] = entries
end

--- Get cached content for a path
---@param parent_path string
---@return CachedEntry[]?
function State:get_cached_content(parent_path)
    return self.cached_content[parent_path]
end

--- Clear cached content for a path (when expanding or content becomes visible)
---@param parent_path string
function State:clear_cached_content(parent_path)
    self.cached_content[parent_path] = nil
end

--- Check if there is cached content under a path (recursive)
---@param path string
---@return boolean
function State:has_cached_content_under(path)
    for parent_path, _ in pairs(self.cached_content) do
        -- HACK: "" matches all absolute paths since pattern becomes "^/"
        if parent_path == path or parent_path:match("^" .. vim.pesc(path) .. "/") then
            return true
        end
    end
    return false
end

--- Get all cached content under a path (recursive, for save)
--- Handles both flat array (from collapse) and before/after structure (from set_root)
---@param path string?
---@return CachedEntry[]
function State:get_all_cached_content(path)
    local all = {}
    path = path or self.root_path
    for parent_path, content in pairs(self.cached_content) do
        -- HACK: "" matches all absolute paths since pattern becomes "^/"
        if parent_path == path or parent_path:match("^" .. vim.pesc(path) .. "/") then
            -- Check if it's a before/after structure or flat array
            if content.before or content.after then
                -- Before/after structure from set_root
                if content.before then
                    for _, entry in ipairs(content.before) do
                        all[#all + 1] = entry
                    end
                end
                if content.after then
                    for _, entry in ipairs(content.after) do
                        all[#all + 1] = entry
                    end
                end
            else
                -- Flat array from collapse
                for _, entry in ipairs(content) do
                    all[#all + 1] = entry
                end
            end
        end
    end
    return all
end

return State
