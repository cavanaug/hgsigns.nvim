local async = require('hgsigns.async')
local cache = require('hgsigns.cache').cache
local git = require('hgsigns.git')
local run_diff = require('hgsigns.diff')
local config = require('hgsigns.config').config
local util = require('hgsigns.util')

local uv = vim.uv or vim.loop ---@diagnostic disable-line: deprecated

local current_buf = vim.api.nvim_get_current_buf

--- @class hgsigns.qflist
local M = {}

--- @param buf_or_filename string|integer
--- @param hunks Hgsigns.Hunk.Hunk[]
--- @param qflist table[]
local function hunks_to_qflist(buf_or_filename, hunks, qflist)
  for _, hunk in ipairs(hunks) do
    local kind = hunk.type == 'add' and 'Added' or hunk.type == 'delete' and 'Removed' or 'Changed'
    local header = ('-%s%s +%s%s'):format(
      hunk.removed.start,
      hunk.removed.count ~= 1 and ',' .. tostring(hunk.removed.count) or '',
      hunk.added.start,
      hunk.added.count ~= 1 and ',' .. tostring(hunk.added.count) or ''
    )
    local line = hunk.added.lines[1] or hunk.removed.lines[1] or ''
    local text = ('%-7s (%s): %s'):format(kind, header, util.lua2viml_str(line))
    qflist[#qflist + 1] = {
      bufnr = type(buf_or_filename) == 'number' and buf_or_filename or nil,
      filename = type(buf_or_filename) == 'string' and buf_or_filename or nil,
      lnum = hunk.added.start,
      text = text,
    }
  end
end

--- @async
--- @param target 'all'|'attached'|integer?
--- @return table[]?
local function buildqflist(target)
  target = target or current_buf()
  if target == 0 then
    target = current_buf()
  end
  local qflist = {} --- @type table[]

  if type(target) == 'number' then
    local bufnr = target
    local bcache = cache[bufnr]
    if not bcache or not bcache.hunks then
      return
    end
    hunks_to_qflist(bufnr, bcache.hunks, qflist)
  elseif target == 'attached' then
    for bufnr, bcache in pairs(cache) do
      if bcache.hunks then
        hunks_to_qflist(bufnr, bcache.hunks, qflist)
      end
    end
  elseif target == 'all' then
    local repos = {} --- @type table<string,Hgsigns.Repo>
    for _, bcache in pairs(cache) do
      local repo = bcache.git_obj.repo
      if not repos[repo.gitdir] then
        repos[repo.gitdir] = repo
      end
    end

    local cwd_repo = git.Repo.get((assert(uv.cwd())))
    if cwd_repo and not repos[cwd_repo.gitdir] then
      repos[cwd_repo.gitdir] = cwd_repo
    end

    for _, r in pairs(repos) do
      local changed_files = r:files_changed(config.base, config.attach_to_untracked)
      local changed_paths = {} --- @type string[]
      for i, changed_file in ipairs(changed_files) do
        changed_paths[i] = changed_file.path
      end
      local diff_attrs = r:check_attr('diff', changed_paths)

      for _, changed_file in ipairs(changed_files) do
        local f = changed_file.path
        if diff_attrs[f] ~= 'unset' then
          local f_abs = r.toplevel .. '/' .. f
          local stat = uv.fs_stat(f_abs)
          if changed_file.deleted or (stat and stat.type == 'file') then
            local base_relpath = changed_file.oldpath or f
            local a --- @type string[]

            if r.vcs == 'hg' then
              local status = changed_file.status
              if status == 'A' and not changed_file.oldpath then
                a = { '' }
              else
                local revision = config.base and config.base ~= ':0' and config.base or r.head_oid
                if revision then
                  a = r:get_show_text_at_revision(revision, base_relpath)
                else
                  a = { '' }
                end
              end
              local b = changed_file.deleted and {} or util.file_lines(f_abs)
              local hunks = run_diff(a, b)
              hunks_to_qflist(f_abs, hunks, qflist)
            else
              --- @type string
              local obj
              if config.base and config.base ~= ':0' then
                obj = config.base .. ':' .. base_relpath
              else
                obj = ':0:' .. f
              end
              local a2, stderr = r:get_show_text(obj)
              if stderr and changed_file.deleted and (not config.base or config.base == ':0') then
                a2 = r:get_show_text('HEAD:' .. base_relpath)
              end
              local b = changed_file.deleted and {} or util.file_lines(f_abs)
              local hunks = run_diff(a2, b)
              hunks_to_qflist(f_abs, hunks, qflist)
            end
          end
        end
      end
    end
  end

  if cwd_repo then
    cwd_repo:unref()
  end
  return qflist
end

--- Populate the quickfix list with hunks. Automatically opens the
--- quickfix window.
--- @async
--- @param target integer|'attached'|'all'?
--- @param opts table?
function M.setqflist(target, opts)
  opts = opts or {}
  if opts.open == nil then
    opts.open = true
  end
  --- @type vim.fn.setqflist.what
  local qfopts = {
    items = buildqflist(target),
    title = 'Hunks',
  }
  async.schedule()
  if opts.use_location_list then
    local nr = opts.nr or 0
    vim.fn.setloclist(nr, {}, ' ', qfopts)
    if opts.open then
      if config.trouble then
        require('trouble').open('loclist')
      else
        vim.cmd.lopen()
      end
    end
  else
    vim.fn.setqflist({}, ' ', qfopts)
    if opts.open then
      if config.trouble then
        require('trouble').open('quickfix')
      else
        vim.cmd.copen()
      end
    end
  end
end

return M
