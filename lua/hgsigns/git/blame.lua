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
--- @param line table
--- @param summary? string First line of the changeset description.
--- @return string sha
--- @return Hgsigns.CommitInfo
local function parse_hg_commit(filename, line, summary)
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
  if summary == nil or summary == '' then
    summary = 'Version of ' .. filename
  end

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

  -- Collect unique non-null shas from the annotate output.
  local NULL_SHA = string.rep('0', 40)
  local unique_shas = {} --- @type table<string, true>
  for _, line in ipairs(lines) do
    if type(line.node) == 'string' and line.node ~= NULL_SHA then
      unique_shas[line.node] = true
    end
  end

  -- Batch-fetch parent and rename info for all unique shas in a single hg log
  -- call, instead of one subprocess per changeset.
  --
  -- Output format (one or more lines per revision):
  --   "{sha} {p1sha}"               — revision header (both are 40-char hex)
  --   "{sha} copy {newname}\t{src}" — one line per copy/rename entry
  --
  -- \t is safe as the name/source separator: Mercurial forbids tabs in paths.
  -- The "copy" prefix makes the two line types unambiguous in the parser.
  local parent_map = {} --- @type table<string, string>   -- sha -> parent sha
  local copies_map = {} --- @type table<string, string>   -- sha -> prev filename
  local desc_map = {} --- @type table<string, string>     -- sha -> commit summary

  local sha_list = vim.tbl_keys(unique_shas)
  if #sha_list > 0 then
    local revset = table.concat(sha_list, ' or ')

    -- Emit, per revision:
    --   "{sha} {p1sha}"                    — revision header
    --   "desc {sha} {first line of desc}"  — commit summary (firstline has no \n)
    --   "copy {sha} {newname}\t{source}"   — one per copy/rename entry
    local log_out = obj.repo:command({
      'log',
      '-r',
      revset,
      '--copies',
      '--template',
      '{node} {p1node}\ndesc {node} {desc|firstline}{file_copies % "\ncopy {node} {name}\t{source}"}\n',
    }, { ignore_error = true })

    for _, ln in ipairs(log_out) do
      if ln:sub(1, 4) == 'copy' then
        -- copy entry: "copy {sha} {newname}\t{oldname}"
        local sha_c = ln:sub(6, 45)
        if sha_c:match('^%x+$') and ln:sub(46, 46) == ' ' then
          local rest = ln:sub(47)
          local tab = rest:find('\t', 1, true)
          if tab then
            local dst = rest:sub(1, tab - 1)
            local src = rest:sub(tab + 1)
            if dst == filename then
              copies_map[sha_c] = src
            end
          end
        end
      elseif ln:sub(1, 5) == 'desc ' then
        -- desc entry: "desc {sha} {summary}"
        local sha_d = ln:sub(6, 45)
        if sha_d:match('^%x+$') and ln:sub(46, 46) == ' ' then
          desc_map[sha_d] = ln:sub(47)
        end
      else
        -- revision header: "{sha} {p1sha}"
        local sha_out = ln:sub(1, 40)
        local p1 = ln:sub(42, 81)
        if sha_out:match('^%x+$') and p1:match('^%x+$') and p1 ~= NULL_SHA then
          parent_map[sha_out] = p1
        end
      end
    end
  end

  -- Build the result table using the pre-fetched maps — O(1) subprocess calls
  -- regardless of how many unique changesets the file has.
  for final_lnum, line in ipairs(lines) do
    if type(line) ~= 'table' then
      error(
        ('Malformed hg annotate line %d for %s: %s'):format(final_lnum, filename, vim.inspect(line))
      )
    end

    local sha, commit = parse_hg_commit(filename, line, desc_map[line.node])
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

    local parent_sha = parent_map[sha]
    local previous_sha --- @type string?
    local previous_filename --- @type string?
    if parent_sha then
      previous_sha = parent_sha
      previous_filename = copies_map[sha] or filename
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
--- @param _lnum? integer|[integer, integer]
--- @param revision? string
--- @param opts? Hgsigns.BlameOpts
--- @return table<integer, Hgsigns.BlameInfo>
--- @return table<string, Hgsigns.CommitInfo?>
function M.run_blame(obj, contents, _lnum, revision, opts)
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

return M
