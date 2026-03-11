local M = {}

---@class Changes
---@field creates {path: string, type: string}[]
---@field moves {from: string, to: string, type: string}[]
---@field copies {from: string, to: string, type: string}[]
---@field deletes {path: string, type: string}[]

--- Calculate diff by comparing parsed buffer against state.entries (original filesystem state)
---@param state State
---@param parsed ParsedEntry[]
---@return Changes
function M.calculate(state, parsed)
    local creates = {}
    local moves = {}
    local copies = {}
    local deletes = {}

    -- Build map: id -> list of paths where this ID appears in buffer
    local id_to_paths = {}  -- id -> {path, type}[]
    local seen_ids = {}     -- quick lookup

    for _, p in ipairs(parsed) do
        if p.id then
            seen_ids[p.id] = true
            id_to_paths[p.id] = id_to_paths[p.id] or {}
            table.insert(id_to_paths[p.id], { path = p.path, type = p.type })
        else
            -- Line without ID = new entry = CREATE
            creates[#creates + 1] = {
                path = p.path,
                type = p.type,
            }
        end
    end

    -- For each original entry, determine what happened
    for id, entry in pairs(state.entries) do
        local paths = id_to_paths[id]

        if not paths or #paths == 0 then
            -- ID not in buffer at all
            -- Only DELETE if not intentionally hidden (collapsed, outside root, etc.)
            if not state:is_intentionally_hidden(entry) then
                deletes[#deletes + 1] = {
                    path = entry.path,
                    type = entry.type,
                }
            end
        else
            -- ID appears in buffer - check if at original location or moved/copied
            local original_in_buffer = false
            local other_paths = {}

            for _, p in ipairs(paths) do
                if p.path == entry.path then
                    original_in_buffer = true
                else
                    table.insert(other_paths, p)
                end
            end

            if original_in_buffer then
                -- Original stays in place, any other occurrences are COPY
                for _, p in ipairs(other_paths) do
                    copies[#copies + 1] = {
                        from = entry.path,
                        to = p.path,
                        type = p.type,
                    }
                end
            else
                -- Original not in buffer
                -- First occurrence is a MOVE, rest are COPY from the move destination
                local first = other_paths[1]
                moves[#moves + 1] = {
                    from = entry.path,
                    to = first.path,
                    type = first.type,
                }

                -- Additional occurrences are copies of the moved file
                for i = 2, #other_paths do
                    local p = other_paths[i]
                    copies[#copies + 1] = {
                        from = first.path,  -- Copy from move destination
                        to = p.path,
                        type = p.type,
                    }
                end
            end
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
