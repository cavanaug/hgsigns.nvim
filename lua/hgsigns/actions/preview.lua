local async = require('hgsigns.async')
local cache = require('hgsigns.cache').cache
local config = require('hgsigns.config').config
local DeletedPreview = require('hgsigns.deleted_preview')
local HunkPreview = require('hgsigns.hunk_preview')
local Hunks = require('hgsigns.hunks')
local popup = require('hgsigns.popup')

local api = vim.api
local current_buf = api.nvim_get_current_buf

--- @class hgsigns.preview
local M = {}

local ns_inline = api.nvim_create_namespace('hgsigns_preview_inline')
local window_ns_supported = api.nvim__ns_set ~= nil
local inline_bufnr --- @type integer?
local inline_winid --- @type integer?

--- @async
--- @param bufnr integer
--- @param greedy? boolean
--- @return Hgsigns.Hunk.Hunk? hunk
local function get_hunk(bufnr, greedy)
  local bcache = cache[bufnr]
  if not bcache then
    return
  end

  return bcache:get_hunk(nil, greedy)
end

--- Get the greedy hunk at the cursor for popup preview.
--- @param bcache Hgsigns.CacheEntry
--- @async
--- @return Hgsigns.Hunk.Hunk? hunk
--- @return integer? index
--- @return integer total
local function get_hunk_at_cursor(bcache)
  --- @type Hgsigns.Hunk.Hunk[]
  local hunks = bcache:get_hunks(true, false) or {}
  local hunk, index = bcache:get_cursor_hunk(hunks)
  if hunk then
    return hunk, index, #hunks
  end

  return nil, nil, 0
end

local function clear_preview_inline(bufnr)
  api.nvim_buf_clear_namespace(bufnr, ns_inline, 0, -1)
  if inline_bufnr == bufnr then
    inline_bufnr = nil
    inline_winid = nil
    if window_ns_supported then
      api.nvim__ns_set(ns_inline, { wins = {} })
    end
  end
end

--- @param keys string
local function feedkeys(keys)
  local cy = api.nvim_replace_termcodes(keys, true, false, true)
  api.nvim_feedkeys(cy, 'nx', false)
end

--- @param bufnr integer
--- @param nsw integer
--- @param hunk Hgsigns.Hunk.Hunk
local function show_added(bufnr, nsw, hunk)
  local start_row = hunk.added.start - 1

  for offset = 0, hunk.added.count - 1 do
    local row = start_row + offset
    api.nvim_buf_set_extmark(bufnr, nsw, row, 0, {
      end_row = row + 1,
      hl_group = 'GitSignsAddPreview',
      hl_eol = true,
      priority = 1000,
    })
  end

  local _, added_regions =
    require('hgsigns.diff_int').run_word_diff(hunk.removed.lines, hunk.added.lines)

  for _, region in ipairs(added_regions) do
    local offset, rtype, scol, ecol = region[1] - 1, region[2], region[3] - 1, region[4] - 1

    -- Special case to handle cr at eol in buffer but not in show text
    local cr_at_eol_change = rtype == 'change'
      and vim.endswith(assert(hunk.added.lines[offset + 1]), '\r')

    api.nvim_buf_set_extmark(bufnr, nsw, start_row + offset, scol, {
      end_col = ecol,
      strict = not cr_at_eol_change,
      hl_group = rtype == 'add' and 'GitSignsAddInline'
        or rtype == 'change' and 'GitSignsChangeInline'
        or 'GitSignsDeleteInline',
      priority = 1001,
    })
  end
end

--- Preview the hunk at the cursor position in a floating
--- window. If the preview is already open, calling this
--- will cause the window to get focus.
function M.preview_hunk()
  if popup.is_open('hunk') then
    popup.focus_open('hunk')
    return
  end

  local bcache = cache[current_buf()]
  if not bcache then
    return
  end

  local hunk, index, total = async.run(get_hunk_at_cursor, bcache):wait()

  if not hunk or not index then
    return
  end

  --- @type Hgsigns.LineSpec[]
  local linespec = {
    { { ('Hunk %d of %d'):format(index, total), 'Title' } },
  }

  vim.list_extend(
    linespec,
    HunkPreview.linespec_for_hunk(
      bcache.bufnr,
      hunk,
      assert(bcache.compare_text),
      bcache.bufnr,
      hunk.added
    )
  )

  popup.create(linespec, config.preview_config, 'hunk')
end

--- Preview the hunk at the cursor position inline in the buffer.
--- @async
--- @return integer? markid
function M.preview_hunk_inline()
  local bufnr = current_buf()
  local winid = api.nvim_get_current_win()

  local hunk = get_hunk(bufnr, true)

  if not hunk then
    return
  end

  if inline_bufnr and (inline_bufnr ~= bufnr or inline_winid ~= winid) then
    api.nvim_buf_clear_namespace(inline_bufnr, ns_inline, 0, -1)
  end

  clear_preview_inline(bufnr)

  if window_ns_supported then
    api.nvim__ns_set(ns_inline, { wins = { winid } })
  end

  inline_bufnr = bufnr
  inline_winid = winid

  local preview_id --- @type integer?
  show_added(bufnr, ns_inline, hunk)
  if hunk.removed.count > 0 then
    preview_id = DeletedPreview.place_inline_preview_lines(bufnr, ns_inline, hunk, nil, {
      win = winid,
      lno_hl = true,
      leftcol = true,
      word_diff = true,
    })
  end

  api.nvim_create_autocmd({ 'CursorMoved', 'InsertEnter', 'BufLeave' }, {
    buffer = bufnr,
    desc = 'Clear hgsigns inline preview',
    callback = function()
      clear_preview_inline(bufnr)
    end,
    once = true,
  })

  -- Virtual lines will be hidden if they are placed on the top row, so
  -- automatically scroll the viewport.
  if hunk.removed.count > 0 and hunk.added.start <= 1 then
    feedkeys(hunk.removed.count .. '<C-y>')
  end

  return preview_id
end

--- @param bufnr integer
--- @return boolean
function M.has_preview_inline(bufnr)
  if inline_bufnr ~= bufnr then
    return false
  end

  if window_ns_supported and inline_winid ~= api.nvim_get_current_win() then
    return false
  end

  return #api.nvim_buf_get_extmarks(bufnr, ns_inline, 0, -1, { limit = 1 }) > 0
end

return M
