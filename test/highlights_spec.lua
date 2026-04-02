local Screen = require('nvim-test.screen')
local helpers = require('test.gs_helpers')

local clear = helpers.clear
local command = helpers.api.nvim_command

local cleanup = helpers.cleanup
local test_config = helpers.test_config
local expectf = helpers.expectf
local match_dag = helpers.match_dag
local p = helpers.p
local setup_hgsigns = helpers.setup_hgsigns
local eq = helpers.eq

helpers.env()

describe('highlights', function()
  local screen --- @type test.screen
  local config --- @type Hgsigns.Config

  before_each(function()
    clear()
    screen = Screen.new(20, 17)
    screen:attach()

    local default_attrs = {
      [1] = { foreground = Screen.colors.DarkBlue, background = Screen.colors.WebGray },
      [2] = { foreground = Screen.colors.NvimDarkCyan },
      [3] = { background = Screen.colors.LightBlue },
      [4] = { foreground = Screen.colors.NvimDarkRed },
      [5] = { foreground = Screen.colors.Brown },
      [6] = { foreground = Screen.colors.Blue1, bold = true },
      [7] = { bold = true },
      [8] = { foreground = Screen.colors.White, background = Screen.colors.Red },
      [9] = { foreground = Screen.colors.SeaGreen, bold = true },
    }

    -- Use the classic vim colorscheme, not the new defaults in nvim >= 0.10
    if helpers.fn.has('nvim-0.10') > 0 then
      command('colorscheme vim')
    else
      default_attrs[2] = { background = Screen.colors.LightMagenta }
      default_attrs[4] =
        { background = Screen.colors.LightCyan1, bold = true, foreground = Screen.colors.Blue1 }
    end

    screen:set_default_attr_ids(default_attrs)

    config = vim.deepcopy(test_config)
  end)

  after_each(function()
    cleanup()
    screen:detach()
  end)

  it('get set up correctly', function()
    command('set termguicolors')

    config.numhl = true
    config.linehl = true
    config._test_mode = true

    setup_hgsigns(config)

    local nvim10 = helpers.fn.has('nvim-0.10') > 0

    expectf(function()
      match_dag({
        p('Deriving HgsignsAdd from ' .. (nvim10 and 'Added' or 'DiffAdd')),
        p('Deriving HgsignsAddLn from DiffAdd'),
        p('Deriving HgsignsAddNr from HgsignsAdd'),
        p('Deriving HgsignsChangeLn from DiffChange'),
        p('Deriving HgsignsChangeNr from HgsignsChange'),
        p('Deriving HgsignsDelete from ' .. (nvim10 and 'Removed' or 'DiffDelete')),
        p('Deriving HgsignsDeleteNr from HgsignsDelete'),
      })
    end)
  end)

  it('update when colorscheme changes', function()
    command('set termguicolors')
    config.linehl = true
    setup_hgsigns(config)
  end)

  it('get_temp_hl handles equal min/max', function()
    helpers.setup_path()
    local res = helpers.exec_lua(function()
      vim.api.nvim_set_hl(0, 'Normal', { bg = 0x000000 })

      package.loaded['hgsigns.highlight'] = nil
      local hl = require('hgsigns.highlight')

      local name = hl.get_temp_hl(0, 0, 0, 0.5, true)
      local info = vim.api.nvim_get_hl(0, { name = name, link = false })
      return { name = name, fg = info.fg }
    end)

    assert(res.name:match('^HgsignsColorTemp%.fg%.%d+$') ~= nil)
    eq(0x00007F, res.fg)
  end)

  it('does not generate staged highlight groups', function()
    helpers.setup_path()

    local names = helpers.exec_lua(function()
      package.loaded['hgsigns.highlight'] = nil
      local highlight = require('hgsigns.highlight')
      local result = {}
      for _, spec in ipairs(highlight.hls) do
        result[#result + 1] = next(spec)
      end
      table.sort(result)
      return result
    end)

    assert(vim.tbl_contains(names, 'HgsignsAdd'))
    eq(false, vim.tbl_contains(names, 'HgsignsStagedAdd'))
    eq(false, vim.tbl_contains(names, 'HgsignsStagedDelete'))

    for _, name in ipairs(names) do
      assert(not name:match('^HgsignsStaged'), table.concat(names, '\n'))
    end
  end)
end)
