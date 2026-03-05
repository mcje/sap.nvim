local config = require("sap.config")
local actions = require("sap.actions")
local buffer = require("sap.buffer")

local M = {}

M.setup = function(opts)
    config.setup(opts)
end

M.open = function(path)
    path = path or vim.fn.getcwd()
    local bufnr, err = require("sap.buffer").create(path)
    if not bufnr then
        vim.notify("sap: " .. err, vim.log.levels.ERROR)
        return
    end

    -- Buffer commands
    -- TODO: maybe move to buffer.lua
    vim.api.nvim_buf_create_user_command(bufnr, "Sap", function(opts)
        local cmd = opts.fargs[1]
        if cmd == "open" then
            actions.open()
        elseif cmd == "parent" then
            actions.parent()
        elseif cmd == "set_root" then
            actions.set_root()
        elseif cmd == "refresh" then
            actions.refresh()
        elseif cmd == "quit" then
            buffer.close(bufnr)
        elseif cmd == "toggle_hidden" then
            actions.toggle_hidden()
        elseif cmd == "expand" then
            actions.expand()
        elseif cmd == "collapse" then
            actions.collapse()
        elseif cmd == "indent" then
            actions.indent(opts.range > 0)()
        elseif cmd == "unindent" then
            actions.unindent(opts.range > 0)()
        end
    end, { nargs = 1, range = true })

    -- Set keymaps
    if config.options.keys then
        for _, km in ipairs(config.options.keys) do
            local mode = km.mode or "n"
            vim.keymap.set(mode, km[1], km[2], { buffer = bufnr, desc = km.desc })
        end
    end

    vim.api.nvim_set_current_buf(bufnr)
end

return M
