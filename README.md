# sap.nvim

A tree-style file manager for Neovim. Edit the buffer to rename, move, copy, create, and delete files.

## Features

- **Tree navigation**: Directories shown with expandable/collapsible children
- **Edit to operate**: Rename files by editing text, delete by removing lines, move by changing indentation
- **Copy support**: Yank and paste lines to copy files
- **In-place navigation**: Go to parent or set a subdirectory as root without losing context
- **Pending edits**: Changes are tracked and only applied when you save (`:w`)
- **Confirmation dialog**: Review all changes before they're applied
- **Icons**: Optional integration with nvim-web-devicons

## Installation

### lazy.nvim

```lua
{
    "username/sap.nvim",
    opts = {},
    keys = {
        { "-", "<cmd>Sap<cr>", desc = "Open file manager" },
    },
}
```

### packer.nvim

```lua
use {
    "username/sap.nvim",
    config = function()
        require("sap").setup()
        vim.keymap.set("n", "-", "<cmd>Sap<cr>")
    end
}
```

## Usage

Open the file manager with `:Sap [path]` or your configured keymap.

### Basic Operations

| Operation | How |
|-----------|-----|
| **Open file** | `<CR>` on a file |
| **Expand/collapse directory** | `<CR>`, `l`, or `h` on a directory |
| **Go to parent directory** | `<BS>` |
| **Set directory as root** | `<C-CR>` on a directory |
| **Toggle hidden files** | `.` |
| **Refresh** | `R` |
| **Close** | `q` |

### File Operations

Edit the buffer like any text file, then save with `:w` to apply changes:

| Operation | How |
|-----------|-----|
| **Rename** | Edit the filename |
| **Delete** | Delete the line (`dd`) |
| **Create file** | Add a new line with filename |
| **Create directory** | Add a new line ending with `/` |
| **Move** | Change indentation to move under different parent |
| **Copy** | Yank line (`yy`), paste (`p`) - original stays, new copy created |

Use `>>` / `<<` (normal) or `>` / `<` (visual) to indent/unindent while preserving internal state.

### Example Workflow

```
project/
    src/
        main.lua
        utils.lua
    README.md
```

1. Rename `utils.lua` to `helpers.lua`: edit the text
2. Move `helpers.lua` to project root: unindent with `<<`
3. Delete `README.md`: press `dd`
4. Create `docs/`: add new line `docs/`
5. Save with `:w` and confirm changes

## Configuration

```lua
require("sap").setup({
    -- Show hidden files (dotfiles) by default
    show_hidden = false,

    -- Indentation width
    indent_size = 4,

    -- Icon configuration
    icons = {
        use_devicons = true,  -- Use nvim-web-devicons if available
        directory = "",
        file = "",
    },

    -- Keymaps (set to false to disable all default keymaps)
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
    },
})
```

### Custom Keymaps

```lua
require("sap").setup({
    keys = {
        { "<CR>", "<cmd>Sap open<cr>" },
        { "-", "<cmd>Sap parent<cr>" },
        -- Add your own...
    },
})
```

### Disable Default Keymaps

```lua
require("sap").setup({
    keys = false,
})
```

## How It Works

Sap displays your filesystem as an editable buffer. Each line has a hidden ID prefix (concealed from view) that tracks the entry through edits. When you save:

1. The buffer is parsed to determine intended paths based on names and indentation
2. Changes are calculated by comparing buffer state to filesystem state
3. A confirmation dialog shows all pending operations
4. Operations are applied in order: creates, copies, moves, deletes

This approach means you can use all your familiar Vim motions and operations—the plugin figures out what filesystem operations are needed.

## Similar Projects

- [oil.nvim](https://github.com/stevearc/oil.nvim) - Edit filesystem like a buffer (flat view)
- [neo-tree.nvim](https://github.com/nvim-neo-tree/neo-tree.nvim) - Feature-rich file explorer
- [nvim-tree.lua](https://github.com/nvim-tree/nvim-tree.lua) - File explorer with git integration

## License

MIT
