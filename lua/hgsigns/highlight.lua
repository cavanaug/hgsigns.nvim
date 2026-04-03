local api = vim.api

--- @class Hgsigns.Hldef
--- @field [integer] string
--- @field desc string
--- @field hidden? boolean
--- @field fg_factor? number

local M = {}

-- hgsigns reuses GitSigns highlight groups directly rather than defining its
-- own Hgsigns* groups.  This keeps the two sibling plugins visually consistent
-- — a single colorscheme / highlight customisation applies to both Git and
-- Mercurial signs without any extra user configuration.
--
-- The table below is exported for docgen only: each entry documents the
-- GitSigns* group that hgsigns will use so users know which groups to
-- customise.

--- Use array of dict so we can iterate deterministically
--- Export for docgen
--- @type table<string,Hgsigns.Hldef>[]
M.hls = {}

--- @param s string
--- @return string
local function capitalise(s)
  return s:sub(1, 1):upper() .. s:sub(2)
end

---@param kind ''|'Nr'|'Ln'|'Cul'
---@param ty 'add'|'change'|'delete'|'changedelete'|'topdelete'|'untracked'
---@return string? highlight
---@return Hgsigns.Hldef? spec
local function gen_hl(kind, ty)
  local cty = capitalise(ty)
  local hl = ('GitSigns%s%s'):format(cty, kind)

  if kind == 'Ln' and (ty == 'delete' or ty == 'topdelete') then
    return
  end

  local what --- @type string
  if kind == 'Nr' then
    what = 'number column (when `config.numhl == true`)'
  elseif kind == 'Ln' then
    what = 'buffer line (when `config.linehl == true`)'
  elseif kind == 'Cul' then
    what = 'the text (when the cursor is on the same line as the sign)'
  else
    what = 'the text'
  end

  --- @type Hgsigns.Hldef
  local spec = {
    desc = ("Used for %s of '%s' signs."):format(what, ty),
  }

  return hl, spec
end

for _, kind in ipairs({ '', 'Nr', 'Ln', 'Cul' }) do
  for _, ty in ipairs({ 'add', 'change', 'delete', 'changedelete', 'topdelete', 'untracked' }) do
    local hl, spec = gen_hl(kind, ty)
    if hl then
      table.insert(M.hls, { [hl] = spec })
    end
  end
end

vim.list_extend(M.hls, {
  { GitSignsAddPreview     = { desc = 'Used for added lines in previews.' } },
  { GitSignsDeletePreview  = { desc = 'Used for deleted lines in previews.' } },
  { GitSignsNoEOLPreview   = { desc = 'Used for "No newline at end of file".' } },
  { GitSignsCurrentLineBlame = { desc = 'Used for current line blame.' } },
  { GitSignsAddInline      = { desc = 'Used for added word diff regions in inline previews.' } },
  { GitSignsDeleteInline   = { desc = 'Used for deleted word diff regions in inline previews.' } },
  { GitSignsChangeInline   = { desc = 'Used for changed word diff regions in inline previews.' } },
  { GitSignsAddLnInline    = { desc = 'Used for added word diff regions when `config.word_diff == true`.' } },
  { GitSignsChangeLnInline = { desc = 'Used for changed word diff regions when `config.word_diff == true`.' } },
  { GitSignsDeleteLnInline = { desc = 'Used for deleted word diff regions when `config.word_diff == true`.' } },
  { GitSignsDeleteVirtLn   = { desc = 'Used for deleted lines shown by inline `preview_hunk_inline()` or `show_deleted()`.' } },
  { GitSignsDeleteVirtLnInLine = { desc = 'Used for word diff regions in lines shown by inline `preview_hunk_inline()` or `show_deleted()`.' } },
  { GitSignsVirtLnum       = { desc = 'Used for line numbers in inline hunks previews.' } },
})

-- No highlight setup needed: hgsigns relies entirely on GitSigns* groups which
-- are owned and registered by gitsigns.nvim.  If gitsigns is not installed the
-- user must define those groups themselves (or they fall back to Neovim's
-- built-in diff highlights).
function M.setup()
  -- Nothing to do — GitSigns* groups are not ours to create or derive.
end

local function dprintf(fmt, ...)
  dprintf = require('hgsigns.debug.log').dprintf
  dprintf(fmt, ...)
end

--- @param x? integer
--- @param factor number
--- @return integer?
local function cmix(x, factor)
  if not x or factor == 0 then
    return x
  end

  local r = math.floor(x / 2 ^ 16)
  local x1 = x - (r * 2 ^ 16)
  local g = math.floor(x1 / 2 ^ 8)
  local b = math.floor(x1 - (g * 2 ^ 8))

  local function mix(c, target, f)
    return math.floor(c + (target - c) * f)
  end

  -- If positive, lighten by mixing with 255 (white)
  -- If negative, darken by mixing with 0 (black)
  local target = factor > 0 and 255 or 0
  factor = math.abs(factor)

  r = mix(r, target, factor)
  g = mix(g, target, factor)
  b = mix(b, target, factor)

  return math.floor(r * 2 ^ 16 + g * 2 ^ 8 + b)
end

do --- temperature highlight
  local temp_colors = {} --- @type table<integer,string>
  local normal_bg --- @type [integer,integer,integer]?

  --- @param min integer
  --- @param max integer
  --- @param t integer
  --- @param alpha number 0-1
  --- @param fg? boolean
  --- @return string
  function M.get_temp_hl(min, max, t, alpha, fg)
    local Color = require('hgsigns.color')

    local denom = math.max(max, t) - min
    local normalized_t = denom ~= 0 and (t - min) / denom or 0
    local raw_temp_color = Color.temp(normalized_t)

    if normal_bg == nil then
      local normal_hl = api.nvim_get_hl(0, { name = 'Normal' })
      if normal_hl.bg then
        normal_bg = Color.int_to_rgb(normal_hl.bg)
      elseif vim.o.background == 'light' then
        normal_bg = { 255, 255, 255 } -- white
      else
        normal_bg = { 0, 0, 0 } -- black
      end
    end

    local color = Color.rgb_to_int(Color.blend(raw_temp_color, normal_bg, alpha))

    if temp_colors[color] then
      return temp_colors[color]
    end

    local fgs = fg and 'fg' or 'bg'
    local hl_name = ('GitSignsColorTemp.%s.%d'):format(fgs, color)
    api.nvim_set_hl(0, hl_name, { [fgs] = color })
    temp_colors[color] = hl_name
    return hl_name
  end
end

return M
