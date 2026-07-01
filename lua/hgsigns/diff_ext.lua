local Hunks = require('hgsigns.hunks')

local async = require('hgsigns.async')
local scheduler = async.schedule

local asystem = async.wrap(3, require('hgsigns.system').system)

local M = {}

--- @param path string
--- @param text string[]
local function write_to_file(path, text)
  local f, err = io.open(path, 'wb')
  if f == nil then
    error(err)
  end
  for _, l in ipairs(text) do
    f:write(l)
    f:write('\n')
  end
  f:close()
end

--- @async
--- @param text_cmp string[]
--- @param text_buf string[]
--- @return Hgsigns.Hunk.Hunk[]
function M.run_diff(text_cmp, text_buf)
  local results = {} --- @type Hgsigns.Hunk.Hunk[]

  -- tmpname must not be called in a callback
  if vim.in_fast_event() then
    scheduler()
  end

  local file_buf = vim.fn.tempname()
  local file_cmp = vim.fn.tempname()

  write_to_file(file_buf, text_buf)
  write_to_file(file_cmp, text_cmp)

  -- Use the system `diff` tool to compare the two temp files. Mercurial's
  -- `hg diff` can only operate on paths inside a repository, so it cannot be
  -- used to diff arbitrary temp files; the POSIX `diff -U0` output uses the
  -- same `@@` unified-hunk format the parser below expects.
  local obj = asystem({
    'diff',
    '-U0',
    file_cmp,
    file_buf,
  }, {
    text = true,
  })
  scheduler()

  local out = vim.split(obj.stdout or '', '\n')

  for _, line in ipairs(out) do
    if vim.startswith(line, '@@') then
      results[#results + 1] = Hunks.parse_diff_line(line)
    elseif #results > 0 then
      local r = results[#results]
      --- @cast r -?
      if line:sub(1, 1) == '-' then
        r.removed.lines[#r.removed.lines + 1] = line:sub(2)
      elseif line:sub(1, 1) == '+' then
        r.added.lines[#r.added.lines + 1] = line:sub(2)
      end
    end
  end

  os.remove(file_buf)
  os.remove(file_cmp)
  return results
end

return M
