local async = require('hgsigns.async')
local git_command = require('hgsigns.git.cmd')
local config = require('hgsigns.config').config
local log = require('hgsigns.debug.log')
local util = require('hgsigns.util')
local Path = util.Path
local errors = require('hgsigns.git.errors')
local Watcher = require('hgsigns.git.repo.watcher')

local check_version = require('hgsigns.git.version').check

local uv = vim.uv or vim.loop ---@diagnostic disable-line: deprecated

local normalize_path --- @type fun(path?: string): string?
local parse_hg_status_lines --- @type fun(lines: string[]): Hgsigns.Repo.HgStatusEntry[]?

--- @class Hgsigns.RepoInfo
--- @field gitdir string
--- @field toplevel string
--- @field detached boolean
--- @field abbrev_head string
--- @field vcs 'git'|'hg'
--- @field head_oid? string

--- @class Hgsigns.Repo : Hgsigns.RepoInfo
---
--- Username configured for the repo.
--- Needed for to determine "You" in current line blame.
--- @field username string
--- @field private _lock Hgsigns.async.Semaphore
--- @field private _watcher? Hgsigns.Repo.Watcher
--- @field head_oid? string
--- @field head_ref? string
--- @field commondir string
local M = {}

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

--- @param gitdir string
--- @return boolean
local function is_rebasing(gitdir)
  return Path.exists(Path.join(gitdir, 'rebase-merge'))
    or Path.exists(Path.join(gitdir, 'rebase-apply'))
end

--- @param value string?
--- @return string?
local function trim(value)
  if not value then
    -- Preserve nil to signal "no value".
    return
  end
  -- Normalize line endings/whitespace from ref files.
  local trimmed = vim.trim(value)
  -- Treat whitespace-only lines as absent.
  return trimmed ~= '' and trimmed or nil
end

--- @param path string
--- @return string?
local function read_first_line(path)
  local f = io.open(path, 'r')
  if not f then
    return
  end
  local line = f:read('*l')
  f:close()
  return trim(line)
end

--- @param path string
local function wait_for_unlock(path)
  -- Git updates refs by taking `<ref>.lock` and then renaming into place.
  -- Wait briefly so we don't read transient state when reacting to fs events.
  --
  -- TODO(lewis6991): should this be async?
  vim.wait(1000, function()
    return not Path.exists(path .. '.lock')
  end, 10, true)
end

--- Wait for `<path>.lock` to clear then read the first line of a file.
--- @param path string
--- @return string?
local function read_first_line_wait(path)
  wait_for_unlock(path)
  return read_first_line(path)
end

--- @param gitdir string
--- @return string?
local function read_head(gitdir)
  return read_first_line_wait(Path.join(gitdir, 'HEAD'))
end

--- @param head string?
--- @return string?
local function parse_head_ref(head)
  return head and head:match('^ref:%s*(.+)$') or nil
end

--- Return the abbreviated ref for HEAD (or short SHA if detached).
--- Equivalent to `git rev-parse --abbrev-ref HEAD`
--- @param gitdir string Must be an absolute path to the .git directory
--- @param head? string
--- @return string abbrev_head
local function get_abbrev_head(gitdir, head)
  head = head or assert(read_head(gitdir))
  -- HEAD content is either:
  --   "ref: refs/heads/<branch>"
  --   "<commitsha>" (detached HEAD)
  local refpath = parse_head_ref(head)
  if refpath then
    return refpath:match('^refs/heads/(.+)$') or refpath
  end

  assert(head:find('^[%x]+$'), 'Invalid HEAD content: ' .. head)

  -- Detached HEAD -> like `git rev-parse --abbrev-ref HEAD`, return literal "HEAD"
  local short_sha = log.debug_mode() and 'HEAD' or head:sub(1, 7)

  if is_rebasing(gitdir) then
    short_sha = short_sha .. '(rebasing)'
  end
  return short_sha
end

--- @param gitdir string
--- @return string
local function get_commondir(gitdir)
  -- In linked worktrees, `gitdir` points at `.git/worktrees/<name>` while most
  -- refs live under the main `.git` directory (the "commondir").
  local commondir = read_first_line(Path.join(gitdir, 'commondir'))
  if not commondir then
    return gitdir
  end
  local abs = Path.join(gitdir, commondir)
  return uv.fs_realpath(abs) or abs
end

--- @param commondir string
--- @param refname string
--- @return string?
local function read_packed_ref(commondir, refname)
  local packed_refs_path = Path.join(commondir, 'packed-refs')
  wait_for_unlock(packed_refs_path)
  -- `packed-refs` is a flat map from refname to OID (with optional peeled
  -- entries). Read it linearly as this is only used on debounced fs events.
  local f = io.open(packed_refs_path, 'r')
  if not f then
    return
  end
  for line in f:lines() do
    --- @cast line string
    if line:sub(1, 1) ~= '#' and line:sub(1, 1) ~= '^' then
      local oid, name = line:match('^(%x+)%s+(.+)$')
      if name == refname then
        f:close()
        return oid
      end
    end
  end
  f:close()
end

--- @param gitdir string
--- @param commondir? string
--- @param refname string
--- @return string?
local function resolve_ref(gitdir, commondir, refname)
  -- Resolve a refname to an OID by following symbolic refs and checking:
  -- - worktree-local loose refs in `gitdir/`
  -- - shared loose refs in `commondir/`
  -- - `commondir/packed-refs`
  local seen = {} --- @type table<string, true>
  local current = refname

  while current and current ~= '' do
    if seen[current] then
      log.dprintf('cycle detected in symbolic refs: %s', vim.inspect(vim.tbl_keys(seen)))
      return
    end
    seen[current] = true

    local line = read_first_line_wait(Path.join(gitdir, current))

    if not line and commondir and commondir ~= gitdir then
      line = read_first_line_wait(Path.join(commondir, current))
    end

    if not line then
      log.dprintf('Ref %s not found as loose ref; checking packed-refs', current)
      break
    elseif line:match('^%x+$') then
      return line
    end

    local symref = line:match('^ref:%s*(.+)$')
    if symref then
      current = symref
    else
      log.dprintf('Ref %s has invalid contents (%s); checking packed-refs', current, line)
      break
    end
  end

  if commondir and current then
    -- Some refs are only stored in packed-refs.
    local packed = read_packed_ref(commondir, current)
    if packed and packed:match('^%x+$') then
      return packed
    end
  end
end

--- Manual implementation of `git rev-parse HEAD`.
--- @param gitdir string
--- @param commondir string
--- @return string? oid
--- @return string? err
local function get_head_oid0(gitdir, commondir)
  -- `.git/HEAD` can remain unchanged while its target ref moves (e.g. `git pull`
  -- updating the checked-out branch). Resolve `HEAD` through loose refs and
  -- packed-refs so we can detect branch moves without spawning `git`.
  local head = read_head(gitdir)
  if not head then
    -- Unable to read HEAD.
    return nil, 'unable to read HEAD file'
  end

  if head:match('^%x+$') then
    -- Detached HEAD contains an OID directly.
    return head
  end

  local ref = parse_head_ref(head)
  if not ref then
    -- Unrecognized HEAD format.
    return nil, ('unrecognized HEAD contents: %s'):format(head)
  end

  local oid = resolve_ref(gitdir, commondir, ref)
  if oid then
    -- Resolved via loose refs or packed-refs.
    return oid
  end

  -- Reftable stores refs in a different backend (no loose/packed refs).
  if Path.exists(Path.join(commondir, 'reftable')) then
    return nil, 'reftable'
  end

  -- Reftable cannot be parsed via loose refs/packed-refs. Keep a synchronous
  -- fallback for correctness (rare setup). Some other backends or transient
  -- states can also cause resolution to fail, so keep this as a general
  -- fallback.
  return nil, ('unable to resolve %s via loose refs/packed-refs'):format(ref)
end

--- Manual implementation of `git rev-parse HEAD` with command fallback.
--- @param gitdir string
--- @param commondir string
--- @return string? oid
local function get_head_oid(gitdir, commondir)
  local oid0, err = get_head_oid0(gitdir, commondir)
  if oid0 then
    return oid0
  end

  log.dprintf('Falling back to `git rev-parse HEAD`: %s', err)

  local stdout, stderr, code = async
    .run(git_command, { '--git-dir', gitdir, 'rev-parse', 'HEAD' }, {
      ignore_error = true,
      vcs = 'git',
    })
    :wait()

  local oid = stdout[1]

  if code ~= 0 or not oid or not oid:match('^%x+$') then
    log.dprintf('Fallback `git rev-parse HEAD` failed: code=%s oid=%s stderr=%s', code, oid, stderr)
    return
  end
  return oid
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

--- Run git command the with the objects gitdir and toplevel
--- @async
--- @param args table<any,any>
--- @param spec? Hgsigns.Git.JobSpec
--- @return string[] stdout
--- @return string? stderr
--- @return integer code
function M:command(args, spec)
  spec = spec or {}
  spec.cwd = self.toplevel

  if self.vcs == 'hg' then
    spec.vcs = 'hg'
    return git_command(args, spec)
  end

  local args0 = { '--git-dir', self.gitdir }

  if self.detached then
    -- If detached, we need to set the work tree to the toplevel so that git
    -- commands work correctly.
    args0 = vim.list_extend(args0, { '--work-tree', self.toplevel })
  end

  vim.list_extend(args0, args)

  spec.vcs = 'git'
  return git_command(args0, spec)
end

--- @async
--- @param base string?
--- @param include_untracked? boolean
--- @return {path:string, oldpath?:string, status?:string}[]
function M:files_changed(base, include_untracked)
  local ret = {} --- @type {path:string, oldpath?:string, status?:string}[]

  if self.vcs == 'hg' then
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
        }
      end
    end
    return ret
  end

  if base and base ~= ':0' then
    local results = self:command({ 'diff', '--name-status', base })
    for _, result in ipairs(results) do
      local parts = vim.split(result, '\t', { plain = true })
      local status = parts[1]
      local path = parts[#parts]
      local renamed = status and (vim.startswith(status, 'R') or vim.startswith(status, 'C'))
      if path then
        ret[#ret + 1] = {
          path = path,
          oldpath = renamed and parts[2] or nil,
          status = status,
        }
      end
    end
    if include_untracked then
      local untracked = self:command({ 'ls-files', '--others', '--exclude-standard' })
      for _, path in ipairs(untracked) do
        ret[#ret + 1] = { path = path, status = '??' }
      end
    end
    return ret
  end

  local results = self:command({ 'status', '--porcelain', '--ignore-submodules' })

  for _, line in ipairs(results) do
    local status = line:sub(1, 2)
    if status:match('^.M') or (include_untracked and status == '??') then
      ret[#ret + 1] = { path = line:sub(4, -1), status = status }
    end
  end
  return ret
end

--- @async
--- @param attr string
--- @param files string[]
--- @return table<string,'set'|'unset'|'unspecified'|string>
function M:check_attr(attr, files)
  local ret = {} --- @type table<string,'set'|'unset'|'unspecified'|string>

  if #files == 0 then
    return ret
  end

  for _, f in ipairs(files) do
    ret[f] = 'unspecified'
  end

  if self.vcs == 'hg' then
    return ret
  end

  local output = self:command({ 'check-attr', attr, '--stdin' }, { stdin = files })
  local sep = ': ' .. attr .. ': '

  for _, line in ipairs(output) do
    local parts = vim.split(line, sep, { plain = true })
    local file = parts[1]
    if file and #parts >= 2 then
      local value = table.concat(parts, sep, 2)
      ret[file] = value
    end
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
--- Get version of file in the index, return array lines
--- @param object string
--- @param encoding? string
--- @return string[] stdout, string? stderr
function M:get_show_text(object, encoding)
  local stdout, stderr
  if self.vcs == 'hg' then
    stdout, stderr = self:command({ 'cat', '-r', object }, { text = false, ignore_error = true })
  else
    stdout, stderr = self:command({ 'show', object }, { text = false, ignore_error = true })
  end

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
  local stdout, stderr

  if self.vcs == 'hg' then
    stdout, stderr = self:command({ 'cat', '-r', revision, relpath }, {
      text = false,
      ignore_error = true,
    })
  else
    stdout, stderr = self:get_show_text(revision .. ':' .. relpath, encoding)
  end

  local missing_path = stderr
    and (
      (self.vcs == 'hg' and is_missing_hg_revision_path(stderr))
      or stderr:match(errors.e.path_does_not_exist)
      or stderr:match(errors.e.path_exist_on_disk_but_not_in)
    )

  if missing_path then
    log.dprintf('%s not found in %s looking for renames', relpath, revision)
    local old_path = self:diff_rename_status(revision, true)[relpath]
      or self:log_rename_status(revision, relpath)
    if old_path then
      log.dprintf('found rename %s -> %s', old_path, relpath)
      if self.vcs == 'hg' then
        stdout, stderr = self:command({ 'cat', '-r', revision, old_path }, {
          text = false,
          ignore_error = true,
        })
      else
        stdout, stderr = self:get_show_text(revision .. ':' .. old_path, encoding)
      end
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
  if self.vcs == 'hg' then
    local stdout = self:command({ 'parents', '-r', revision, '-T', '{node}\n' }, {
      ignore_error = true,
    })
    local parent = stdout[1]
    return parent ~= '' and parent or nil
  end

  local stdout = self:command({ 'rev-parse', revision .. '^' }, { ignore_error = true })
  local parent = stdout[1]
  return parent ~= '' and parent or nil
end

--- @async
--- @param revision string
--- @param relpath string
--- @return string?
function M:get_previous_path(revision, relpath)
  if self.vcs == 'hg' then
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

  return self:diff_rename_status(revision, true)[relpath] or relpath
end

--- @type table<string,Hgsigns.Repo?>
local repo_cache = setmetatable({}, { __mode = 'v' })

--- @async
--- @private
--- @param info Hgsigns.RepoInfo
--- @return Hgsigns.Repo
function M._new(info)
  --- @type Hgsigns.Repo
  local self = setmetatable(info, { __index = M })
  self._lock = async.semaphore(1)
  self.head_oid = info.head_oid

  if self.vcs == 'hg' then
    self.username = self:command({ 'config', 'ui.username' }, { ignore_error = true })[1]
    self.commondir = self.gitdir

    if config.watch_gitdir.enable then
      self._watcher = Watcher.new(self.gitdir, self.commondir, self.vcs)
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

  self.username = self:command({ 'config', 'user.name' }, { ignore_error = true })[1]

  self.commondir = get_commondir(self.gitdir)

  if config.watch_gitdir.enable then
    local head = read_head(self.gitdir)
    self.head_ref = parse_head_ref(head)
    self.head_oid = get_head_oid(self.gitdir, self.commondir)
    self._watcher = Watcher.new(self.gitdir, self.commondir, self.vcs)
    self._watcher:set_head_ref(self.head_ref)
    self._watcher:on_update(function()
      -- Recompute on every debounced tick. The checked-out branch can move
      -- without `HEAD` changing (e.g. `refs/heads/main` update).
      local head2 = read_head(self.gitdir)
      if not head2 then
        return
      end

      self.head_oid = get_head_oid(self.gitdir, self.commondir)
      -- Set abbrev_head to empty string if head_oid is unavailable (.e.g repo
      -- with no commits). This is consistent with `git rev-parse --abrev-ref
      -- HEAD` which returns "HEAD" in this case.
      local abbrev_head = self.head_oid and get_abbrev_head(self.gitdir, head2) or ''
      if self.abbrev_head ~= abbrev_head then
        self.abbrev_head = abbrev_head
        log.dprintf('HEAD changed, updating abbrev_head to %s', self.abbrev_head)
      end

      local head_ref = parse_head_ref(head2)
      if self.head_ref ~= head_ref then
        self.head_ref = head_ref
        self._watcher:set_head_ref(self.head_ref)
      end
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
      repo.vcs = info.vcs
    else
      repo = M._new(info)
      repo_cache[info.gitdir] = repo
    end
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
--- @param gitdir string
--- @param head_str string
--- @param cwd string
--- @return string
local function process_abbrev_head(gitdir, head_str, cwd)
  if head_str ~= 'HEAD' then
    return head_str
  end

  local short_sha = git_command({ 'rev-parse', '--short', 'HEAD' }, {
    ignore_error = true,
    cwd = cwd,
    vcs = 'git',
  })[1] or ''

  -- Make tests easier
  if short_sha ~= '' and log.debug_mode() then
    short_sha = 'HEAD'
  end

  if is_rebasing(gitdir) then
    return short_sha .. '(rebasing)'
  end

  return short_sha
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
    vcs = 'hg',
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
    vcs = 'hg',
  })
  if branch_code > 0 then
    return nil, string.format('got stderr: %s', branch_err or '')
  end

  local parents_out, parents_err, parents_code = git_command(
    { 'parents', '--template', '{node}\n' },
    {
      ignore_error = true,
      cwd = toplevel_r,
      vcs = 'hg',
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
    vcs = 'hg',
    head_oid = parents_out[1],
  }
end

--- @async
--- @param dir? string
--- @param gitdir? string
--- @param worktree? string
--- @return Hgsigns.RepoInfo? info, string? err
local function get_info_git(dir, gitdir, worktree)
  -- Does git rev-parse have --absolute-git-dir, added in 2.13:
  --    https://public-inbox.org/git/20170203024829.8071-16-szeder.dev@gmail.com/
  local has_abs_gd = check_version(2, 13)

  -- Explicitly fallback to env vars for better debug
  gitdir = gitdir or vim.env.GIT_DIR
  worktree = worktree or vim.env.GIT_WORK_TREE or vim.fs.dirname(gitdir)

  local stdout, stderr, code = git_command(
    util.flatten({
      gitdir and { '--git-dir', gitdir },
      worktree and { '--work-tree', worktree },
      'rev-parse',
      '--show-toplevel',
      has_abs_gd and '--absolute-git-dir' or '--git-dir',
      '--abbrev-ref',
      'HEAD',
    }),
    {
      ignore_error = true,
      -- Worktree may be a relative path, so don't set cwd when it is provided.
      cwd = not worktree and dir or nil,
      vcs = 'git',
    }
  )

  -- If the repo has no commits yet, rev-parse will fail. Ignore this error.
  if code > 0 and stderr and stderr:match(errors.e.ambiguous_head) then
    code = 0
  end

  if code > 0 then
    return nil, string.format('got stderr: %s', stderr or '')
  end

  if #stdout < 3 then
    return nil, string.format('incomplete stdout: %s', table.concat(stdout, '\n'))
  end
  --- @cast stdout [string, string, string]

  local toplevel_r = assert(normalize_path(stdout[1]))
  local gitdir_r = assert(normalize_path(stdout[2]))
  dir = normalize_path(dir)
  gitdir = normalize_path(gitdir)

  -- On windows, git will emit paths with `/` but dir may contain `\` so need to
  -- normalize.
  if dir and not vim.startswith(dir, toplevel_r) then
    log.dprintf("'%s' is outside worktree '%s'", dir, toplevel_r)
    -- outside of worktree
    return
  end

  if not has_abs_gd then
    gitdir_r = assert(normalize_path(uv.fs_realpath(gitdir_r)))
  end

  if gitdir and not worktree and gitdir ~= gitdir_r then
    log.eprintf('expected gitdir to be %s, got %s', gitdir, gitdir_r)
  end

  return {
    toplevel = toplevel_r,
    gitdir = gitdir_r,
    abbrev_head = process_abbrev_head(gitdir_r, stdout[3], toplevel_r),
    detached = gitdir_r ~= assert(normalize_path(Path.join(toplevel_r, '.git'))),
    vcs = 'git',
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

  local explicit_hg = is_hg_gitdir(gitdir)
  if explicit_hg then
    return get_info_hg(dir, gitdir, worktree)
  end

  local hg_info, hg_err = get_info_hg(dir, gitdir, worktree)
  local git_info, git_err = get_info_git(dir, gitdir, worktree)

  if hg_info and git_info then
    if #hg_info.toplevel > #git_info.toplevel then
      return hg_info
    end
    return git_info
  end

  if hg_info then
    return hg_info
  end

  if git_info then
    return git_info
  end

  if hg_err and not is_not_in_hg_repo(hg_err) then
    return nil, hg_err
  end

  return nil, git_err or hg_err
end

--- @class (exact) Hgsigns.Repo.LsTree.Result
--- @field relpath string
--- @field mode_bits? string
--- @field object_name? string
--- @field object_type? 'blob'|'tree'|'commit'

--- @async
--- @param path string
--- @param revision string
--- @return Hgsigns.Repo.LsTree.Result? info
--- @return string? err
function M:ls_tree(path, revision)
  local results, stderr, code = self:command({
    'ls-tree',
    revision,
    path,
  }, { ignore_error = true })

  if code > 0 then
    return nil, stderr or tostring(code)
  end

  local res = results[1]

  if not res then
    -- Not found, see if it was renamed
    log.dprintf('%s not found in %s looking for renames', path, revision)
    local old_path = self:diff_rename_status(revision, true)[path]
    if old_path then
      log.dprintf('found rename %s -> %s', old_path, path)
      return self:ls_tree(old_path, revision)
    end

    return nil, ('%s not found in %s'):format(path, revision)
  end

  local info, relpath = unpack(vim.split(res, '\t'))
  assert(info and relpath)
  local mode_bits, object_type, object_name = unpack(vim.split(info, '%s+'))
  --- @cast object_type 'blob'|'tree'|'commit'

  return {
    relpath = relpath,
    mode_bits = mode_bits,
    object_name = object_name,
    object_type = object_type,
  }
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
--- @field i_crlf? boolean (requires git version >= 2.9)
--- @field w_crlf? boolean (requires git version >= 2.9)
--- @field has_conflicts? true

--- @async
--- Get information about files in the index and the working tree
--- @param file string
--- @return Hgsigns.Repo.LsFiles.Result? info
--- @return string? err
function M:ls_files(file)
  if self.vcs == 'hg' then
    local relpath = to_relpath(self.toplevel, file)
    if not relpath then
      return {} --[[@as Hgsigns.Repo.LsFiles.Result]]
    end
    return self:hg_file_info(relpath)
  end

  local has_eol = check_version(2, 9)

  -- --others + --exclude-standard means ignored files won't return info, but
  -- untracked files will. Unlike file_info_tree which won't return untracked
  -- files.
  local results, stderr, code = self:command(
    util.flatten({
      'ls-files',
      '--stage',
      '--others',
      '--exclude-standard',
      has_eol and '--eol',
      file,
    }),
    { ignore_error = true }
  )

  -- ignore_error for the cases when we run:
  --    git ls-files --others exists/nonexist
  if code > 0 and (not stderr or not stderr:match(errors.e.path_does_not_exist)) then
    return nil, stderr or tostring(code)
  end

  local relpath_idx = has_eol and 2 or 1

  local result = {
    file_state = 'unknown',
  } --- @type Hgsigns.Repo.LsFiles.Result
  for _, line in ipairs(results) do
    local parts = vim.split(line, '\t')
    if #parts > relpath_idx then -- tracked file
      result.file_state = 'tracked'
      local attrs = vim.split(assert(parts[1]), '%s+')
      local stage = tonumber(attrs[3])
      if stage <= 1 then
        result.mode_bits = attrs[1]
        result.object_name = attrs[2]
      else
        result.has_conflicts = true
      end

      if has_eol then
        result.relpath = parts[3]
        local eol = vim.split(assert(parts[2]), '%s+')
        result.i_crlf = eol[1] == 'i/crlf'
        result.w_crlf = eol[2] == 'w/crlf'
      else
        result.relpath = parts[2]
      end
    else -- untracked file
      result.relpath = parts[relpath_idx]
      result.file_state = 'unknown'
    end
  end

  return result
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
  if self.vcs == 'hg' then
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

  if M.from_tree(revision) then
    local info, err = self:ls_tree(file, assert(revision))
    if err then
      return nil, err
    end

    if info and info.object_type == 'blob' then
      return {
        relpath = info.relpath,
        mode_bits = info.mode_bits,
        object_name = info.object_name,
        file_state = 'tracked',
      }
    end
  else
    local info, err = self:ls_files(file)
    if err then
      return nil, err
    end

    return info
  end
end

--- @async
--- @param mode_bits string
--- @param object string
--- @param path string
--- @param add? boolean
function M:update_index(mode_bits, object, path, add)
  self:command(util.flatten({
    'update-index',
    add and '--add',
    '--cacheinfo',
    ('%s,%s,%s'):format(mode_bits, object, path),
  }))
end

--- @async
--- @param path string
--- @param lines string[]
--- @return string
function M:hash_object(path, lines)
  -- Concatenate the lines into a single string to ensure EOL
  -- is respected
  local text = table.concat(lines, '\n')
  local res = self:command({ 'hash-object', '-w', '--path', path, '--stdin' }, { stdin = text })[1]
  return assert(res)
end

--- @param line string?
--- @return string? status
--- @return string? path
--- @return string? path2
local function parse_name_status_line(line)
  if not line then
    return
  end

  local parts = vim.split(line, '\t', { plain = true })
  if #parts < 2 then
    return
  end

  local status = parts[1]
  if not status then
    return
  end

  if vim.startswith(status, 'R') or vim.startswith(status, 'C') then
    return status, parts[2], parts[3]
  end

  return status, parts[2]
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
  if self.vcs == 'hg' then
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
    return
  end

  local out = self:command({
    'log',
    '--follow',
    '--name-status',
    '--diff-filter=R',
    '--format=',
    revision .. '..HEAD',
    '--',
    path,
  })
  local _, old_path = parse_name_status_line(out[#out])
  return old_path
end

--- @async
--- @param revision? string
--- @param invert? boolean
--- @return table<string,string>
function M:diff_rename_status(revision, invert)
  if self.vcs == 'hg' then
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

  local out = self:command({
    'diff',
    '--name-status',
    '--find-renames',
    '--find-copies',
    '--cached',
    revision,
  })
  local ret = {} --- @type table<string,string>
  for _, l in ipairs(out) do
    local stat, orig_file, new_file = parse_name_status_line(l)
    if stat and vim.startswith(stat, 'R') and orig_file and new_file then
      if invert then
        ret[new_file] = orig_file
      else
        ret[orig_file] = new_file
      end
    end
  end
  return ret
end

return M
