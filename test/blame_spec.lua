local helpers = require('test.gs_helpers')

local check = helpers.check
local clear = helpers.clear
local edit = helpers.edit
local enable_lua_treesitter_on_filetype = helpers.enable_lua_treesitter_on_filetype
local eq = helpers.eq
local exec_lua = helpers.exec_lua
local expectf = helpers.expectf
local feed = helpers.feed
local fn = helpers.fn
local git = helpers.git
local hg = helpers.hg
local require_source_hls = helpers.require_source_hls
local setup_hgsigns = helpers.setup_hgsigns
local setup_test_repo = helpers.setup_test_repo
local setup_test_hg_repo = helpers.setup_test_hg_repo
local test_config = helpers.test_config
local wait_for_attach = helpers.wait_for_attach
local write_to_file = helpers.write_to_file
local scratch --- @type string
local test_file --- @type string

helpers.env()

local function refresh_paths()
  scratch = helpers.scratch
  test_file = helpers.test_file
end

local function open_blame_window()
  exec_lua(function()
    local async = require('hgsigns.async')
    async.run(require('hgsigns.actions.blame').blame):wait(5000)
  end)

  eq('hgsigns-blame', exec_lua('return vim.bo.filetype'))
end

local function open_full_blame_popup()
  exec_lua(function()
    local async = require('hgsigns.async')
    async.run(require('hgsigns.actions.blame_line'), { full = true }):wait(5000)
  end)

  eq(true, exec_lua("return require('hgsigns.popup').is_open('blame') ~= nil"))
end

local open_blame_panel = open_blame_window

local function get_blame_panel_state()
  return exec_lua(function()
    local bufnr = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local ns = assert(vim.api.nvim_get_namespaces().hgsigns_blame_win)
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
    local row_hls = {} --- @type table<integer, string[]>
    local line_widths = {} --- @type integer[]

    for _, mark in ipairs(marks) do
      local row = mark[2] + 1
      local details = assert(mark[4])
      if details.virt_text_win_col == nil and type(details.hl_group) == 'string' then
        row_hls[row] = row_hls[row] or {}
        row_hls[row][#row_hls[row] + 1] = details.hl_group
      end
    end

    for i, line in ipairs(lines) do
      line_widths[i] = vim.fn.strdisplaywidth(line)
    end

    return {
      date = os.date('%Y-%m-%d'),
      line_widths = line_widths,
      lines = lines,
      row_hls = row_hls,
      win_width = vim.api.nvim_win_get_width(0),
      year = os.date('%Y'),
    }
  end)
end

local function has_hl(row_hls, row, name)
  for _, hl in ipairs(row_hls[row] or {}) do
    if hl == name then
      return true
    end
  end
  return false
end

local function has_hl_match(row_hls, row, pattern)
  for _, hl in ipairs(row_hls[row] or {}) do
    if hl:match(pattern) then
      return true
    end
  end
  return false
end

describe('blame', function()
  before_each(function()
    clear()
    refresh_paths()
    helpers.chdir_tmp()
    setup_hgsigns()
  end)

  it('keeps cursor line on reblame', function()
    setup_hgsigns(test_config)
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

    expectf(function()
      return exec_lua(function(initial_name)
        return vim.bo.filetype == 'hgsigns-blame' and vim.api.nvim_buf_get_name(0) ~= initial_name
      end, initial_blame_bufname)
    end)

    eq({ 3, 0 }, helpers.api.nvim_win_get_cursor(0))
    eq('hgsigns-blame', exec_lua('return vim.bo.filetype'))
  end)

  it('renders the default side-panel layout', function()
    setup_hgsigns(test_config)
    setup_test_repo({
      test_file_text = { 'one', 'two' },
    })

    edit(test_file)
    check({
      status = { head = 'main', added = 0, changed = 0, removed = 0 },
      signs = {},
    })

    open_blame_panel()

    local result = get_blame_panel_state()
    local date_pat = result.date:gsub('%-', '%%-')

    assert(result.lines[1]:match('^┍ %x%x%x%x%x%x%x%x tester ' .. date_pat .. '$'))
    eq('┕ init commit', result.lines[2])
    eq(true, has_hl_match(result.row_hls, 1, '^HgsignsBlameColor%.'))
    eq(true, has_hl(result.row_hls, 2, 'Comment'))
  end)

  it('supports string side-panel formatters', function()
    local config = vim.deepcopy(test_config)
    config.blame_formatter = '<author_time:%Y> <abbrev_sha> <summary>'
    setup_hgsigns(config)
    setup_test_repo({
      test_file_text = { 'one', 'two' },
    })

    edit(test_file)
    check({
      status = { head = 'main', added = 0, changed = 0, removed = 0 },
      signs = {},
    })

    open_blame_panel()

    local result = get_blame_panel_state()

    assert(result.lines[1]:match('^┍ ' .. result.year .. ' %x%x%x%x%x%x%x%x init commit$'))
    eq('┕', result.lines[2])
    eq(true, has_hl_match(result.row_hls, 1, '^HgsignsBlameColor%.'))
    eq(false, has_hl(result.row_hls, 2, 'Comment'))
  end)

  it('does not let repeated summary lines widen the side panel', function()
    setup_hgsigns(test_config)
    setup_test_repo({
      test_file_text = { 'one', 'two' },
    })

    local summary = table.concat({
      'this is a deliberately long commit summary',
      'that should not widen the blame side panel',
    }, ' ')

    helpers.write_to_file(test_file, { 'ONE', 'TWO' })
    helpers.git('add', test_file)
    helpers.git('commit', '-m', summary)

    edit(test_file)
    check({
      status = { head = 'main', added = 0, changed = 0, removed = 0 },
      signs = {},
    })

    open_blame_panel()

    local result = get_blame_panel_state()

    eq(true, result.line_widths[2] > result.line_widths[1])
    eq(result.line_widths[1] + 1, result.win_width)
  end)

  it('supports function side-panel formatters with highlights', function()
    setup_hgsigns(test_config)
    exec_lua(function()
      require('hgsigns.config').config.blame_formatter = function(_name, info, context)
        return {
          { info.abbrev_sha, context.hash_hl_group },
          { ' ' },
          { info.author, 'ErrorMsg' },
          { ' ' },
          { os.date('%Y', info.author_time), 'WarningMsg' },
        },
          false
      end
    end)

    setup_test_repo({
      test_file_text = { 'one', 'two' },
    })

    edit(test_file)
    check({
      status = { head = 'main', added = 0, changed = 0, removed = 0 },
      signs = {},
    })

    open_blame_panel()

    local result = get_blame_panel_state()

    assert(result.lines[1]:match('^┍ %x%x%x%x%x%x%x%x tester ' .. result.year .. '$'))
    eq('┕', result.lines[2])
    eq(true, has_hl_match(result.row_hls, 1, '^HgsignsBlameColor%.'))
    eq(true, has_hl(result.row_hls, 1, 'ErrorMsg'))
    eq(true, has_hl(result.row_hls, 1, 'WarningMsg'))
    eq(false, has_hl(result.row_hls, 2, 'Comment'))
  end)

  it('falls back when function side-panel formatters return strings', function()
    setup_hgsigns(test_config)
    exec_lua(function()
      require('hgsigns.config').config.blame_formatter = function()
        return 'not chunks'
      end
    end)

    setup_test_repo({
      test_file_text = { 'one', 'two' },
    })

    edit(test_file)
    check({
      status = { head = 'main', added = 0, changed = 0, removed = 0 },
      signs = {},
    })

    open_blame_panel()

    local result = get_blame_panel_state()
    local date_pat = result.date:gsub('%-', '%%-')

    assert(result.lines[1]:match('^┍ %x%x%x%x%x%x%x%x tester ' .. date_pat .. '$'))
    eq('┕ init commit', result.lines[2])
    eq(true, has_hl_match(result.row_hls, 1, '^HgsignsBlameColor%.'))
    eq(true, has_hl(result.row_hls, 2, 'Comment'))
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
            captured_args = captured_args or vim.deepcopy(argv)
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
    setup_hgsigns(test_config)

    local relpath = '.config/nvim/lua/mappings.lua'
    local file = scratch .. '/' .. relpath

    write_to_file(file, { 'hello', 'world' })
    git('add', file)
    git('commit', '-m', 'add nested mappings')

    edit(file)

    wait_for_attach()

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

  it('reuses source highlight stacks in the full blame popup hunk', function()
    require_source_hls()

    setup_test_hg_repo({
      test_file_text = {
        'local foo = 1',
      },
    })

    helpers.write_to_file(test_file, {
      'local bar = 1',
    })
    helpers.hg('add', test_file)
    helpers.hg('commit', '-m', 'rename foo', '-u', 'tester')

    local config = vim.deepcopy(test_config)
    config.gh = true
    setup_hgsigns(config)
    edit(test_file)
    enable_lua_treesitter_on_filetype('hgsigns_blame_treesitter')

    check({
      status = { head = 'default', added = 0, changed = 0, removed = 0 },
      signs = {},
    })

    exec_lua(function()
      package.loaded['hgsigns.gh'] = {
        commit_url = function()
          return 'https://example.test/commit'
        end,
        create_pr_linespec = function()
          return { { '#1 ', 'Title', 'https://example.test/pr/1' } }
        end,
      }
    end)

    open_full_blame_popup()

    expectf(function()
      local result = exec_lua(function()
        local function expected_line_hls(line, line_hl, inline_hl, region)
          local preview_buf = vim.api.nvim_create_buf(false, true)
          vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, { line })
          vim.bo[preview_buf].filetype = vim.bo.filetype
          vim.bo[preview_buf].tabstop = vim.bo.tabstop
          if vim.bo.syntax ~= '' then
            vim.bo[preview_buf].syntax = vim.bo.syntax
          end
          local ok, parser = pcall(vim.treesitter.get_parser, preview_buf, 'lua')
          assert(ok and parser)
          pcall(parser.parse, parser, true)

          local ns_preview = vim.api.nvim_create_namespace('hgsigns_test_blame_expected')
          vim.api.nvim_buf_set_extmark(preview_buf, ns_preview, 0, 0, {
            hl_group = line_hl,
            hl_eol = true,
            end_row = 1,
            priority = 1000,
          })
          vim.api.nvim_buf_set_extmark(preview_buf, ns_preview, 0, region[3] - 1, {
            hl_group = inline_hl,
            end_col = region[4] - 1,
            end_row = 0,
            priority = 1001,
          })

          local diff_col = region[3] - 1
          local inspected = require('hgsigns.inspect').inspect_range(preview_buf, 0, 0, #line)
          local keyword = require('hgsigns.inspect').hl_stack_at(inspected, 0)
          local diff = require('hgsigns.inspect').hl_stack_at(inspected, diff_col)

          vim.api.nvim_buf_delete(preview_buf, { force = true })

          return keyword, diff, diff_col
        end

        local popup_win = require('hgsigns.popup').is_open('blame')
        if not popup_win then
          return
        end

        local popup_buf = vim.api.nvim_win_get_buf(popup_win)
        local lines = vim.api.nvim_buf_get_lines(popup_buf, 0, -1, false)
        local deleted_row, added_row

        for i, line in ipairs(lines) do
          if line == '-local foo = 1' then
            deleted_row = i - 1
          elseif line == '+local bar = 1' then
            added_row = i - 1
          end
        end

        if deleted_row == nil or added_row == nil then
          return
        end

        local Inspect = require('hgsigns.inspect')
        local removed_regions, added_regions = require('hgsigns.diff_int').run_word_diff(
          { 'local foo = 1' },
          { 'local bar = 1' }
        )
        local expected_deleted_keyword, expected_deleted_diff, deleted_diff_col = expected_line_hls(
          'local foo = 1',
          'HgsignsDeletePreview',
          'HgsignsDeleteInline',
          removed_regions[1]
        )
        local expected_added_keyword, expected_added_diff, added_diff_col = expected_line_hls(
          'local bar = 1',
          'HgsignsAddPreview',
          added_regions[1][2] == 'add' and 'HgsignsAddInline'
            or added_regions[1][2] == 'change' and 'HgsignsChangeInline'
            or 'HgsignsDeleteInline',
          added_regions[1]
        )
        local deleted = Inspect.inspect_range(popup_buf, deleted_row, 0, #'-local foo = 1')
        local added = Inspect.inspect_range(popup_buf, added_row, 0, #'+local bar = 1')

        return {
          title = lines[1],
          expected_deleted_keyword = expected_deleted_keyword,
          actual_deleted_keyword = Inspect.hl_stack_at(deleted, 1),
          expected_deleted_diff = expected_deleted_diff,
          actual_deleted_diff = Inspect.hl_stack_at(deleted, deleted_diff_col + 1),
          expected_added_keyword = expected_added_keyword,
          actual_added_keyword = Inspect.hl_stack_at(added, 1),
          expected_added_diff = expected_added_diff,
          actual_added_diff = Inspect.hl_stack_at(added, added_diff_col + 1),
        }
      end)

      assert(result)
      eq(result.expected_deleted_keyword, result.actual_deleted_keyword)
      eq(result.expected_deleted_diff, result.actual_deleted_diff)
      eq(result.expected_added_keyword, result.actual_added_keyword)
      eq(result.expected_added_diff, result.actual_added_diff)
      assert(result.title:find('#1', 1, true))
    end)
  end)

  it('extends full blame popup line highlights to the end of the line', function()
    setup_test_hg_repo({
      test_file_text = {
        'local foo = 1',
      },
    })

    helpers.write_to_file(test_file, {
      'local bar = 1',
    })
    helpers.hg('add', test_file)
    helpers.hg('commit', '-m', 'rename foo', '-u', 'tester')

    local config = vim.deepcopy(test_config)
    config.gh = true
    setup_hgsigns(config)
    edit(test_file)
    check({
      status = { head = 'default', added = 0, changed = 0, removed = 0 },
      signs = {},
    })

    exec_lua(function()
      package.loaded['hgsigns.gh'] = {
        commit_url = function()
          return 'https://example.test/commit'
        end,
        create_pr_linespec = function()
          return { { '#1 ', 'Title', 'https://example.test/pr/1' } }
        end,
      }
    end)

    open_full_blame_popup()

    local result
    expectf(function()
      result = exec_lua(function()
        local popup_win = require('hgsigns.popup').is_open('blame')
        if not popup_win then
          return
        end
        local popup_buf = vim.api.nvim_win_get_buf(popup_win)
        local lines = vim.api.nvim_buf_get_lines(popup_buf, 0, -1, false)
        local ns = assert(vim.api.nvim_get_namespaces().hgsigns_popup)
        local marks = vim.api.nvim_buf_get_extmarks(popup_buf, ns, 0, -1, { details = true })

        local deleted_row, added_row
        for i, line in ipairs(lines) do
          if line == '-local foo = 1' then
            deleted_row = i - 1
          elseif line == '+local bar = 1' then
            added_row = i - 1
          end
        end

        if deleted_row == nil or added_row == nil then
          return
        end

        local deleted_eol0, added_eol0 = false, false
        for _, mark in ipairs(marks) do
          local row = mark[2]
          local col = mark[3]
          local details = assert(mark[4])
          if
            details.hl_group == 'HgsignsDeletePreview'
            and row == deleted_row
            and col == 0
            and details.end_row == deleted_row + 1
            and details.end_col == 0
          then
            deleted_eol0 = true
          elseif
            details.hl_group == 'HgsignsAddPreview'
            and row == added_row
            and col == 0
            and details.end_row == added_row + 1
            and details.end_col == 0
          then
            added_eol0 = true
          end
        end

        return {
          deleted_eol = deleted_eol0,
          added_eol = added_eol0,
        }
      end)

      assert(result and result.deleted_eol and result.added_eol)
    end)
  end)
end)
