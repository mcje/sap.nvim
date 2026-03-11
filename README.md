# sap.nvim

A tree-style file manager for Neovim. Edit the buffer to rename, move, copy, create, and delete files.

## Requirements

- Neovim 0.8+
- Optional: [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) for file icons

## Installation

```lua
-- lazy.nvim
{
    "username/sap.nvim",
    opts = {},
    keys = {
        { "-", "<cmd>Sap<cr>", desc = "Open file manager" },
    },
}
```

## Usage

Open with `:Sap [path]` or your configured keymap.

### Navigation

| Key | Action |
|-----|--------|
| `<CR>` | Open file / toggle directory |
| `l` / `h` | Expand / collapse directory |
| `<BS>` | Go to parent directory |
| `<C-CR>` | Set directory as root |
| `.` | Toggle hidden files |
| `R` | Refresh |
| `q` | Close |

### File Operations

Edit the buffer, then `:w` to apply changes:

| Operation | How |
|-----------|-----|
| Rename | Edit the filename |
| Delete | Delete the line (`dd`) |
| Create file | Add a new line |
| Create directory | Add a new line ending with `/` |
| Move | Change indentation (`>>` / `<<`) |
| Copy | Yank (`yy`) and paste (`p`) |

## Configuration

```lua
require("sap").setup({
    show_hidden = false,
    indent_size = 4,
    delete_method = "trash",  -- "trash" or "permanent"
    save_scope = "global",    -- "global" or "view"
})
```

See [config.lua](lua/sap/config.lua) for all options.

## TODO

- [ ] Symlink creation
- [ ] Preview file contents
- [ ] Trash management (list, restore, purge)
- [ ] Git status indicators

## Known Issues

- Toggling hidden files (`.`) requires saving changes first (causes full refresh)

## Similar Projects

- [oil.nvim](https://github.com/stevearc/oil.nvim) - Edit filesystem like a buffer (flat view)
- [neo-tree.nvim](https://github.com/nvim-neo-tree/neo-tree.nvim) - Feature-rich file explorer
- [nvim-tree.lua](https://github.com/nvim-tree/nvim-tree.lua) - File explorer with git integration

## License

MIT
