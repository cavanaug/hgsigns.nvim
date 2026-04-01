local Async = require('hgsigns.async')
local cache = require('hgsigns.cache').cache
local Util = require('hgsigns.util')
local Hunks = require('hgsigns.hunks')
local config = require('hgsigns.config').config

local api = vim.api

local SHOW_FORMAT = table.concat({
  'commit' .. '%x20%H',
  'tree' .. '%x20%T',
  'parent' .. '%x20%P',
  'author' .. '%x20%an%x20<%ae>%x20%ad',
  'committer' .. '%x20%cn%x20<%ce>%x20%cd',
  'encoding' .. '%x20%e',
  '',
  '%B',
}, '%n')

--- @param line string
--- @return string
local function strip_ansi(line)
  return (line:gsub('\r$', ''):gsub('\r', ''):gsub('\27%[[0-9;?]*[%a]', ''))
end

--- @param lines string[]
--- @return string[]
local function sanitize_lines(lines)
  local ret = {} --- @type string[]
  for i, line in ipairs(lines) do
    ret[i] = strip_ansi(line)
  end
  return ret
end

--- @async
--- @param repo Hgsigns.Repo
--- @param base string
--- @return string[]
local function build_hg_show_output(repo, base)
  local meta_out, meta_err, meta_code = repo:command({ 'log', '-r', base, '-T', 'json' }, {
    ignore_error = true,
  })
  if meta_code > 0 then
    error(meta_err or ('Failed to load mercurial revision ' .. base), 2)
  end

  local ok, payload = pcall(vim.json.decode, table.concat(meta_out, '\n'))
  if not ok or type(payload) ~= 'table' or type(payload[1]) ~= 'table' then
    error('Malformed mercurial log output for revision ' .. base, 2)
  end

  local meta = payload[1] --- @type table<string, any>
  local desc = tostring(meta.desc or '')
  local desc_lines = vim.split(desc, '\n', { plain = true })
  local lines = {
    ('commit %s'):format(assert(meta.node)),
  } --- @type string[]

  for _, parent in ipairs(meta.parents or {}) do
    if parent ~= '' and parent ~= ('0'):rep(40) then
      lines[#lines + 1] = ('parent %s'):format(parent)
    end
  end

  lines[#lines + 1] = ('author %s'):format(tostring(meta.user or ''))
  if type(meta.date) == 'table' and type(meta.date[1]) == 'number' then
    lines[#lines + 1] = ('date %s'):format(os.date('%Y-%m-%d %H:%M %z', meta.date[1]))
  end
  if meta.branch and meta.branch ~= '' then
    lines[#lines + 1] = ('branch %s'):format(meta.branch)
  end
  lines[#lines + 1] = ('summary %s'):format(desc_lines[1] or '')
  lines[#lines + 1] = ''
  vim.list_extend(lines, desc_lines)

  local diff_out, diff_err, diff_code = repo:command({ 'diff', '-c', base, '--git' }, {
    ignore_error = true,
  })
  if diff_code > 0 then
    error(diff_err or ('Failed to diff mercurial revision ' .. base), 2)
  end

  diff_out = sanitize_lines(diff_out)
  if #diff_out > 0 then
    lines[#lines + 1] = ''
    vim.list_extend(lines, diff_out)
  end

  return lines
end

--- @async
--- @param repo Hgsigns.Repo
--- @param base string
--- @return string[]
local function build_show_output(repo, base)
  if repo.vcs == 'hg' then
    return build_hg_show_output(repo, base)
  end

  local res = repo:command({
    'show',
    '--unified=0',
    '--format=format:' .. SHOW_FORMAT,
    base,
  })

  -- Remove encoding line if it's not set to something meaningful
  if assert(res[6]):match('^encoding (unknown)?') == nil then
    table.remove(res, 6)
  end

  return sanitize_lines(res)
end

--- @param lnum integer
--- @return Hgsigns.Hunk.Hunk
--- @return string
--- @return string
local function get_hunk(lnum)
  local new_file --- @type string?
  local old_file --- @type string?
  local hunk_line --- @type string?
  while true do
    local line = assert(api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1])

    new_file = line:match('^%+%+%+ b/(.*)') or new_file
    old_file = line:match('^%-%-%- a/(.*)') or old_file
    hunk_line = line:match('^@@ [^ ]+ [^ ]+ @@.*') or hunk_line
    if hunk_line and old_file and new_file then
      break
    end

    lnum = lnum - 1
  end
  assert(hunk_line and old_file and new_file, 'Failed to find hunk header or file names')

  return Hunks.parse_diff_line(hunk_line), old_file, new_file
end

local M = {}

--- @async
--- @param bufnr integer
--- @param commit string
--- @param old_file string
--- @param new_file string
--- @param added boolean
--- @param target_lnum integer
local function show_hunk_diff(bufnr, commit, old_file, new_file, added, target_lnum)
  if not added then
    local repo = assert(cache[bufnr]).git_obj.repo
    commit = repo:get_parent_revision(commit) or (commit .. '^')
  end

  require('hgsigns.actions.diffthis').show(bufnr, commit, added and new_file or old_file)
  api.nvim_win_set_cursor(0, { target_lnum, 0 })
end

--- @param base string?
--- @param bufnr integer
--- @param commit_buf integer
--- @param ref_list string[]
--- @param ref_list_ptr integer
local function goto_action(base, bufnr, commit_buf, ref_list, ref_list_ptr)
  local curline = api.nvim_get_current_line()
  local header, ref = curline:match('^([a-z]+) (%x+)')
  if (header == 'tree' or header == 'parent') and ref then
    local ref_stack_ptr1 = ref_list_ptr + 1
    ref_list[ref_stack_ptr1] = base
    for i = ref_stack_ptr1 + 1, #ref_list do
      ref_list[i] = nil
    end
    Async.run(M.show_commit, ref, 'edit', bufnr, ref_list, ref_stack_ptr1):raise_on_error()
    return
  elseif curline:match('^[%+%-]') then
    local lnum = api.nvim_win_get_cursor(0)[1]
    local hunk, old_file, new_file = get_hunk(lnum)
    local line = assert(api.nvim_buf_get_lines(commit_buf, lnum - 1, lnum, false)[1])
    local added = line:match('^%+')

    local commit =
      assert(assert(api.nvim_buf_get_lines(commit_buf, 0, 1, false)[1]):match('^commit (%x+)$'))

    Async.run(
      show_hunk_diff,
      bufnr,
      commit,
      old_file,
      new_file,
      added ~= nil,
      added and hunk.added.start or hunk.removed.start
    ):raise_on_error()
  end
end

--- @async
--- @param base? string?
--- @param open? 'vsplit'|'tabnew'|'edit'
--- @param bufnr? integer
--- @param ref_list? string[]
--- @param ref_list_ptr? integer
--- @return integer? commit_buf
function M.show_commit(base, open, bufnr, ref_list, ref_list_ptr)
  open = open or 'vsplit'
  bufnr = bufnr or api.nvim_get_current_buf()
  ref_list = ref_list or {}
  ref_list_ptr = ref_list_ptr or #ref_list
  local bcache = cache[bufnr]
  if not bcache then
    return
  end

  local repo = bcache.git_obj.repo
  base = Util.norm_base(base or Util.default_revision(repo.vcs), repo.vcs)
  local res = build_show_output(repo, assert(base))

  local buffer_name = bcache:get_rev_bufname(base, false)
  local commit_buf = nil
  -- find preexisting commit buffer or create a new one
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_get_name(buf) == buffer_name then
      commit_buf = buf
      break
    end
  end
  if commit_buf == nil then
    commit_buf = api.nvim_create_buf(true, true)
    api.nvim_buf_set_name(commit_buf, buffer_name)
    api.nvim_buf_set_lines(commit_buf, 0, -1, false, res)
    vim.bo[commit_buf].modifiable = false
    vim.bo[commit_buf].buftype = 'nofile'
    vim.bo[commit_buf].filetype = 'git'
    vim.bo[commit_buf].bufhidden = 'wipe'
  end
  vim.cmd[open]({ mods = { keepalt = true } })
  api.nvim_win_set_buf(0, commit_buf)

  if config._commit_maps then
    vim.keymap.set('n', '<CR>', function()
      goto_action(base, bufnr, commit_buf, ref_list, ref_list_ptr)
    end, { buffer = commit_buf, silent = true })

    vim.keymap.set('n', '<C-o>', function()
      local ref = ref_list[ref_list_ptr]
      if ref then
        Async.run(M.show_commit, ref, 'edit', bufnr, ref_list, ref_list_ptr - 1):raise_on_error()
      end
    end, { buffer = commit_buf, silent = true })

    vim.keymap.set('n', '<C-i>', function()
      local ref = ref_list[ref_list_ptr + 2]
      if ref then
        Async.run(M.show_commit, ref, 'edit', bufnr, ref_list, ref_list_ptr + 1):raise_on_error()
      end
    end, { buffer = commit_buf, silent = true })
  end

  return commit_buf
end

return M.show_commit
