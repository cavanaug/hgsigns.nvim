local config = require('hgsigns.config').config

--- @async
--- @param a string[]
--- @param b string[]
--- @param linematch? boolean
--- @return Hgsigns.Hunk.Hunk[] hunks
return function(a, b, linematch)
  -- -- Short circuit optimization
  -- if not a or #a == 0 then
  --   local Hunks = require('hgsigns.hunks')
  --   local hunk = Hunks.create_hunk(0, 0, 1, #b)
  --   hunk.added.lines = b
  --   return { hunk }
  -- end

  if config.diff_opts.internal then
    return require('hgsigns.diff_int').run_diff(a, b, linematch)
  else
    return require('hgsigns.diff_ext').run_diff(a, b)
  end
end
