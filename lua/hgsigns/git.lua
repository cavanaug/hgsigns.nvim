local log = require('hgsigns.debug.log')
local util = require('hgsigns.util')
local Repo = require('hgsigns.git.repo')
local errors = require('hgsigns.git.errors')

local M = {}

M.Repo = Repo

--- @class Hgsigns.GitObj
--- @field file string
--- @field encoding string
--- @field mode_bits string
--- @field file_state? Hgsigns.FileState
---
--- Revision the object is tracking against. Nil for index
--- @field revision? string
---
--- The fixed object name to use. Nil for untracked.
--- @field object_name? string
---
--- The path of the file relative to toplevel. Used to
--- perform git operations. Nil if file does not exist
--- @field relpath? string
---
--- Used for tracking moved files
--- @field orig_relpath? string
---
--- @field repo Hgsigns.Repo
--- @field has_conflicts? boolean
local Obj = {}
Obj.__index = Obj

M.Obj = Obj

--- @async
--- @param revision? string
--- @return string? err
function Obj:change_revision(revision)
  self.revision = util.norm_base(revision, self.repo.vcs)
  return self:refresh()
end

--- @async
--- @param fn async fun()
function Obj:lock(fn)
  return self.repo:lock(fn)
end

--- @async
--- @return string? err
function Obj:refresh()
  local info, err = self.repo:file_info(self.file, self.revision)

  if err then
    log.eprint(err)
  end

  if not info then
    return err
  end

  --- @cast info Hgsigns.Repo.LsFiles.Result

  self.relpath = info.relpath
  self.object_name = info.object_name
  self.mode_bits = info.mode_bits
  self.file_state = info.file_state
  self.has_conflicts = info.has_conflicts

  log.dprintf(
    'Refreshed %s: state=%s relpath=%s object_name=%s',
    self.file,
    tostring(self.file_state),
    tostring(self.relpath),
    tostring(self.object_name)
  )
end

function Obj:from_tree()
  return Repo.from_tree(self.revision)
end

function Obj:is_untracked()
  return self.file_state == nil or self.file_state == 'unknown'
end

function Obj:has_staging_area()
  return self.repo.vcs == 'git'
end

--- @async
--- @param revision? string
--- @param relpath? string
--- @return string[] stdout, string? stderr
function Obj:get_show_text(revision, relpath)
  relpath = relpath or self.relpath
  if revision and not relpath then
    log.dprint('no relpath')
    return {}
  end

  if not revision and not self.object_name then
    if self.file_state == 'removed' and self.relpath and self.repo.head_oid then
      return self.repo:get_show_text_at_revision(self.repo.head_oid, self.relpath, self.encoding)
    end

    log.dprintf('using empty baseline for %s state=%s', self.file, tostring(self.file_state))
    return { '' }
  end

  local stdout, stderr
  if revision then
    --- @cast relpath -?
    stdout, stderr = self.repo:get_show_text_at_revision(revision, relpath, self.encoding)
  elseif self.repo.vcs == 'hg' then
    --- @cast relpath -?
    stdout, stderr =
      self.repo:get_show_text_at_revision(assert(self.object_name), relpath, self.encoding)
  else
    stdout, stderr = self.repo:get_show_text(assert(self.object_name), self.encoding)
  end

  return stdout, stderr
end

--- @async
--- @param contents? string[]
--- @param lnum? integer|[integer, integer]
--- @param revision? string
--- @param opts? Hgsigns.BlameOpts
--- @return table<integer,Hgsigns.BlameInfo?>
--- @return table<string,Hgsigns.CommitInfo?>
function Obj:run_blame(contents, lnum, revision, opts)
  return require('hgsigns.git.blame').run_blame(self, contents, lnum, revision, opts)
end

--- @async
--- @param file string Absolute path or relative to toplevel
--- @param revision string?
--- @param encoding string
--- @param gitdir string?
--- @param toplevel string?
--- @return Hgsigns.GitObj?
function Obj.new(file, revision, encoding, gitdir, toplevel)
  local cwd = toplevel
  if not cwd and util.Path.is_abs(file) then
    cwd = vim.fn.fnamemodify(file, ':h')
  end

  local repo, err = Repo.get(cwd, gitdir, toplevel)
  if not repo then
    log.dprint('Not in hg repo')
    if
      err
      and not err:match(errors.e.not_in_git)
      and not err:match(errors.e.not_in_hg)
      and not err:match(errors.e.worktree)
    then
      log.eprint(err)
    end
    return
  end

  if vim.startswith(vim.fn.fnamemodify(file, ':p'), vim.fn.fnamemodify(repo.gitdir, ':p')) then
    -- Normally this check would be caught (unintended) in the above
    -- block, as gitdir resolution will fail if `file` is inside a gitdir.
    -- If gitdir is explicitly passed (or set in the env with GIT_DIR)
    -- then resolution will succeed, but we still don't want to
    -- attach if `file` is inside the gitdir.
    log.dprint('In hgdir')
    return
  end

  -- When passing gitdir and toplevel, suppress stderr when resolving the file
  local silent = gitdir ~= nil and toplevel ~= nil

  revision = util.norm_base(revision, repo.vcs)

  local info, err2 = repo:file_info(file, revision)

  if err2 and not silent then
    log.eprint(err2)
  end

  if not info then
    return
  end

  --- @cast info Hgsigns.Repo.LsFiles.Result

  if info.relpath then
    file = util.Path.join(repo.toplevel, info.relpath)
  end

  local self = setmetatable({}, Obj)
  self.repo = repo
  self.file = util.cygpath(file, 'unix')
  self.revision = revision
  self.encoding = encoding

  self.relpath = info.relpath
  self.object_name = info.object_name
  self.mode_bits = info.mode_bits
  self.file_state = info.file_state
  self.has_conflicts = info.has_conflicts

  return self
end

return M
