local api = vim.api

--- @class Hgsigns.Hldef
--- @field [integer] string
--- @field desc string
--- @field hidden? boolean
--- @field fg_factor? number

local M = {}
local cmix --- @type fun(x?: integer, factor: number): integer?

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
  local hl = ('Hgsigns%s%s'):format(cty, kind)

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

  local fallbacks --- @type string[]
  if ty == 'changedelete' then
    fallbacks = { 'Hgsigns' .. capitalise('change') .. kind }
  elseif ty == 'topdelete' then
    fallbacks = { 'Hgsigns' .. capitalise('delete') .. kind }
  elseif ty == 'untracked' then
    fallbacks = { 'Hgsigns' .. capitalise('add') .. kind }
  elseif kind == 'Nr' or kind == 'Cul' then
    fallbacks = { ('Hgsigns%s'):format(cty) }
  elseif kind == 'Ln' then
    fallbacks = { ('Diff%s'):format(cty) }
  else
    -- base sign hl: fall back to nvim built-in diff groups
    fallbacks = {
      ty == 'add' and 'Added'
        or ty == 'delete' and 'Removed'
        or ty == 'change' and 'Changed'
        or '???',
      ('Diff%s'):format(cty),
    }
  end

  --- @type Hgsigns.Hldef
  local spec = {
    desc = ("Used for %s of '%s' signs."):format(what, ty),
    unpack(fallbacks),
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
  { HgsignsAddPreview = { desc = 'Used for added lines in previews.' } },
  { HgsignsDeletePreview = { desc = 'Used for deleted lines in previews.' } },
  { HgsignsNoEOLPreview = { desc = 'Used for "No newline at end of file".' } },
  { HgsignsCurrentLineBlame = { 'NonText', desc = 'Used for current line blame.' } },
  { HgsignsAddInline = { desc = 'Used for added word diff regions in inline previews.' } },
  { HgsignsDeleteInline = { desc = 'Used for deleted word diff regions in inline previews.' } },
  { HgsignsChangeInline = { desc = 'Used for changed word diff regions in inline previews.' } },
  {
    HgsignsAddLnInline = {
      desc = 'Used for added word diff regions when `config.word_diff == true`.',
    },
  },
  {
    HgsignsChangeLnInline = {
      desc = 'Used for changed word diff regions when `config.word_diff == true`.',
    },
  },
  {
    HgsignsDeleteLnInline = {
      desc = 'Used for deleted word diff regions when `config.word_diff == true`.',
    },
  },
  {
    HgsignsDeleteVirtLn = {
      desc = 'Used for deleted lines shown by inline `preview_hunk_inline()` or `show_deleted()`.',
    },
  },
  {
    HgsignsDeleteVirtLnInLine = {
      desc = 'Used for word diff regions in lines shown by inline `preview_hunk_inline()` or `show_deleted()`.',
    },
  },
  { HgsignsVirtLnum = { desc = 'Used for line numbers in inline hunks previews.' } },
})

local function dprintf(fmt, ...)
  dprintf = require('hgsigns.debug.log').dprintf
  dprintf(fmt, ...)
end

--- @param hl string
--- @return boolean
local function is_hl_set(hl)
  local exists, def = pcall(api.nvim_get_hl, 0, { name = hl, link = false })
  return exists and next(def) ~= nil
end

--- @param hl string
--- @param hldef Hgsigns.Hldef
--- @param is_bg_light boolean
local function derive(hl, hldef, is_bg_light)
  local fallbacks = hldef --- @type string[]
  if type(fallbacks[1]) == 'string' then
    for _, fb in ipairs(fallbacks) do
      if is_hl_set(fb) then
        api.nvim_set_hl(0, hl, { default = true, link = fb })
        dprintf('Derived %s from %s', hl, fb)
        return
      end
    end
    -- No fallback is set yet; link to first anyway so colorscheme can fill it in
    if fallbacks[1] and not hldef.fg_factor then
      api.nvim_set_hl(0, hl, { default = true, link = fallbacks[1] })
      dprintf('Could not derive %s, linked to %s', hl, fallbacks[1])
      return
    end
  end

  if hldef.fg_factor then
    local base = fallbacks[1] or hl
    local base_hl = api.nvim_get_hl(0, { name = base, link = false })
    local fg = base_hl.fg
    if fg then
      api.nvim_set_hl(0, hl, { fg = cmix(fg, hldef.fg_factor) })
      dprintf('Derived %s with fg_factor from %s', hl, base)
      return
    end
  end

  dprintf('No derivation found for %s', hl)
end

function M.setup_highlights()
  local is_bg_light = vim.o.background == 'light'
  for _, hlg in ipairs(M.hls) do
    for hl, hldef in pairs(hlg) do
      if is_hl_set(hl) then
        dprintf('Highlight %s is already defined', hl)
      else
        derive(hl, hldef, is_bg_light)
      end
    end
  end
end

function M.setup()
  M.setup_highlights()
  api.nvim_create_autocmd('ColorScheme', {
    group = 'hgsigns',
    callback = M.setup_highlights,
  })
end

--- @param x? integer
--- @param factor number
--- @return integer?
cmix = function(x, factor)
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
    local hl_name = ('HgsignsColorTemp.%s.%d'):format(fgs, color)
    api.nvim_set_hl(0, hl_name, { [fgs] = color })
    temp_colors[color] = hl_name
    return hl_name
  end
end

return M
