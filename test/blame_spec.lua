local helpers = require('test.gs_helpers')

local setup_hgsigns = helpers.setup_hgsigns
local feed = helpers.feed
local test_file = helpers.test_file
local edit = helpers.edit
local exec_lua = helpers.exec_lua
local test_config = helpers.test_config
local clear = helpers.clear
local setup_test_repo = helpers.setup_test_repo
local setup_test_hg_repo = helpers.setup_test_hg_repo
local eq = helpers.eq
local check = helpers.check
local expectf = helpers.expectf
local git = helpers.git
local hg = helpers.hg
local scratch = helpers.scratch
local write_to_file = helpers.write_to_file

helpers.env()

local function open_blame_window()
  exec_lua(function()
    local async = require('hgsigns.async')
    async.run(require('hgsigns.actions.blame').blame):raise_on_error()
  end)

  eq(
    true,
    exec_lua(function()
      return vim.wait(10000, function()
        return vim.bo.filetype == 'hgsigns-blame'
      end)
    end)
  )
end

local function open_full_blame_popup()
  exec_lua(function()
    local async = require('hgsigns.async')
    async.run(require('hgsigns.actions.blame_line'), { full = true }):raise_on_error()
  end)

  eq(
    true,
    exec_lua(function()
      return vim.wait(5000, function()
        return require('hgsigns.popup').is_open('blame') ~= nil
      end)
    end)
  )
end

describe('blame', function()
  before_each(function()
    clear()
    helpers.chdir_tmp()
    setup_hgsigns(test_config)
  end)

  it('keeps cursor line on reblame', function()
    setup_test_repo({
      test_file_text = { 'one', 'two', 'three', 'four', 'five' },
    })
    helpers.write_to_file(test_file, { 'ONE', 'two', 'three', 'four', 'five' })
    helpers.git('add', test_file)
    helpers.git('commit', '-m', 'second commit')

    edit(test_file)
    check({
      status = { head = 'main', added = 0, changed = 0, removed = 0 },
      signs = {},
    })
    open_blame_window()

    local initial_blame_bufname = exec_lua('return vim.api.nvim_buf_get_name(0)')

    feed('3G')
    feed('r')

    eq(
      true,
      exec_lua(function(initial_name)
        return vim.wait(5000, function()
          return vim.bo.filetype == 'hgsigns-blame' and vim.api.nvim_buf_get_name(0) ~= initial_name
        end)
      end, initial_blame_bufname)
    )

    eq({ 3, 0 }, helpers.api.nvim_win_get_cursor(0))
    eq('hgsigns-blame', exec_lua('return vim.bo.filetype'))
  end)

  it('keeps cursor line on mercurial reblame', function()
    setup_test_hg_repo({
      test_file_text = { 'one', 'two', 'three', 'four', 'five' },
    })
    write_to_file(test_file, { 'ONE', 'two', 'three', 'four', 'five' })
    hg('commit', '-A', '-m', 'second commit', '-u', 'tester')

    edit(test_file)
    check({
      status = { head = 'default', added = 0, changed = 0, removed = 0 },
      signs = {},
    })
    open_blame_window()

    local initial_blame_bufname = exec_lua('return vim.api.nvim_buf_get_name(0)')

    feed('3G')
    feed('r')

    eq(
      true,
      exec_lua(function(initial_name)
        return vim.wait(5000, function()
          return vim.bo.filetype == 'hgsigns-blame' and vim.api.nvim_buf_get_name(0) ~= initial_name
        end)
      end, initial_blame_bufname)
    )

    eq({ 3, 0 }, helpers.api.nvim_win_get_cursor(0))
    eq('hgsigns-blame', exec_lua('return vim.bo.filetype'))
  end)

  it('keeps the mercurial blame window open when parent reblame has no parent', function()
    setup_test_hg_repo()

    edit(test_file)
    check({
      status = { head = 'default', added = 0, changed = 0, removed = 0 },
      signs = {},
    })
    open_blame_window()

    local initial_blame_bufname = exec_lua('return vim.api.nvim_buf_get_name(0)')

    feed('R')

    eq(
      true,
      exec_lua(function(initial_name)
        return vim.wait(2000, function()
          return vim.bo.filetype == 'hgsigns-blame' and vim.api.nvim_buf_get_name(0) == initial_name
        end)
      end, initial_blame_bufname)
    )

    eq({ 1, 0 }, helpers.api.nvim_win_get_cursor(0))
  end)

  it('uses a repo-relative path when running blame', function()
    local args = exec_lua(function()
      local blame = require('hgsigns.git.blame')

      local captured_args
      local obj = {
        file = 'C:/msys64/home/User/.dotfiles/.config/nvim/lua/mappings.lua',
        relpath = '.config/nvim/lua/mappings.lua',
        object_name = ('a'):rep(40),
        repo = {
          abbrev_head = 'main',
          toplevel = 'C:/msys64/home/User/.dotfiles',
          command = function(_, argv, spec)
            captured_args = vim.deepcopy(argv)
            spec.stdout(
              nil,
              table.concat({
                ('a'):rep(40) .. ' 1 1 1',
                'author tester',
                'author-mail <tester@example.com>',
                'author-time 0',
                'author-tz +0000',
                'committer tester',
                'committer-mail <tester@example.com>',
                'committer-time 0',
                'committer-tz +0000',
                'summary init',
                'filename .config/nvim/lua/mappings.lua',
                '',
              }, '\n')
            )
            return {}, nil, 0
          end,
        },
      }

      blame.run_blame(obj, { 'line' }, 1, nil, {})

      return captured_args
    end)

    eq('--', args[#args - 1])
    eq('.config/nvim/lua/mappings.lua', args[#args])
  end)

  it('parses mercurial annotate output with repo-relative nested paths', function()
    local result = exec_lua(function()
      local blame = require('hgsigns.git.blame')

      local relpath = 'nested dir/file name.lua'
      local encoded = vim.json.encode({
        {
          path = relpath,
          lines = {
            {
              node = string.rep('a', 40),
              rev = 12,
              lineno = 1,
              user = 'tester person',
              date = { 1710000000, 0 },
              line = 'first line\n',
            },
            {
              node = string.rep('b', 40),
              rev = 13,
              lineno = 2,
              user = 'reviewer person',
              date = { 1710003600, 0 },
              line = 'second line\n',
            },
          },
        },
      })

      local captured_args
      local obj = {
        file = 'C:/repo/' .. relpath,
        relpath = relpath,
        object_name = string.rep('f', 40),
        repo = {
          vcs = 'hg',
          abbrev_head = 'default',
          toplevel = 'C:/repo',
          get_parent_revision = function()
            return nil
          end,
          get_previous_path = function(_, _, path)
            return path
          end,
          command = function(_, argv, _)
            captured_args = vim.deepcopy(argv)
            return vim.split(encoded, '\n', { plain = true }), nil, 0
          end,
        },
      }

      local blame_entries, commits = blame.run_blame(obj, nil, nil, nil, {})
      local blame_info = assert(blame_entries[2])

      return {
        argv = captured_args,
        filename = blame_info.filename,
        sha = blame_info.commit.sha,
        abbrev_sha = blame_info.commit.abbrev_sha,
        author = blame_info.commit.author,
        author_time = blame_info.commit.author_time,
        summary = blame_info.commit.summary,
        commits = vim.tbl_count(commits),
      }
    end)

    eq('annotate', result.argv[1])
    eq(true, vim.tbl_contains(result.argv, '--template'))
    eq(true, vim.tbl_contains(result.argv, 'json'))
    eq('nested dir/file name.lua', result.argv[#result.argv])
    eq('nested dir/file name.lua', result.filename)
    eq(string.rep('b', 40), result.sha)
    eq(string.rep('b', 12), result.abbrev_sha)
    eq('reviewer person', result.author)
    eq(1710003600, result.author_time)
    eq('Version of nested dir/file name.lua', result.summary)
    eq(2, result.commits)
  end)

  it('derives mercurial previous revision metadata for renamed lines', function()
    local result = exec_lua(function()
      local blame = require('hgsigns.git.blame')

      local parent_sha = string.rep('a', 40)
      local commit_sha = string.rep('b', 40)
      local relpath = 'renamed.txt'
      local encoded = vim.json.encode({
        {
          path = relpath,
          lines = {
            {
              node = parent_sha,
              rev = 0,
              lineno = 1,
              user = 'tester person',
              date = { 1710000000, 0 },
              line = 'one\n',
            },
            {
              node = commit_sha,
              rev = 1,
              lineno = 2,
              user = 'reviewer person',
              date = { 1710003600, 0 },
              line = 'TWO\n',
            },
          },
        },
      })

      local calls = {}
      local obj = {
        file = 'C:/repo/' .. relpath,
        relpath = relpath,
        object_name = commit_sha,
        repo = {
          vcs = 'hg',
          abbrev_head = 'default',
          toplevel = 'C:/repo',
          command = function(_, argv, _)
            calls[#calls + 1] = vim.deepcopy(argv)

            if argv[1] == 'annotate' then
              return vim.split(encoded, '\n', { plain = true }), nil, 0
            end

            if argv[1] == 'log' then
              -- Return parent + copy info for both unique shas.
              -- parent_sha has no parent (null hash); commit_sha's parent is parent_sha.
              -- renamed.txt was added in commit_sha by renaming from file.txt.
              local null_hash = string.rep('0', 40)
              local lines = {
                parent_sha .. ' ' .. null_hash,
                commit_sha .. ' ' .. parent_sha,
                'copy ' .. commit_sha .. ' ' .. relpath .. '\t' .. 'file.txt',
              }
              return lines, nil, 0
            end

            error('unexpected hg command: ' .. vim.inspect(argv))
          end,
        },
      }

      local blame_entries = blame.run_blame(obj, nil, nil, nil, {})
      local first = assert(blame_entries[1])
      local second = assert(blame_entries[2])

      return {
        first_has_previous = first.previous_sha ~= nil or first.previous_filename ~= nil,
        second_previous_sha = second.previous_sha,
        second_previous_filename = second.previous_filename,
        log_calls = vim.tbl_count(vim.tbl_filter(function(argv)
          return argv[1] == 'log'
        end, calls)),
        annotate_calls = vim.tbl_count(vim.tbl_filter(function(argv)
          return argv[1] == 'annotate'
        end, calls)),
      }
    end)

    eq(false, result.first_has_previous)
    eq(string.rep('a', 40), result.second_previous_sha)
    eq('file.txt', result.second_previous_filename)
    eq(1, result.log_calls)
    eq(1, result.annotate_calls)
  end)

  it('shows the mercurial blame popup hunk for renamed history', function()
    setup_test_hg_repo({
      test_file_text = { 'one', 'two', 'three' },
    })

    local renamed = scratch .. '/renamed.txt'
    hg('mv', test_file, renamed)
    write_to_file(renamed, { 'one', 'TWO', 'three' })
    hg('commit', '-A', '-m', 'rename and edit', '-u', 'tester')

    edit(renamed)
    check({
      status = { head = 'default', added = 0, changed = 0, removed = 0 },
      signs = {},
    })

    feed('2G')
    open_full_blame_popup()

    local popup_text = table.concat(
      exec_lua(function()
        local popup = require('hgsigns.popup')
        local winid = assert(popup.is_open('blame'))
        local bufnr = vim.api.nvim_win_get_buf(winid)
        return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      end),
      '\n'
    )

    eq(nil, popup_text:find('File added in commit', 1, true))
    eq(true, popup_text:find('Hunk 1 of 1', 1, true) ~= nil)
    eq(true, popup_text:find('-two', 1, true) ~= nil)
    eq(true, popup_text:find('+TWO', 1, true) ~= nil)
  end)

  it('opens mercurial blame diff navigation for renamed history', function()
    setup_test_hg_repo({
      test_file_text = { 'one', 'two', 'three' },
    })

    local renamed = scratch .. '/renamed.txt'
    hg('mv', test_file, renamed)
    write_to_file(renamed, { 'one', 'TWO', 'three' })
    hg('commit', '-A', '-m', 'rename and edit', '-u', 'tester')

    edit(renamed)
    check({
      status = { head = 'default', added = 0, changed = 0, removed = 0 },
      signs = {},
    })
    open_blame_window()

    feed('2G')
    feed('d')

    eq(
      true,
      exec_lua(function()
        return vim.wait(5000, function()
          local wins = vim.api.nvim_tabpage_list_wins(0)
          if #wins ~= 2 then
            return false
          end

          for _, win in ipairs(wins) do
            if not vim.wo[win].diff then
              return false
            end
          end

          return true
        end)
      end)
    )

    local result = exec_lua(function()
      local diff_lines = {}
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local buf = vim.api.nvim_win_get_buf(win)
        diff_lines[#diff_lines + 1] = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
      end
      table.sort(diff_lines)
      return diff_lines
    end)

    eq({ 'TWO', 'two' }, result)
  end)

  it('blames a tracked file in a nested path', function()
    helpers.git_init_scratch()

    local relpath = '.config/nvim/lua/mappings.lua'
    local file = scratch .. '/' .. relpath

    write_to_file(file, { 'hello', 'world' })
    git('add', file)
    git('commit', '-m', 'add nested mappings')

    edit(file)

    expectf(function()
      return exec_lua(function()
        return vim.b.hgsigns_status_dict.gitdir ~= nil
      end)
    end)

    local result = exec_lua(function(file0)
      local async = require('hgsigns.async')
      return async
        .run(function()
          local Git = require('hgsigns.git')
          local encoding = vim.bo.fileencoding
          if encoding == '' then
            encoding = 'utf-8'
          end

          local obj = assert(Git.Obj.new(file0, nil, encoding))
          local blame_entries = obj:run_blame(nil, 1, nil, {})
          local blame_info = blame_entries and blame_entries[1]

          return {
            relpath = obj.relpath,
            file = obj.file,
            filename = blame_info and blame_info.filename or '',
            sha = blame_info and blame_info.commit and blame_info.commit.sha or '',
          }
        end)
        :wait(5000)
    end, file)

    eq(relpath, result.relpath)
    eq(false, result.file == result.relpath)
    eq(relpath, result.filename)
    eq(false, result.sha == '')
  end)
end)
