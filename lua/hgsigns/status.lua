local api = vim.api

--- @class (exact) Hgsigns.StatusObj
--- @field added? integer
--- @field removed? integer
--- @field changed? integer
--- @field head? string
--- @field root? string
--- @field gitdir? string

local M = {}

--- @param bufnr integer
local function autocmd_update(bufnr)
  api.nvim_exec_autocmds('User', {
    pattern = 'HgsignsUpdate',
    modeline = false,
    data = { buffer = bufnr },
  })
end

--- @param bufnr integer
--- @param status Hgsigns.StatusObj
function M.update(bufnr, status)
  if not api.nvim_buf_is_loaded(bufnr) then
    return
  end
  local bstatus = vim.b[bufnr].hgsigns_status_dict
  if bstatus then
    status = vim.tbl_extend('force', bstatus, status)
  end

  if vim.deep_equal(bstatus, status) then
    return
  end

  vim.b[bufnr].hgsigns_head = status.head or ''
  vim.b[bufnr].hgsigns_status_dict = status

  local config = require('hgsigns.config').config

  vim.b[bufnr].hgsigns_status = config.status_formatter(status)

  autocmd_update(bufnr)
end

function M.clear(bufnr)
  if not api.nvim_buf_is_loaded(bufnr) then
    return
  end

  local b = vim.b[bufnr]

  if b.hgsigns_head == nil and b.hgsigns_status_dict == nil and b.hgsigns_status == nil then
    return
  end

  b.hgsigns_head = nil
  b.hgsigns_status_dict = nil
  b.hgsigns_status = nil
  autocmd_update(bufnr)
end

return M
