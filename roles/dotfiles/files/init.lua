-- kali-forge neovim config — managed by Ansible
-- Deliberately plugin-free. A plugin manager is one more thing to keep in
-- sync across two machines and one more thing to break on a fresh install.
-- If you add plugins later, pin them with a lockfile committed to this repo.

vim.opt.number         = true
vim.opt.relativenumber = true
vim.opt.expandtab      = true
vim.opt.shiftwidth     = 2
vim.opt.tabstop        = 2
vim.opt.smartindent    = true
vim.opt.wrap           = false
vim.opt.ignorecase     = true
vim.opt.smartcase      = true
vim.opt.incsearch      = true
vim.opt.hlsearch       = false
vim.opt.scrolloff      = 8
vim.opt.signcolumn     = "yes"
vim.opt.updatetime     = 250
vim.opt.termguicolors  = true
vim.opt.clipboard      = "unnamedplus"
vim.opt.undofile       = true
vim.opt.swapfile       = false

vim.g.mapleader = " "

-- Write and quit without contorting your fingers
vim.keymap.set("n", "<leader>w", "<cmd>w<cr>")
vim.keymap.set("n", "<leader>q", "<cmd>q<cr>")

-- Keep the cursor centred when jumping
vim.keymap.set("n", "<C-d>", "<C-d>zz")
vim.keymap.set("n", "<C-u>", "<C-u>zz")
vim.keymap.set("n", "n", "nzzzv")
vim.keymap.set("n", "N", "Nzzzv")

-- Paste over a selection without losing the register
vim.keymap.set("x", "<leader>p", [["_dP]])

-- Move selected lines
vim.keymap.set("v", "J", ":m '>+1<CR>gv=gv")
vim.keymap.set("v", "K", ":m '<-2<CR>gv=gv")

-- Highlight on yank
vim.api.nvim_create_autocmd("TextYankPost", {
  callback = function() vim.highlight.on_yank({ timeout = 150 }) end,
})

-- Markdown notes: soft wrap, spell check
vim.api.nvim_create_autocmd("FileType", {
  pattern = "markdown",
  callback = function()
    vim.opt_local.wrap = true
    vim.opt_local.linebreak = true
    vim.opt_local.spell = true
  end,
})
