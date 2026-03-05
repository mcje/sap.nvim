local uv = vim.uv
local fs = vim.fs

local M = {}

---@class FSEntry
---@field name string
---@field path string Absolute path
---@field type "file"|"directory"|"link"

--- Get the basename of path
---@param path string
---@return string
M.basename = function(path)
    return fs.basename(path)
end

--- Get stat of path
---@param path string
---@return uv.fs_stat.result|nil
M.stat = function(path)
    ---@diagnostic disable-next-line: param-type-mismatch
    return uv.fs_lstat(path)
end

--- Read directory contents
---@param path string Absolute directory path
---@return FSEntry[]?
---@return string? err
M.read_dir = function(path)
    local it, err = uv.fs_scandir(path)
    if not it then
        return nil, "could not read dir: " .. path
    end
    local files = {}
    while true do
        local name, type = uv.fs_scandir_next(it)
        if not name then
            break
        end
        files[#files + 1] = { name = name, path = path .. "/" .. name, type = type }
    end
    return files
end

--- Create a file or directory
---@param path string
---@param is_dir boolean
---@return boolean? success
---@return string? error
M.create = function(path, is_dir)
    if is_dir then
        local success, err = uv.fs_mkdir(path, tonumber("755", 8))
        if not success then
            return success, err
        end
    else
        local fd, err = uv.fs_open(path, "w", tonumber("666", 8))
        if not fd then
            return nil, err
        end
        uv.fs_close(fd)
    end
    return true
end

--- Delete a file or directory
---@param path string
---@return boolean? success
---@return string? error
M.remove = function(path)
    -- TODO: handle symlinks
    local stat = uv.fs_stat(path)
    if not stat then
        return nil, "file not found"
    end
    if stat.type == "directory" then
        local it = uv.fs_scandir(path)
        if it then
            while true do
                local name, _ = uv.fs_scandir_next(it)
                if not name then
                    break
                end
                local success, err = M.remove(path .. "/" .. name)
                if not success then
                    return success, err
                end
            end
        end
        local success, err = uv.fs_rmdir(path)
        if not success then
            return success, err
        end
        return true
    elseif stat.type == "file" or stat.type == "link" then
        local success, err = uv.fs_unlink(path)
        if not success then
            return success, err
        end
        return true
    end
    return nil, "unsupported type: " .. stat.type
end

--- Rename/move a file or directory
---@param old_path string
---@param new_path string
---@return boolean? success
---@return string? error
M.move = function(old_path, new_path)
    return uv.fs_rename(old_path, new_path)
end

--- Copy a file or directory
---@param old_path string
---@param new_path string
---@return boolean? success
---@return string? error
M.copy = function(old_path, new_path)
    local stat = uv.fs_stat(old_path)
    if not stat then
        return nil, "source not found"
    end

    if stat.type == "file" then
        local ok, err = uv.fs_copyfile(old_path, new_path)
        if not ok then
            return nil, err
        end
        return true
    elseif stat.type == "directory" then
        local ok, err = uv.fs_mkdir(new_path, tonumber("755", 8))
        if not ok then
            return nil, err
        end
        local it = uv.fs_scandir(old_path)
        if it then
            while true do
                local name = uv.fs_scandir_next(it)
                if not name then
                    break
                end
                local copy_ok, copy_err = M.copy(old_path .. "/" .. name, new_path .. "/" .. name)
                if not copy_ok then
                    return nil, copy_err
                end
            end
        end
        return true
    elseif stat.type == "link" then
        local target = uv.fs_readlink(old_path)
        if not target then
            return nil, "failed to read symlink"
        end
        local ok, err = uv.fs_symlink(target, new_path)
        if not ok then
            return nil, err
        end
        return true
    end

    return nil, "unsupported type: " .. stat.type
end

return M
