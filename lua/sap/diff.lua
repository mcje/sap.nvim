local M = {}

---@class Changes
---@field creates {path: string, type: string}[]
---@field moves {from: string, to: string, type: string}[]
---@field copies {from: string, to: string, type: string}[]
---@field deletes {path: string, type: string}[]

--- Check if an entry is intentionally not visible (outside root, collapsed, or hidden)
---@param state State
---@param entry Entry
---@return boolean
local function is_intentionally_hidden(state, entry)
    -- Check if entry is outside the current root (above or sibling of root)
    -- Entry is "under root" if its path starts with root_path/
    -- The root itself is also visible
    local root = state.root_path
    if entry.path ~= root and not entry.path:match("^" .. vim.pesc(root) .. "/") then
        return true
    end

    -- Check if entry itself is hidden and we're not showing hidden
    if entry.hidden and not state.show_hidden then
        return true
    end

    -- Check if under a collapsed directory
    local path = entry.path
    local parent = vim.fs.dirname(path)
    while parent and parent ~= path do
        local parent_entry = state:get_by_path(parent)
        if parent_entry and parent_entry.type == "directory" then
            if not state:is_expanded(parent_entry) and parent ~= state.root_path then
                return true
            end
        end
        path = parent
        parent = vim.fs.dirname(path)
    end
    return false
end

--- Calculate diff between current state and parsed buffer
---@param state State
---@param parsed ParsedEntry[]
---@return Changes
function M.calculate(state, parsed)
    local creates = {}
    local moves = {}
    local copies = {}
    local deletes = {}

    local seen_ids = {}       -- ids that appear in buffer
    local staying = {}        -- paths that aren't moving (same id, same path)

    -- First pass: find entries that are staying in place
    for _, p in ipairs(parsed) do
        if p.id then
            local entry = state:get_by_id(p.id)
            if entry and entry.path == p.path then
                staying[entry.path] = true
            end
        end
    end

    -- Second pass: categorize all entries
    for _, p in ipairs(parsed) do
        if not p.id then
            -- No id = new entry = create
            creates[#creates + 1] = {
                path = p.path,
                type = p.type,
            }
        else
            seen_ids[p.id] = true
            local entry = state:get_by_id(p.id)

            if entry then
                local original_path = entry.path
                local intended_path = p.path

                if original_path ~= intended_path then
                    -- Path changed
                    if not staying[original_path] then
                        -- Original location is empty = move
                        moves[#moves + 1] = {
                            from = original_path,
                            to = intended_path,
                            type = p.type,
                        }
                        staying[original_path] = true  -- can only move once
                    else
                        -- Original still exists = copy
                        copies[#copies + 1] = {
                            from = original_path,
                            to = intended_path,
                            type = p.type,
                        }
                    end
                end
                -- else: same path = no change
            end
        end
    end

    -- Third pass: find deletes (entries not in buffer, not intentionally hidden)
    for id, entry in pairs(state.entries) do
        if not seen_ids[id] and not staying[entry.path] then
            -- Only mark as delete if not intentionally hidden (collapsed/hidden)
            if not is_intentionally_hidden(state, entry) then
                deletes[#deletes + 1] = {
                    path = entry.path,
                    type = entry.type,
                }
            end
        end
    end

    -- Fourth pass: include pending_deletes (user deletions preserved across navigation)
    for path, _ in pairs(state.pending_deletes) do
        -- Avoid duplicates
        local already_added = false
        for _, d in ipairs(deletes) do
            if d.path == path then
                already_added = true
                break
            end
        end
        if not already_added then
            local entry = state:get_by_path(path)
            if entry then
                deletes[#deletes + 1] = {
                    path = entry.path,
                    type = entry.type,
                }
            end
        end
    end

    -- Also include pending_moves and pending_creates
    for from_path, to_path in pairs(state.pending_moves) do
        local already_added = false
        for _, m in ipairs(moves) do
            if m.from == from_path then
                already_added = true
                break
            end
        end
        if not already_added then
            local entry = state:get_by_path(from_path)
            if entry then
                moves[#moves + 1] = {
                    from = from_path,
                    to = to_path,
                    type = entry.type,
                }
            end
        end
    end

    for path, create in pairs(state.pending_creates) do
        local already_added = false
        for _, c in ipairs(creates) do
            if c.path == path then
                already_added = true
                break
            end
        end
        if not already_added then
            creates[#creates + 1] = {
                path = path,
                type = create.type,
            }
        end
    end

    return {
        creates = creates,
        moves = moves,
        copies = copies,
        deletes = deletes,
    }
end

---@param changes Changes
---@return boolean
function M.is_empty(changes)
    return #changes.creates == 0
        and #changes.moves == 0
        and #changes.copies == 0
        and #changes.deletes == 0
end

return M
