local M = {}

M.defaults = {
    show_hidden = false,
    indent_size = 4,

    -- "view" = save current view only, "global" = include all cached content
    save_scope = "global",

    -- "trash" = move to trash_dir, "permanent" = delete permanently
    delete_method = "trash",
    trash_dir = vim.fn.stdpath("data") .. "/sap/trash",

    icons = {
        use_devicons = true,
        directory = "",
        file = "",
    },

    -- Tree guide lines (set to false to disable)
    guides = {
        enabled = true,
        icons = {
            expanded = "", -- expanded directory indicator
            collapsed = "", -- collapsed directory indicator
            middle = "├", -- middle child
            last = "└", -- last child
            pipe = "│", -- vertical connector
            space = " ", -- empty space (no connector)
        },
    },

    -- Keymaps (set to false to disable all)
    keys = {
        { "<CR>", "<cmd>Sap open<cr>", desc = "Open file / toggle dir" },
        { "<BS>", "<cmd>Sap parent<cr>", desc = "Go to parent" },
        { "<C-CR>", "<cmd>Sap set_root<cr>", desc = "Set as root" },
        { "R", "<cmd>Sap refresh<cr>", desc = "Refresh" },
        { "q", "<cmd>Sap quit<cr>", desc = "Close" },
        { ".", "<cmd>Sap toggle_hidden<cr>", desc = "Toggle hidden" },
        { "l", "<cmd>Sap expand<cr>", desc = "Expand directory" },
        { "h", "<cmd>Sap collapse<cr>", desc = "Collapse directory" },
        { ">>", "<cmd>Sap indent<cr>", desc = "Indent" },
        { "<<", "<cmd>Sap unindent<cr>", desc = "Unindent" },
        { ">", "<cmd>Sap indent<cr>", mode = "v", desc = "Indent" },
        { "<", "<cmd>Sap unindent<cr>", mode = "v", desc = "Unindent" },
        { "p", "<cmd>Sap paste<cr>", desc = "Smart paste" },
        { "P", "<cmd>Sap paste_before<cr>", desc = "Smart paste before" },
    },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
    M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
end

return M
