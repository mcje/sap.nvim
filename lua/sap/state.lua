local fs = require("sap.fs")

---@class Entry
---@field id integer
---@field path string
---@field name string
---@field type "file"|"directory"|"link"
---@field stat uv.fs_stat.result?
---@field parent_path string?
---@field hidden boolean

---@class PendingCreate
---@field name string
---@field type "file"|"directory"
---@field parent_path string

---@class State
---@field root_path string
---@field entries table<integer, Entry>
---@field path_to_id table<string, integer>
---@field expanded table<string, boolean>
---@field show_hidden boolean
---@field next_id integer
---@field pending_deletes table<string, boolean>  -- paths to delete
---@field pending_moves table<string, string>  -- original_path -> new_path
---@field pending_creates table<string, PendingCreate>  -- path -> create info
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
    self.pending_deletes = {}
    self.pending_moves = {}
    self.pending_creates = {}

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

--- Get visible children of a path (respects pending edits)
---@param parent_path string
---@return Entry[]
function State:get_children(parent_path)
    local children = {}

    -- Add entries from state (excluding deleted, applying moves)
    for _, entry in pairs(self.entries) do
        local effective_parent = entry.parent_path
        local effective_path = entry.path
        local effective_name = entry.name

        -- Check if this entry is moved
        if self.pending_moves[entry.path] then
            effective_path = self.pending_moves[entry.path]
            effective_name = fs.basename(effective_path)
            effective_parent = vim.fs.dirname(effective_path)
        end

        -- Skip if deleted
        if self.pending_deletes[entry.path] then
            goto continue
        end

        -- Check if parent matches
        if effective_parent ~= parent_path then
            goto continue
        end

        -- Check hidden
        local is_hidden = effective_name:sub(1, 1) == "."
        if not self.show_hidden and is_hidden then
            goto continue
        end

        -- Create effective entry for display
        children[#children + 1] = {
            id = entry.id,
            path = effective_path,
            name = effective_name,
            type = entry.type,
            stat = entry.stat,
            parent_path = effective_parent,
            hidden = is_hidden,
        }

        ::continue::
    end

    -- Add pending creates under this parent
    for path, create in pairs(self.pending_creates) do
        if create.parent_path == parent_path then
            local name = fs.basename(path)
            local is_hidden = name:sub(1, 1) == "."
            if self.show_hidden or not is_hidden then
                children[#children + 1] = {
                    id = nil,  -- No ID for creates
                    path = path,
                    name = name,
                    type = create.type,
                    stat = nil,
                    parent_path = parent_path,
                    hidden = is_hidden,
                }
            end
        end
    end

    table.sort(children, self.sort)
    return children
end

--- Get effective path for an entry (applies pending moves)
---@param entry Entry
---@return string
function State:get_effective_path(entry)
    return self.pending_moves[entry.path] or entry.path
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

--- Check if an entry is pending deletion
---@param path string
---@return boolean
function State:is_deleted(path)
    return self.pending_deletes[path] == true
end

--- Mark an entry for deletion
---@param path string
function State:mark_delete(path)
    -- If it's a pending create, just remove the create
    if self.pending_creates[path] then
        self.pending_creates[path] = nil
        return
    end
    self.pending_deletes[path] = true
end

--- Mark an entry for move/rename
---@param from_path string
---@param to_path string
function State:mark_move(from_path, to_path)
    -- If it's a pending create, update the create path
    if self.pending_creates[from_path] then
        local create = self.pending_creates[from_path]
        self.pending_creates[from_path] = nil
        create.parent_path = vim.fs.dirname(to_path)
        self.pending_creates[to_path] = create
        return
    end
    self.pending_moves[from_path] = to_path
end

--- Add a pending create
---@param path string
---@param entry_type "file"|"directory"
function State:mark_create(path, entry_type)
    self.pending_creates[path] = {
        name = fs.basename(path),
        type = entry_type,
        parent_path = vim.fs.dirname(path),
    }
end

--- Clear a pending deletion (undo delete)
---@param path string
function State:unmark_delete(path)
    self.pending_deletes[path] = nil
end

--- Clear a pending move (undo move)
---@param from_path string
function State:unmark_move(from_path)
    self.pending_moves[from_path] = nil
end

--- Clear all pending edits
function State:clear_pending()
    self.pending_deletes = {}
    self.pending_moves = {}
    self.pending_creates = {}
end

--- Check if there are any pending edits
---@return boolean
function State:has_pending_edits()
    return next(self.pending_deletes) ~= nil
        or next(self.pending_moves) ~= nil
        or next(self.pending_creates) ~= nil
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

--- Refresh entries from filesystem (clears pending edits)
function State:refresh()
    -- Clear all entries and pending edits
    self.entries = {}
    self.path_to_id = {}
    self.next_id = 1
    self.pending_deletes = {}
    self.pending_moves = {}
    self.pending_creates = {}

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

return State
