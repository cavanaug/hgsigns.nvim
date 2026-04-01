local helpers = require('test.gs_helpers')

local clear = helpers.clear
local eq = helpers.eq
local exec_lua = helpers.exec_lua

helpers.env()

describe('hgsigns entrypoint', function()
  before_each(function()
    clear()
    helpers.setup_path()
  end)

  it(
    'hgsigns_entrypoint_spec loads through the renamed top-level module without loading gitsigns',
    function()
      local result = exec_lua(function()
        package.loaded.hgsigns = nil
        package.loaded.gitsigns = nil

        local ok, mod = pcall(require, 'hgsigns')

        return {
          ok = ok,
          mod_type = type(mod),
          gitsigns_loaded = package.loaded.gitsigns ~= nil,
        }
      end)

      eq(true, result.ok)
      eq('table', result.mod_type)
      eq(false, result.gitsigns_loaded)
    end
  )
end)
