local async = require('hgsigns.async')
local git_command = require('hgsigns.git.cmd')
local config = require('hgsigns.config').config
local log = require('hgsigns.debug.log')
local util = require('hgsigns.util')
local Path = util.Path
local errors = require('hgsigns.git.errors')
local Watcher = require('hgsigns.git.repo.watcher')

local uv = vim.uv or vim.loop ---@diagnostic disable-line: deprecated

local normalize_path --- @type fun(path?: string): string?
local parse_hg_status_lines --- @type fun(lines: string[]): Hgsigns.Repo.HgStatusEntry[]?

--- @class Hgsigns.RepoInfo
--- @field gitdir string
--- @field toplevel string
--- @field detached boolean
--- @field abbrev_head string
--- @field head_oid? string

--- @class Hgsigns.Repo : Hgsigns.RepoInfo
---
--- Username configured for the repo.
--- Needed for to determine "You" in current line blame.
--- @field username string
--- @field private _lock Hgsigns.async.Semaphore
--- @field private _watcher? Hgsigns.Repo.Watcher
--- @field private _refs integer
--- @field head_oid? string
--- @field commondir string
local M = {}

--- @type table<string,Hgsigns.Repo?>
local repo_cache = setmetatable({}, { __mode = 'v' })

--- @param gitdir string?
--- @return boolean
local function is_hg_gitdir(gitdir)
  return gitdir ~= nil and gitdir:match('[\\/]%.hg$') ~= nil
end

--- @param stderr string?
--- @return boolean
local function is_not_in_hg_repo(stderr)
  return stderr ~= nil and stderr:match(errors.e.not_in_hg) ~= nil
end

--- @param stderr string?
--- @return boolean
local function is_missing_hg_revision_path(stderr)
  return stderr ~= nil and stderr:match(': no such file in rev ') ~= nil
end

--- @param file string
--- @return string
local function default_mode_bits(file)
  local stat = uv.fs_stat(file)
  if stat and stat.mode and bit.band(stat.mode, 0x49) ~= 0 then
    return '100755'
  end
  return '100644'
end

--- @param toplevel string
--- @param file string
--- @return string?
local function to_relpath(toplevel, file)
  local normalized_file = normalize_path(file)
  local normalized_root = normalize_path(toplevel)
  if not normalized_file or not normalized_root then
    return
  end

  if vim.startswith(normalized_file, normalized_root .. '/') then
    return normalized_file:sub(#normalized_root + 2)
  end

  if normalized_file == normalized_root then
    return vim.fs.basename(normalized_file)
  end

  return normalized_file
end

--- Registers a callback to be invoked on update events.
---
--- The provided callback function `cb` will be stored and called when an update
--- occurs. Returns a deregister function that, when called, will remove the
--- callback from the watcher.
---
--- @param callback fun() Callback function to be invoked on update.
--- @return fun() deregister Function to remove the callback from the watcher.
function M:on_update(callback)
  assert(self._watcher, 'Watcher not initialized')
  return self._watcher:on_update(callback)
end

--- Run a function while holding the repo lock.
--- This serializes git operations that mutate repo state such as the index.
--- @async
--- @generic R
--- @param fn async fun(): R...
--- @return R...
function M:lock(fn)
  return self._lock:with(fn)
end

--- Run an hg command with the repo's toplevel as cwd.
--- @async
--- @param args table<any,any>
--- @param spec? Hgsigns.Git.JobSpec
--- @return string[] stdout
--- @return string? stderr
--- @return integer code
function M:command(args, spec)
  spec = spec or {}
  spec.cwd = self.toplevel
  return git_command(args, spec)
end

--- @async
--- @param base string?
--- @param include_untracked? boolean
--- @return {path:string, oldpath?:string, status?:string, deleted?:boolean}[]
function M:files_changed(base, include_untracked)
  local ret = {} --- @type {path:string, oldpath?:string, status?:string, deleted?:boolean}[]

  local args = { 'status', '--copies' }
  if base and base ~= ':0' then
    vim.list_extend(args, { '--rev', base })
  end

  local parsed = parse_hg_status_lines(self:command(args)) or {}
  for _, entry in ipairs(parsed) do
    if entry.status ~= '?' or include_untracked then
      ret[#ret + 1] = {
        path = entry.path,
        oldpath = entry.oldpath,
        status = entry.status,
        deleted = entry.status == 'R' or nil,
      }
    end
  end
  return ret
end

--- @async
--- @param _attr string
--- @param files string[]
--- @return table<string,'set'|'unset'|'unspecified'|string>
function M:check_attr(_attr, files)
  local ret = {} --- @type table<string,'set'|'unset'|'unspecified'|string>

  if #files == 0 then
    return ret
  end

  -- Mercurial has no equivalent of git attributes; report everything as
  -- unspecified.
  for _, f in ipairs(files) do
    ret[f] = 'unspecified'
  end

  return ret
end

--- @param encoding string
--- @return boolean
local function iconv_supported(encoding)
  -- TODO(lewis6991): needs https://github.com/neovim/neovim/pull/21924
  if vim.startswith(encoding, 'utf-16') or vim.startswith(encoding, 'utf-32') then
    return false
  end
  return true
end

--- @async
--- Get version of file at a revision, return array of lines.
--- @param object string
--- @param encoding? string
--- @return string[] stdout, string? stderr
function M:get_show_text(object, encoding)
  local stdout, stderr = self:command(
    { 'cat', '-r', object },
    { text = false, ignore_error = true }
  )

  if encoding and encoding ~= 'utf-8' and iconv_supported(encoding) then
    for i, l in ipairs(stdout) do
      stdout[i] = vim.iconv(l, encoding, 'utf-8')
    end
  end

  return stdout, stderr
end

--- @async
--- Get version of file at revision. If the path was renamed after `revision`,
--- resolve the old path before reading the blob.
--- @param revision string
--- @param relpath string
--- @param encoding? string
--- @return string[] stdout, string? stderr
function M:get_show_text_at_revision(revision, relpath, encoding)
  local stdout, stderr = self:command({ 'cat', '-r', revision, relpath }, {
    text = false,
    ignore_error = true,
  })

  local missing_path = stderr
    and (
      is_missing_hg_revision_path(stderr)
      or stderr:match(errors.e.path_does_not_exist)
      or stderr:match(errors.e.path_exist_on_disk_but_not_in)
    )

  if missing_path then
    log.dprintf('%s not found in %s looking for renames', relpath, revision)
    local old_path = self:diff_rename_status(revision, true)[relpath]
      or self:log_rename_status(revision, relpath)
    if old_path then
      log.dprintf('found rename %s -> %s', old_path, relpath)
      stdout, stderr = self:command({ 'cat', '-r', revision, old_path }, {
        text = false,
        ignore_error = true,
      })
    end
  end

  if encoding and encoding ~= 'utf-8' and iconv_supported(encoding) then
    for i, l in ipairs(stdout) do
      stdout[i] = vim.iconv(l, encoding, 'utf-8')
    end
  end

  return stdout, stderr
end

--- @async
--- @param revision string
--- @return string?
function M:get_parent_revision(revision)
  local stdout = self:command({ 'parents', '-r', revision, '-T', '{node}\n' }, {
    ignore_error = true,
  })
  local parent = stdout[1]
  return parent ~= '' and parent or nil
end

--- @async
--- @param revision string
--- @param relpath string
--- @return string?
function M:get_previous_path(revision, relpath)
  local parsed = parse_hg_status_lines(self:command({
    'status',
    '--copies',
    '--change',
    revision,
    '--',
    relpath,
  }, { ignore_error = true })) or {}

  for _, entry in ipairs(parsed) do
    if entry.path == relpath then
      if entry.status == 'A' then
        return entry.oldpath
      end
      return relpath
    end
  end

  return relpath
end

--- @private
function M:_close()
  repo_cache[self.gitdir] = nil
  if self._watcher then
    self._watcher:close()
    self._watcher = nil
  end
end

function M:ref()
  self._refs = self._refs + 1
  return self
end

function M:unref()
  if self._refs == 0 then
    return
  end

  self._refs = self._refs - 1

  if self._refs == 0 then
    self:_close()
  end
end

--- @async
--- @private
--- @param info Hgsigns.RepoInfo
--- @return Hgsigns.Repo
function M._new(info)
  --- @type Hgsigns.Repo
  local self = setmetatable(info, { __index = M })
  self._lock = async.semaphore(1)
  self._refs = 0
  self.head_oid = info.head_oid

  -- Normalize `ui.username` to just the display name so it matches the author
  -- names produced from `hg annotate` output (which `blame` compares against to
  -- render "You"). Mercurial usernames are typically `Name <email>`.
  local raw_username = self:command({ 'config', 'ui.username' }, { ignore_error = true })[1]
  if raw_username then
    local name = raw_username:match('^(.-)%s*<[^>]+>$')
    self.username = (name and name ~= '' and name) or vim.trim(raw_username)
  end
  self.commondir = self.gitdir

  if config.watch_gitdir.enable then
    self._watcher = Watcher.new(self.gitdir, self.commondir)
    self._watcher:on_update(function()
      async
        .run(function()
          local info2 = M.get_info(self.toplevel, self.gitdir, self.toplevel)
          if not info2 then
            return
          end

          self.head_oid = info2.head_oid
          if self.abbrev_head ~= info2.abbrev_head then
            self.abbrev_head = info2.abbrev_head
            log.dprintf('HEAD changed, updating abbrev_head to %s', self.abbrev_head)
          end
        end)
        :raise_on_error()
    end)
  end

  return self
end

function M:has_watcher()
  return self._watcher ~= nil
end

local sem = async.semaphore(1)

--- @async
--- @param cwd? string
--- @param gitdir? string
--- @param toplevel? string
--- @return Hgsigns.Repo? repo
--- @return string? err
function M.get(cwd, gitdir, toplevel)
  --- EmmyLuaLs/emmylua-analyzer-rust#659
  --- @return Hgsigns.Repo? repo
  --- @return string? err
  return sem:with(function()
    local info, err = M.get_info(cwd, gitdir, toplevel)
    if not info then
      return nil, err
    end

    local repo = repo_cache[info.gitdir]
    if repo then
      -- Keep cached repo metadata in sync with the repo's current state.
      -- Without this, branch transitions can leave abbrev_head stale until a
      -- watcher callback runs.
      repo.abbrev_head = info.abbrev_head
      repo.detached = info.detached
      repo.head_oid = info.head_oid
    else
      repo = M._new(info)
      repo_cache[info.gitdir] = repo
    end
    repo:ref()
    return repo
  end)
end

local has_win_cygpath = vim.fn.has('win32') == 1 and vim.fn.executable('cygpath') == 1

--- Normalize repo discovery paths for comparisons and returned repo metadata.
--- On Windows with MSYS/Cygwin Git, convert `/c/...` style paths to mixed
--- Windows form before applying `vim.fs.normalize()`.
--- @async
--- @param path? string
--- @return string?
normalize_path = function(path)
  if not path then
    return
  end
  if has_win_cygpath then
    path = util.cygpath(path, 'mixed')
  end
  return vim.fs.normalize(path)
end

--- @async
--- @param dir? string
--- @param gitdir? string
--- @param worktree? string
--- @return Hgsigns.RepoInfo? info, string? err
local function get_info_hg(dir, gitdir, worktree)
  if gitdir and not is_hg_gitdir(gitdir) then
    return nil, errors.e.not_in_hg
  end

  local cwd = worktree or (gitdir and vim.fs.dirname(gitdir)) or dir
  local root_out, root_err, root_code = git_command({ 'root' }, {
    ignore_error = true,
    cwd = cwd,
  })

  if root_code > 0 then
    if is_not_in_hg_repo(root_err) then
      return nil, root_err
    end
    return nil, string.format('got stderr: %s', root_err or '')
  end

  local toplevel_r = normalize_path(root_out[1])
  if not toplevel_r then
    return nil, string.format('incomplete stdout: %s', table.concat(root_out, '\n'))
  end

  dir = normalize_path(dir)
  if dir and not vim.startswith(dir, toplevel_r) then
    log.dprintf("'%s' is outside worktree '%s'", dir, toplevel_r)
    return
  end

  local branch_out, branch_err, branch_code = git_command({ 'branch' }, {
    ignore_error = true,
    cwd = toplevel_r,
  })
  if branch_code > 0 then
    return nil, string.format('got stderr: %s', branch_err or '')
  end

  local parents_out, parents_err, parents_code = git_command(
    { 'parents', '--template', '{node}\n' },
    {
      ignore_error = true,
      cwd = toplevel_r,
    }
  )
  if parents_code > 0 then
    return nil, string.format('got stderr: %s', parents_err or '')
  end

  return {
    toplevel = toplevel_r,
    gitdir = assert(normalize_path(Path.join(toplevel_r, '.hg'))),
    abbrev_head = branch_out[1] or '',
    detached = false,
    head_oid = parents_out[1],
  }
end

--- @async
--- @param dir? string
--- @param gitdir? string
--- @param worktree? string
--- @return Hgsigns.RepoInfo? info, string? err
function M.get_info(dir, gitdir, worktree)
  -- Wait for internal scheduler to settle before running command (#215)
  async.schedule()

  if dir and not uv.fs_stat(dir) then
    -- Cwd can be deleted externally, so check if it exists (see #1331)
    log.dprintf("dir '%s' does not exist", dir)
    return
  end

  return get_info_hg(dir, gitdir, worktree)
end

--- @async
--- @param relpath string
--- @return Hgsigns.Repo.LsFiles.Result? info
--- @return string? err
function M:hg_file_info(relpath)
  local results, stderr, code = self:command({ 'status', '-A', relpath }, { ignore_error = true })

  if code > 0 and stderr then
    local missing = stderr:match('^.-: No such file or directory$')
    if missing then
      local info = {
        relpath = relpath,
        file_state = 'removed',
        mode_bits = default_mode_bits(Path.join(self.toplevel, relpath)),
        object_name = self.head_oid,
      } --- @type Hgsigns.Repo.LsFiles.Result
      return info, nil
    end
    return nil, stderr
  end

  local result = {
    relpath = relpath,
    file_state = 'tracked',
    mode_bits = default_mode_bits(Path.join(self.toplevel, relpath)),
    object_name = self.head_oid,
  } --- @type Hgsigns.Repo.LsFiles.Result
  local line = results[1]

  if not line or line == '' then
    return result
  end

  local status = line:sub(1, 1)
  if status == '?' then
    result.file_state = 'unknown'
    result.object_name = nil
  elseif status == 'A' then
    result.file_state = 'added'
    result.object_name = nil
  elseif status == 'R' or status == '!' then
    result.file_state = 'removed'
  elseif status == 'I' then
    result.file_state = 'unknown'
    result.relpath = nil
    result.object_name = nil
  elseif status ~= 'M' and status ~= 'C' then
    result.file_state = 'unknown'
    result.object_name = nil
    log.eprintf('Unhandled mercurial status %q for %s', status, relpath)
  end

  return result
end

--- @alias Hgsigns.FileState 'unknown'|'added'|'tracked'|'removed'
---
--- @class (exact) Hgsigns.Repo.LsFiles.Result
--- @field relpath? string nil if file is not in working tree
--- @field mode_bits? string
--- @field object_name? string nil if file has no parent object baseline
--- @field file_state? Hgsigns.FileState
--- @field has_conflicts? true

--- @async
--- Get information about files in the index and the working tree
--- @param file string
--- @return Hgsigns.Repo.LsFiles.Result? info
--- @return string? err
function M:ls_files(file)
  local relpath = to_relpath(self.toplevel, file)
  if not relpath then
    return {} --[[@as Hgsigns.Repo.LsFiles.Result]]
  end
  return self:hg_file_info(relpath)
end

--- @param revision? string
--- @return boolean
function M.from_tree(revision)
  return revision ~= nil and not vim.startswith(revision, ':')
end

--- @async
--- @param file string
--- @param revision? string
--- @return Hgsigns.Repo.LsFiles.Result? info
--- @return string? err
function M:file_info(file, revision)
  local relpath = to_relpath(self.toplevel, file)
  if not relpath then
    return nil, ('%s is outside repo'):format(file)
  end

  if M.from_tree(revision) then
    local stdout, stderr = self:get_show_text_at_revision(assert(revision), relpath)
    if stderr then
      return nil, stderr
    end
    if #stdout == 0 then
      return nil, ('%s not found in %s'):format(relpath, revision)
    end
    return {
      relpath = relpath,
      mode_bits = default_mode_bits(Path.join(self.toplevel, relpath)),
      object_name = revision,
      file_state = 'tracked',
    }
  end

  return self:hg_file_info(relpath)
end

--- @class (exact) Hgsigns.Repo.HgStatusEntry
--- @field status string
--- @field path string
--- @field oldpath? string

--- @param lines string[]
--- @return Hgsigns.Repo.HgStatusEntry[]?
parse_hg_status_lines = function(lines)
  local ret = {} --- @type Hgsigns.Repo.HgStatusEntry[]
  local last_added --- @type Hgsigns.Repo.HgStatusEntry?

  for _, line in ipairs(lines) do
    if line ~= '' then
      local status = line:sub(1, 1)
      if status == ' ' then
        local oldpath = line:sub(3)
        if
          not last_added
          or last_added.status ~= 'A'
          or last_added.oldpath ~= nil
          or oldpath == ''
        then
          log.eprintf('Malformed mercurial status copy line: %q', line)
          return nil
        end
        last_added.oldpath = oldpath
      else
        local path = line:sub(3)
        if path == '' then
          log.eprintf('Malformed mercurial status line: %q', line)
          return nil
        end

        local entry = {
          status = status,
          path = path,
        }
        ret[#ret + 1] = entry
        last_added = entry
      end
    end
  end

  return ret
end

--- @async
--- @param revision string
--- @param path string
--- @return string?
function M:log_rename_status(revision, path)
  local parsed = parse_hg_status_lines(self:command({
    'status',
    '--copies',
    '--rev',
    revision,
    path,
  })) or {}

  for _, entry in ipairs(parsed) do
    if entry.path == path and entry.oldpath then
      return entry.oldpath
    end
  end
end

--- @async
--- @param revision? string
--- @param invert? boolean
--- @return table<string,string>
function M:diff_rename_status(revision, invert)
  local args = { 'status', '--copies' }
  if revision then
    vim.list_extend(args, { '--rev', revision })
  end

  local parsed = parse_hg_status_lines(self:command(args)) or {}
  local ret = {} --- @type table<string,string>
  for _, entry in ipairs(parsed) do
    if entry.status == 'A' and entry.oldpath then
      if invert then
        ret[entry.path] = entry.oldpath
      else
        ret[entry.oldpath] = entry.path
      end
    end
  end
  return ret
end

return M
