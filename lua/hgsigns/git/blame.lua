local uv = vim.uv or vim.loop ---@diagnostic disable-line: deprecated

local error_once = require('hgsigns.message').error_once
local log = require('hgsigns.debug.log')
local util = require('hgsigns.util')

--- @class Hgsigns.CommitInfo
--- @field author string
--- @field author_mail string
--- @field author_time integer
--- @field author_tz string
--- @field committer string
--- @field committer_mail string
--- @field committer_time integer
--- @field committer_tz string
--- @field summary string
--- @field sha string
--- @field abbrev_sha string
--- @field boundary? true

--- @class Hgsigns.BlameInfoPublic: Hgsigns.BlameInfo, Hgsigns.CommitInfo
--- @field body? string[]
--- @field hunk_no? integer
--- @field num_hunks? integer
--- @field hunk? string[]
--- @field hunk_head? string

--- @class Hgsigns.BlameInfo
--- @field orig_lnum integer
--- @field final_lnum integer
--- @field commit Hgsigns.CommitInfo
--- @field filename string
--- @field previous_filename? string
--- @field previous_sha? string

local NOT_COMMITTED = {
  author = 'Not Committed Yet',
  author_mail = '<not.committed.yet>',
  committer = 'Not Committed Yet',
  committer_mail = '<not.committed.yet>',
}

local M = {}

--- @param file string
--- @return Hgsigns.CommitInfo
local function not_committed(file)
  local time = os.time()
  return {
    sha = string.rep('0', 40),
    abbrev_sha = string.rep('0', 8),
    author = 'Not Committed Yet',
    author_mail = '<not.committed.yet>',
    author_tz = '+0000',
    author_time = time,
    committer = 'Not Committed Yet',
    committer_time = time,
    committer_mail = '<not.committed.yet>',
    committer_tz = '+0000',
    summary = 'Version of ' .. file,
  }
end

--- @param file string
--- @param lnum integer
--- @return Hgsigns.BlameInfo
function M.get_blame_nc(file, lnum)
  return {
    orig_lnum = 0,
    final_lnum = lnum,
    commit = not_committed(file),
    filename = file,
  }
end

---@param x any
---@return integer
local function asinteger(x)
  return assert(util.tointeger(x))
end

--- @param readline fun(): string?
--- @param commits table<string,Hgsigns.CommitInfo?>
--- @param result table<integer,Hgsigns.BlameInfo>
local function incremental_iter(readline, commits, result)
  local line = assert(readline())

  local sha, orig_lnum_str, final_lnum_str, size_str = line:match('(%x+) (%d+) (%d+) (%d+)')
  if not sha then
    error(("Could not parse sha from line: '%s'"):format(line))
  end

  local orig_lnum = asinteger(orig_lnum_str)
  local final_lnum = asinteger(final_lnum_str)
  local size = asinteger(size_str)

  local commit = commits[sha]
    or {
      sha = sha,
      abbrev_sha = sha:sub(1, 8) --[[@as string]],
    }

  --- @type string?, string?
  local previous_sha, previous_filename

  line = assert(readline())

  -- filename terminates the entry
  while not line:match('^filename ') do
    local key, value = line:match('^([^%s]+) (.*)')
    if key == 'previous' then
      previous_sha, previous_filename = line:match('^previous (%x+) (.*)')
    elseif key then
      key = key:gsub('%-', '_') --- @type string
      if vim.endswith(key, '_time') then
        --- @diagnostic disable-next-line: assign-type-mismatch
        commit[key] = asinteger(value)
      else
        commit[key] = value
      end
    else
      --- @diagnostic disable-next-line: assign-type-mismatch
      commit[line] = true
      if line ~= 'boundary' then
        log.dprintf("Unknown tag: '%s'", line)
      end
    end
    line = assert(readline())
  end

  local filename = assert(line:match('^filename (.*)'))

  -- New in git 2.41:
  -- The output given by "git blame" that attributes a line to contents
  -- taken from the file specified by the "--contents" option shows it
  -- differently from a line attributed to the working tree file.
  if
    commit.author_mail == '<external.file>'
    or commit.author_mail == 'External file (--contents)'
  then
    commit = vim.tbl_extend('force', commit, NOT_COMMITTED)
  end
  commits[sha] = commit --[[@as Hgsigns.CommitInfo]]

  for j = 0, size - 1 do
    result[final_lnum + j] = {
      final_lnum = final_lnum + j,
      orig_lnum = orig_lnum + j,
      commit = commits[sha],
      filename = filename,
      previous_filename = previous_filename,
      previous_sha = previous_sha,
    }
  end
end

--- @param data string
--- @param partial? string
--- @return string[] lines
--- @return string? partial
local function data_to_lines(data, partial)
  local lines = vim.split(data, '\n')
  if partial then
    lines[1] = partial .. lines[1]
    partial = nil
  end

  -- if data doesn't end with a newline, then the last line is partial
  if lines[#lines] ~= '' then
    partial = lines[#lines]
  end

  -- Clear the last line as it will be empty of the partial line
  lines[#lines] = nil
  return lines, partial
end

--- @param f fun(readline: fun(): string?))
--- @return fun(data: string?)
local function buffered_line_reader(f)
  --- @param data string?
  return coroutine.wrap(function(data)
    if not data then
      return
    end

    local data_lines, partial_line = data_to_lines(data)
    local i = 0

    --- @async
    local function readline(peek)
      if not data_lines[i + 1] then
        -- No more data, wait for more
        data = coroutine.yield()
        if not data then
          -- No more data, return the partial line if there is one
          return partial_line
        end
        data_lines, partial_line = data_to_lines(data, partial_line)
        i = 0
      end

      if peek then
        return data_lines[i + 1]
      end
      i = i + 1
      return data_lines[i]
    end

    while readline(true) do
      f(readline)
    end
  end)
end

--- @param offset integer
--- @return string
local function hg_tz(offset)
  local sign = offset <= 0 and '+' or '-'
  offset = math.abs(offset)
  local hours = math.floor(offset / 3600)
  local minutes = math.floor((offset % 3600) / 60)
  return ('%s%02d%02d'):format(sign, hours, minutes)
end

--- @param user string?
--- @return string author
--- @return string author_mail
local function hg_user(user)
  user = vim.trim(user or '')
  local author, mail = user:match('^(.-)%s*<([^>]+)>$')
  if author and mail then
    author = vim.trim(author)
    if author ~= '' then
      return author, '<' .. mail .. '>'
    end
  end

  return user ~= '' and user or 'unknown', '<unknown>'
end

--- @param filename string
--- @param line table<string, any>
--- @return string sha
--- @return Hgsigns.CommitInfo
local function parse_hg_commit(filename, line)
  local sha = line.node
  if type(sha) ~= 'string' or not sha:match('^%x+$') then
    error(
      ('Malformed hg annotate record for %s: missing node in %s'):format(
        filename,
        vim.inspect(line)
      )
    )
  end

  local date = line.date
  if type(date) ~= 'table' then
    error(
      ('Malformed hg annotate record for %s: missing date in %s'):format(
        filename,
        vim.inspect(line)
      )
    )
  end

  local author_time = util.tointeger(date[1])
  local offset = util.tointeger(date[2])
  if not author_time or offset == nil then
    error(
      ('Malformed hg annotate record for %s: invalid date in %s'):format(
        filename,
        vim.inspect(line)
      )
    )
  end

  local author, author_mail = hg_user(line.user)
  local summary = 'Version of ' .. filename

  return sha,
    {
      sha = sha,
      abbrev_sha = sha:sub(1, 12),
      author = author,
      author_mail = author_mail,
      author_time = author_time,
      author_tz = hg_tz(offset),
      committer = author,
      committer_mail = author_mail,
      committer_time = author_time,
      committer_tz = hg_tz(offset),
      summary = summary,
    }
end

--- @async
--- @param obj Hgsigns.GitObj
--- @param revision? string
--- @param opts? Hgsigns.BlameOpts
--- @return table<integer, Hgsigns.BlameInfo>
--- @return table<string, Hgsigns.CommitInfo?>
local function run_blame_hg(obj, revision, opts)
  local ret = {} --- @type table<integer, Hgsigns.BlameInfo>
  local commits = {} --- @type table<string,Hgsigns.CommitInfo?>

  local stdout, stderr, code = obj.repo:command(
    util.flatten({
      'annotate',
      '--user',
      '--number',
      '--changeset',
      '--date',
      '--line-number',
      opts and opts.ignore_whitespace and '-w' or nil,
      opts and opts.extra_opts or nil,
      revision and { '--rev', revision } or nil,
      '--template',
      'json',
      '--',
      obj.relpath,
    }),
    {
      ignore_error = true,
    }
  )

  if code ~= 0 or stderr then
    local msg = 'Error running hg annotate: ' .. (stderr or tostring(code))
    error_once(msg)
    log.eprint(msg)
    error(msg)
  end

  local ok, decoded = pcall(vim.json.decode, table.concat(stdout, '\n'))
  if not ok then
    local msg = ('Failed to parse hg annotate JSON for %s: %s'):format(obj.relpath, decoded)
    log.eprint(msg)
    error(msg)
  end

  if type(decoded) ~= 'table' or type(decoded[1]) ~= 'table' then
    error(('Malformed hg annotate JSON for %s: %s'):format(obj.relpath, vim.inspect(decoded)))
  end

  local blob = decoded[1]
  local filename = blob.path
  local lines = blob.lines

  if type(filename) ~= 'string' or filename == '' then
    error(('Malformed hg annotate JSON for %s: missing path'):format(obj.relpath))
  end

  if type(lines) ~= 'table' then
    error(('Malformed hg annotate JSON for %s: missing lines'):format(obj.relpath))
  end

  local parent_cache = {} --- @type table<string,string>
  local parent_resolved = {} --- @type table<string,true>
  local previous_path_cache = {} --- @type table<string,string>
  local previous_path_resolved = {} --- @type table<string,true>

  for final_lnum, line in ipairs(lines) do
    if type(line) ~= 'table' then
      error(
        ('Malformed hg annotate line %d for %s: %s'):format(final_lnum, filename, vim.inspect(line))
      )
    end

    local sha, commit = parse_hg_commit(filename, line)
    commits[sha] = commits[sha] or commit

    local orig_lnum = util.tointeger(line.lineno)
    if not orig_lnum then
      error(
        ('Malformed hg annotate line %d for %s: missing lineno in %s'):format(
          final_lnum,
          filename,
          vim.inspect(line)
        )
      )
    end

    local parent_key = sha
    local parent_sha = parent_cache[parent_key] --- @type string?
    if not parent_resolved[parent_key] then
      parent_sha = obj.repo:get_parent_revision(sha)
      if parent_sha then
        parent_cache[parent_key] = parent_sha
      end
      parent_resolved[parent_key] = true
    end

    local previous_sha --- @type string?
    local previous_filename --- @type string?
    if parent_sha then
      local previous_key = sha .. '\0' .. filename
      local previous_path = previous_path_cache[previous_key] --- @type string?
      if not previous_path_resolved[previous_key] then
        previous_path = obj.repo:get_previous_path(sha, filename)
        if previous_path then
          previous_path_cache[previous_key] = previous_path
        end
        previous_path_resolved[previous_key] = true
      end

      if previous_path then
        previous_sha = parent_sha
        previous_filename = previous_path
      end
    end

    ret[final_lnum] = {
      final_lnum = final_lnum,
      orig_lnum = orig_lnum,
      commit = commits[sha],
      filename = filename,
      previous_sha = previous_sha,
      previous_filename = previous_filename,
    }
  end

  return ret, commits
end

--- @async
--- @param obj Hgsigns.GitObj
--- @param contents? string[]
--- @param lnum? integer|[integer, integer]
--- @param revision? string
--- @param opts? Hgsigns.BlameOpts
--- @return table<integer, Hgsigns.BlameInfo>
--- @return table<string, Hgsigns.CommitInfo?>
function M.run_blame(obj, contents, lnum, revision, opts)
  if obj.repo.vcs == 'hg' then
    if not obj.object_name or obj.repo.abbrev_head == '' then
      assert(contents, 'contents must be provided for untracked files')
      local ret = {} --- @type table<integer,Hgsigns.BlameInfo>
      local commit = not_committed(obj.file)
      for i in ipairs(contents) do
        ret[i] = {
          orig_lnum = 0,
          final_lnum = i,
          commit = commit,
          filename = obj.relpath or obj.file,
        }
      end
      return ret, {}
    end

    return run_blame_hg(obj, revision, opts)
  end

  local ret = {} --- @type table<integer,Hgsigns.BlameInfo>

  if not obj.object_name or obj.repo.abbrev_head == '' then
    assert(contents, 'contents must be provided for untracked files')
    -- As we support attaching to untracked files we need to return something if
    -- the file isn't isn't tracked in git.
    -- If abbrev_head is empty, then assume the repo has no commits
    local commit = not_committed(obj.file)
    for i in ipairs(contents) do
      ret[i] = {
        orig_lnum = 0,
        final_lnum = i,
        commit = commit,
        filename = obj.file,
      }
    end
    return ret, {}
  end

  --- @type Hgsigns.BlameOpts
  --- EmmyLuaLs/emmylua-analyzer-rust#921
  opts = opts or {}

  local ignore_file = obj.repo.toplevel .. '/.git-blame-ignore-revs'

  local commits = {} --- @type table<string,Hgsigns.CommitInfo?>

  local reader = buffered_line_reader(function(readline)
    incremental_iter(readline, commits, ret)
  end)

  --- @param data string?
  local function on_stdout(_, data)
    reader(data)
  end

  local contents_str = contents and table.concat(contents, '\n') or nil

  local _, stderr = obj.repo:command(
    util.flatten({
      'blame',
      '--incremental',
      contents and { '--contents', '-' },
      opts.ignore_whitespace and '-w' or nil,
      lnum and { '-L', type(lnum) == 'table' and (lnum[1] .. ',' .. lnum[2]) or (lnum .. ',+1') },
      opts.extra_opts,
      uv.fs_stat(ignore_file) and { '--ignore-revs-file', ignore_file },
      revision,
      '--',
      obj.relpath,
    }),
    {
      stdin = contents_str,
      stdout = on_stdout,
      ignore_error = true,
    }
  )

  if stderr then
    local msg = 'Error running git-blame: ' .. stderr
    error_once(msg)
    log.eprint(msg)
  end

  return ret, commits
end

return M
