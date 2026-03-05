-- Minimal init for running tests
-- Run with: nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/sap"

-- Add current directory to runtime path
vim.opt.rtp:prepend(".")

-- Add plenary to rtp (adjust path as needed for your setup)
local plenary_path = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
if vim.fn.isdirectory(plenary_path) == 1 then
    vim.opt.rtp:prepend(plenary_path)
end

-- Alternatively for packer users:
-- vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/site/pack/packer/start/plenary.nvim")
