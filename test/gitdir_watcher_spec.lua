--- @diagnostic disable: access-invisible
local helpers = require('test.gs_helpers')

local clear = helpers.clear
local cleanup = helpers.cleanup
local command = helpers.api.nvim_command
local edit = helpers.edit
local eq = helpers.eq
local eq_path = helpers.eq_path
local exec_lua = helpers.exec_lua
local expectf = helpers.expectf
local get_buf_var = helpers.api.nvim_buf_get_var
local hg = helpers.hg
local match_dag = helpers.match_dag
local normalize_path = helpers.normalize_path
local path_pattern = helpers.path_pattern
local setup_hgsigns = helpers.setup_hgsigns
local setup_test_hg_repo = helpers.setup_test_hg_repo
local test_config = helpers.test_config
local test_file = helpers.test_file
local write_to_file = helpers.write_to_file

helpers.env()

local watcher_fallback_test_config = vim.tbl_deep_extend('force', vim.deepcopy(test_config), {
  _allow_fs_poll_fallback = true,
  watch_gitdir = {
    enable = true,
    follow_files = true,
  },
})

--- @param with_poll? boolean
local function install_failing_fs_watchers(with_poll)
  helpers.exec_lua(function(with_poll0)
    local uv = vim.uv or vim.loop

    local function new_fake_handle(fields)
      local handle = fields or {}
      handle._closed = false

      function handle:stop() end

      function handle:close()
        self._closed = true
      end

      function handle:is_closing()
        return self._closed
      end

      return handle
    end

    uv.new_fs_event = function()
      local handle = new_fake_handle()

      function handle:start(_, _, cb)
        vim.schedule(function()
          if not self._closed then
            cb('EMFILE', nil, nil)
          end
        end)
        return 0
      end

      return handle
    end

    if not with_poll0 then
      return
    end

    local poll_id = 0

    uv.new_fs_poll = function()
      poll_id = poll_id + 1

      local handle = new_fake_handle({ _id = poll_id })

      function handle:start(path, _, cb)
        self._path = path
        self._cb = cb
        return 0
      end

      return handle
    end
  end, with_poll)
end
local function get_bufs()
  local bufs = {} --- @type table<integer, string>
  for _, b in ipairs(helpers.api.nvim_list_bufs()) do
    bufs[b] = normalize_path(helpers.api.nvim_buf_get_name(b))
  end
  return bufs
end

--- @param expected table<integer, string>
local function eq_bufs(expected)
  local normalized = {} --- @type table<integer, string?>
  for bufnr, path in pairs(expected) do
    normalized[bufnr] = normalize_path(path)
  end
  eq(normalized, get_bufs())
end

---@param bufnr? integer
local function wait_for_attach(bufnr)
  expectf(function()
    return exec_lua(function(bufnr0)
      return vim.b[bufnr0 or 0].hgsigns_status_dict.gitdir ~= nil
    end, bufnr)
  end)
end

describe('gitdir_watcher (mercurial)', function()
  before_each(function()
    clear()
    helpers.chdir_tmp()
  end)

  after_each(function()
    cleanup()
  end)

  it('follows moved hg files with spaces', function()
    helpers.hg_init_scratch()

    local old_name = helpers.scratch .. '/old name.txt'
    local new_name = helpers.scratch .. '/new name.txt'

    write_to_file(old_name, { 'test' })
    hg('add', old_name)
    hg('commit', '-m', 'init commit', '-u', 'tester')

    setup_hgsigns(test_config)
    edit(old_name)
    wait_for_attach()

    command('Hgsigns clear_debug')
    hg('mv', old_name, new_name)

    expectf(function()
      eq_bufs({ [1] = new_name })
    end)

    match_dag({
      helpers.p('Hg dir update:'),
      helpers.p('attach%.handle_moved%(1%): File moved to new name%.txt'),
      helpers.p(
        'attach%.handle_moved%(1%): Renamed buffer 1 from '
          .. path_pattern(old_name)
          .. ' to '
          .. path_pattern(new_name)
      ),
    })
  end)

  it('refreshes hg branch head and clears signs after external commit', function()
    setup_test_hg_repo()
    setup_hgsigns(test_config)
    edit(test_file)
    wait_for_attach()

    helpers.feed('gg0Cbranch change<esc>')
    command('write')

    helpers.check({
      status = { head = 'default', added = 0, changed = 1, removed = 0 },
      signs = { changed = 1 },
    })

    command('Hgsigns clear_debug')
    hg('branch', 'feature/foo')

    helpers.check({
      status = { head = 'feature/foo', added = 0, changed = 1, removed = 0 },
      signs = { changed = 1 },
    })

    match_dag({
      helpers.p('Hg dir update:'),
      helpers.p('attach%.repo_update_handler%(1%): Watcher handler called for buffer 1'),
    })

    command('Hgsigns clear_debug')
    hg('commit', '-m', 'external commit', '-u', 'tester')

    helpers.check({
      status = { head = 'feature/foo', added = 0, changed = 0, removed = 0 },
      signs = {},
    })

    eq_path(test_file, helpers.api.nvim_buf_get_name(1))

    match_dag({
      helpers.p('Hg dir update:'),
      helpers.p('attach%.repo_update_handler%(1%): Watcher handler called for buffer 1'),
    })
  end)

  it('does not delete alternate buffers when following moved files', function()
    setup_test_hg_repo()
    setup_hgsigns(test_config)
    edit(test_file)
    local tracked_buf = helpers.api.nvim_get_current_buf()

    wait_for_attach()

    local alt_file = helpers.scratch .. '/alt.txt'
    helpers.write_to_file(alt_file, { 'alt buffer' })
    edit(alt_file)
    local alt_buf = helpers.api.nvim_get_current_buf()

    command('buffer ' .. tracked_buf)

    local test_file2 = test_file .. '2'
    hg('mv', test_file, test_file2)

    helpers.expectf(function()
      eq_bufs({
        [tracked_buf] = test_file2,
        [alt_buf] = alt_file,
      })
    end)
  end)

  it('debounces hg watcher refreshes across multiple buffers', function()
    helpers.hg_init_scratch()

    local f1 = vim.fs.joinpath(helpers.scratch, 'file1')
    local f2 = vim.fs.joinpath(helpers.scratch, 'file2')

    write_to_file(f1, { '1', '2', '3' })
    write_to_file(f2, { '1', '2', '3' })

    hg('add', f1, f2)
    hg('commit', '-m', 'init commit', '-u', 'tester')

    setup_hgsigns(test_config)

    command('edit ' .. f1)
    helpers.feed('Aa<esc>')
    command('write')
    local b1 = helpers.api.nvim_get_current_buf()

    command('split ' .. f2)
    helpers.feed('Ab<esc>')
    command('write')
    local b2 = helpers.api.nvim_get_current_buf()

    helpers.check({ signs = { changed = 1 } }, b1)
    helpers.check({ signs = { changed = 1 } }, b2)

    hg('commit', '-m', 'batch update', '-u', 'tester')

    helpers.check({ signs = {} }, b1)
    helpers.check({ signs = {} }, b2)
  end)

  it('gc proxy closes over handles without retaining watcher', function()
    setup_test_hg_repo()
    helpers.setup_path()

    local result = helpers.exec_lua(function(scratch)
      local async = require('hgsigns.async')
      local Repo = require('hgsigns.git.repo')

      local repo, err = async.run(Repo.get, scratch):wait(5000)
      assert(repo, err)

      local watcher = repo._watcher
      local gc = assert(getmetatable(watcher._gc).__gc)
      local captured = {
        handles = false,
        watcher = false,
      }

      for i = 1, 20 do
        local name, value = debug.getupvalue(gc, i)
        if not name then
          break
        end
        if value == watcher.handles then
          captured.handles = true
        end
        if value == watcher then
          captured.watcher = true
        end
      end

      return captured
    end, helpers.scratch)

    eq(true, result.handles)
    eq(false, result.watcher)
  end)

  it('garbage collects repo and watcher', function()
    setup_test_hg_repo()
    helpers.setup_path()

    local result = helpers.exec_lua(function(scratch)
      local async = require('hgsigns.async')
      local Repo = require('hgsigns.git.repo')

      local repo, err = async.run(Repo.get, scratch):wait(5000)
      assert(repo, err)

      local gitdir = repo.gitdir
      local watcher = repo._watcher
      local handles = {} --- @type uv.uv_fs_event_t[]
      for _, handle in pairs(watcher.handles) do
        handles[#handles + 1] = handle
      end
      assert(#handles > 0)

      local function get_upvalue(fn, key)
        for i = 1, 50 do
          local name, value = debug.getupvalue(fn, i)
          if not name then
            break
          end
          if name == key then
            return value
          end
        end
      end

      local repo_cache = get_upvalue(Repo.get, 'repo_cache')
      assert(repo_cache, 'repo_cache not found')

      local weak = setmetatable({ repo, watcher }, { __mode = 'v' })

      --- @diagnostic disable-next-line: unused, assign-type-mismatch
      watcher, repo = nil, nil

      vim.wait(2000, function()
        collectgarbage('collect')

        local handles_closed = true
        for _, handle in ipairs(handles) do
          handles_closed = handles_closed and handle:is_closing()
        end

        return weak[1] == nil and weak[2] == nil and repo_cache[gitdir] == nil and handles_closed
      end, 20, false)

      return {
        repo_gced = weak[1] == nil,
        watcher_gced = weak[2] == nil,
        cache_cleared = repo_cache[gitdir] == nil,
        handle_closed = (function()
          local closed = true
          for _, handle in ipairs(handles) do
            closed = closed and handle:is_closing()
          end
          return closed
        end)(),
      }
    end, helpers.scratch)

    eq(true, result.repo_gced)
    eq(true, result.watcher_gced)
    eq(true, result.cache_cleared)
    eq(true, result.handle_closed)
  end)

  it('falls back to fs_poll when fs_event fails', function()
    setup_test_hg_repo()
    install_failing_fs_watchers()

    setup_hgsigns(watcher_fallback_test_config)
    edit(test_file)

    helpers.expectf(function()
      return helpers.exec_lua(function()
        local bcache = require('hgsigns.cache').cache[vim.api.nvim_get_current_buf()]
        return bcache ~= nil
          and bcache.git_obj.repo._watcher ~= nil
          and bcache.git_obj.repo._watcher._backend == 'fs_poll'
          and vim.b.hgsigns_status_dict.gitdir ~= nil
      end)
    end)

    hg('commit', '-m', 'external commit', '-u', 'tester', '--allow-empty')

    helpers.check({ status = { head = 'default', added = 0, changed = 0, removed = 0 }, signs = {} })
  end)

  it('recreates fs_poll watches after poll errors', function()
    setup_test_hg_repo()
    install_failing_fs_watchers(true)

    setup_hgsigns(watcher_fallback_test_config)
    edit(test_file)

    helpers.expectf(function()
      return helpers.exec_lua(function()
        local bcache = require('hgsigns.cache').cache[vim.api.nvim_get_current_buf()]
        return bcache ~= nil
          and bcache.git_obj.repo._watcher ~= nil
          and bcache.git_obj.repo._watcher._backend == 'fs_poll'
      end)
    end)

    eq(
      true,
      helpers.exec_lua(function()
        local bcache = require('hgsigns.cache').cache[vim.api.nvim_get_current_buf()]
        local repo = assert(bcache).git_obj.repo
        local watcher = assert(repo._watcher)
        local watched_path, old = next(watcher.handles)
        assert(watched_path and old)

        old._cb('ENOENT', nil, nil)

        local new = assert(watcher.handles[watched_path])
        return old:is_closing() and new ~= old and not new:is_closing()
      end)
    )
  end)
end)
