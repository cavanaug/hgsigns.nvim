-- Minimal nvim config for hgsigns demo recordings
-- Usage: nvim -u media/demo_init.lua <file>

vim.opt.termguicolors  = true
vim.opt.number         = true
vim.opt.relativenumber = false
vim.opt.signcolumn     = 'yes:1'
vim.opt.cursorline     = true
vim.opt.laststatus     = 2
vim.opt.ruler          = false
vim.opt.showcmd        = false
vim.opt.showmode       = false
vim.opt.cmdheight      = 1

vim.cmd('colorscheme habamax')
vim.cmd('syntax on')
vim.cmd('filetype on')

-- Load hgsigns from the repo under development
local repo = vim.fn.expand('<sfile>:p:h:h')
vim.opt.rtp:prepend(repo)

require('hgsigns').setup({
  signs = {
    add          = { text = '┃' },
    change       = { text = '┃' },
    delete       = { text = '▁' },
    topdelete    = { text = '▔' },
    changedelete = { text = '~' },
    untracked    = { text = '┆' },
  },
  signcolumn    = true,
  current_line_blame = true,
  current_line_blame_opts = {
    virt_text = true,
    virt_text_pos = 'eol',
    delay = 0,
  },
  preview_config = { border = 'rounded', row = 1, col = 1 },
  on_attach = function(buf)
    local hs = require('hgsigns')
    local map = function(m, l, r) vim.keymap.set(m, l, r, { buffer = buf, silent = true }) end
    map('n', ']h', function() hs.nav_hunk('next') end)
    map('n', '[h', function() hs.nav_hunk('prev') end)
    map('n', '<leader>gp', hs.preview_hunk)
    map('n', '<leader>gi', hs.preview_hunk_inline)
    map('n', '<leader>gr', hs.reset_hunk)
    map('n', '<leader>gb', function() hs.blame_line({ full = true }) end)
    map('n', '<leader>gB', hs.blame)
  end,
})
