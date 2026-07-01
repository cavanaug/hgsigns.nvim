local Screen = require('nvim-test.screen')
local helpers = require('test.gs_helpers')

local api = helpers.api
local check = helpers.check
local cleanup = helpers.cleanup
local clear = helpers.clear
local command = api.nvim_command
local command_wait_hgsigns_update = helpers.command_wait_hgsigns_update
local edit = helpers.edit
local eq = helpers.eq
local eq_path = helpers.eq_path
local exec_lua = helpers.exec_lua
local expectf = helpers.expectf
local feed = helpers.feed
local get_buf_var = api.nvim_buf_get_var
local hg = helpers.hg
local insert = helpers.insert
local match_dag = helpers.match_dag
local match_debug_messages = helpers.match_debug_messages
local match_lines = helpers.match_lines
local n, p, np = helpers.n, helpers.p, helpers.np
local path_pattern = helpers.path_pattern
local setup_hgsigns = helpers.setup_hgsigns
local setup_test_repo = helpers.setup_test_hg_repo
local setup_test_hg_repo = helpers.setup_test_hg_repo
local split = vim.split
local test_config = helpers.test_config
local wait_for_attach = helpers.wait_for_attach
local write_to_file = helpers.write_to_file
local fn = helpers.fn
local newfile --- @type string
local scratch --- @type string
local test_file --- @type string

helpers.env()

local function refresh_paths()
  newfile = helpers.newfile
  scratch = helpers.scratch
  test_file = helpers.test_file
end

local revparse_pat = 'system.system: hg %-%-config ui%.relative%-paths=false root'
local attach_open_pat = 'attach%.attach%(1%): Attaching %(trigger=Buf%u%l+%u%l+%)'

describe('hgsigns (with screen)', function()
  local screen --- @type test.screen
  local config --- @type table

  before_each(function()
    clear()
    refresh_paths()
    screen = Screen.new(20, 17)
    screen:attach({ ext_messages = true })

    local default_attrs = {
      [1] = { foreground = Screen.colors.DarkBlue, background = Screen.colors.WebGray },
      [2] = { foreground = Screen.colors.DodgerBlue },
      [3] = { foreground = Screen.colors.SeaGreen },
      [4] = { foreground = Screen.colors.Red },
      [5] = { foreground = Screen.colors.Brown },
      [6] = { foreground = Screen.colors.Blue1, bold = true },
      [7] = { bold = true },
      [8] = { foreground = Screen.colors.White, background = Screen.colors.Red },
      [9] = { foreground = Screen.colors.SeaGreen, bold = true },
      [11] = { foreground = Screen.colors.Red1, background = Screen.colors.WebGray },
      [12] = { foreground = Screen.colors.DodgerBlue, background = Screen.colors.WebGray },
    }

    -- Use the classic vim colorscheme, not the new defaults in nvim >= 0.10
    if fn.has('nvim-0.12') == 0 then
      default_attrs[2].foreground = Screen.colors.NvimDarkCyan
      default_attrs[3].foreground = Screen.colors.NvimDarkGreen
      default_attrs[4].foreground = Screen.colors.NvimDarkRed
      default_attrs[11].foreground = Screen.colors.NvimDarkRed
      default_attrs[12] =
        { foreground = Screen.colors.NvimDarkCyan, background = Screen.colors.Gray }
    end

    command('colorscheme vim')

    screen:set_default_attr_ids(default_attrs)

    config = vim.deepcopy(test_config)
    helpers.chdir_tmp()
  end)

  after_each(function()
    cleanup()
    screen:detach()
  end)

  it('can run basic setup', function()
    setup_hgsigns()
    check({ status = {}, signs = {} })
  end)

  it('gitdir watcher works on a fresh repo', function()
    --- @type integer
    local nvim_ver = exec_lua('return vim.version().minor')
    screen:try_resize(20, 6)
    setup_test_repo({ no_add = true })
    -- Don't set this too low, or else the test will lock up
    config.watch_gitdir = { interval = 100 }
    setup_hgsigns(config)
    edit(test_file)

    match_dag({
      'attach.attach(1): Attaching (trigger=BufReadPost)',
      p('system.system: hg %-%-config ui%.relative%-paths=false root'),
      p('system.system: hg %-%-config ui%.relative%-paths=false branch'),
      p('attach%.attach%(1%): Watching hg dir .*'),
    })

    check({
      status = { head = 'default', added = 18, changed = 0, removed = 0 },
      signs = { untracked = nvim_ver == 9 and 8 or 7 },
    })

    hg('add', test_file)
    hg('commit', '-m', 'init commit', '-u', 'tester')

    check({
      status = { head = 'default', added = 0, changed = 0, removed = 0 },
      signs = {},
    })
  end)

  it('attaches in a fresh hg repo and exposes .hg metadata', function()
    --- @type integer
    local nvim_ver = exec_lua('return vim.version().minor')
    screen:try_resize(20, 6)
    setup_test_hg_repo({ no_add = true })
    config.watch_gitdir = { interval = 100 }
    setup_hgsigns(config)
    edit(test_file)

    match_dag({
      'attach.attach(1): Attaching (trigger=BufReadPost)',
      p('system.system: hg %-%-config ui%.relative%-paths=false root'),
      p('system.system: hg %-%-config ui%.relative%-paths=false branch'),
      p('attach%.attach%(1%): Watching hg dir .*%.hg'),
    })

    check({
      status = { head = 'default', added = 18, changed = 0, removed = 0 },
      signs = { untracked = nvim_ver == 9 and 8 or 7 },
    })

    eq_path(scratch .. '/.hg', exec_lua([[return vim.b.hgsigns_status_dict.gitdir]]))
  end)

  it('reports slash hg branch names in buffer status', function()
    setup_test_hg_repo({ branch = 'feature/foo' })
    setup_hgsigns(config)
    edit(test_file)
    wait_for_attach()

    check({
      status = { head = 'feature/foo', added = 0, changed = 0, removed = 0 },
      signs = {},
    })

    eq_path(scratch .. '/.hg', exec_lua([[return vim.b.hgsigns_status_dict.gitdir]]))
  end)

  it('can open files not in a hg repo', function()
    setup_hgsigns(config)
    local tmpfile = helpers.tempname()
    edit(tmpfile)

    match_dag({
      p(attach_open_pat),
      p(revparse_pat),
      p('git%.new: Not in hg repo'),
      p('attach%.attach%(1%): Empty hg obj'),
    })
    command('Hgsigns clear_debug')

    insert('line')
    command('write')

    match_dag({
      p('attach%.attach%(1%): Attaching %(trigger=BufWritePost%)'),
      p(revparse_pat),
      p('git%.new: Not in hg repo'),
      p('attach%.attach%(1%): Empty hg obj'),
    })
  end)

  describe('when attaching', function()
    before_each(function()
      setup_test_repo()
      setup_hgsigns(config)
    end)

    it('can setup mappings', function()
      edit(test_file)
      expectf(function()
        local res = split(api.nvim_exec2('nmap <buffer>', { output = true }).output, '\n')
        table.sort(res)

        -- Check all keymaps get set
        match_lines(res, {
          n('n  mhp         *@<Cmd>lua require"hgsigns".preview_hunk()<CR>'),
          n('n  mhr         *@<Cmd>lua require"hgsigns".reset_hunk()<CR>'),
        })
      end)
    end)

    it("doesn't attach to ignored files", function()
      write_to_file(scratch .. '/.hgignore', { 'syntax: glob', 'dummy_ignored.txt' })

      local ignored_file = scratch .. '/dummy_ignored.txt'

      helpers.touch(ignored_file)
      edit(ignored_file)

      match_debug_messages({
        'attach.attach(1): Attaching (trigger=BufReadPost)',
        np('attach%.attach%(1%): Cannot resolve file in repo'),
      })

      check({ status = { head = 'default' } })
    end)

    it("doesn't attach to non-existent files with non-existent sub-dirs", function()
      edit(scratch .. '/does/not/exist')

      match_debug_messages({
        'attach.attach(1): Attaching (trigger=BufNewFile)',
        n('attach.attach(1): Not a path'),
      })

      helpers.pcall_err(get_buf_var, 0, 'hgsigns_head')
      helpers.pcall_err(get_buf_var, 0, 'hgsigns_status_dict')
    end)

    it('can run copen', function()
      command('copen')
      match_debug_messages({
        'attach.attach(2): Attaching (trigger=BufReadPost)',
        n('attach.attach(2): Non-normal buffer'),
      })
    end)

    it('can run get_hunks()', function()
      edit(test_file)
      insert('line1')
      feed('oline2<esc>')

      expectf(function()
        eq({
          {
            head = '@@ -1,1 +1,2 @@',
            type = 'change',
            lines = { '-This', '+line1This', '+line2' },
            added = { count = 2, start = 1, lines = { 'line1This', 'line2' } },
            removed = { count = 1, start = 1, lines = { 'This' } },
          },
        }, exec_lua([[return require'hgsigns'.get_hunks()]]))
      end)
    end)
  end)

  describe('current line blame', function()
    before_each(function()
      config.current_line_blame = true
      config.current_line_blame_formatter = ' <author>, <author_time:%R> - <summary>'
      config.current_line_blame_opts = { delay = 1 }
      setup_hgsigns(config)
    end)

    local function stub_notify_once()
      exec_lua(function()
        _G.__gitsigns_notify_once_orig = vim.notify_once
        vim.notify_once = function() end
      end)
    end

    local function restore_notify_once()
      exec_lua(function()
        if _G.__gitsigns_notify_once_orig then
          vim.notify_once = _G.__gitsigns_notify_once_orig
          _G.__gitsigns_notify_once_orig = nil
        end
      end)
    end

    after_each(function()
      restore_notify_once()
    end)

    local function blame_line_ui_test(file_ending)
      setup_test_repo()
      exec_lua([[vim.g.editorconfig = false]])

      if file_ending == 'dos' then
        write_to_file(newfile, { 'This', 'is', 'a', 'windows', 'file' }, {
          newline = '\r\n',
        })
      else
        write_to_file(newfile, { 'This', 'is', 'a', 'windows', 'file' })
      end

      hg('add', newfile)
      hg('commit', '-m', 'commit on main', '-u', 'tester')

      edit(newfile)
      feed('gg')
      check({ signs = {} })

      screen:expect({
        grid = [[
        ^{MATCH:This {6: You, .*}}|
        is                  |
        a                   |
        windows             |
        file                |
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
      ]],
      })
    end

    it('does handle dos fileformats', function()
      -- Add a file with windows line endings into the repo.
      -- hg stores files verbatim, so the \r\n line endings are preserved.
      blame_line_ui_test('dos')
    end)

    it('does handle unix', function()
      blame_line_ui_test('unix')
    end)

    it('falls back when function formatters return invalid virt_text', function()
      -- nvim 0.10.4 can hang screen tests that render notify_once messages.
      -- This spec only cares about falling back to the default formatter.
      stub_notify_once()

      exec_lua(function()
        require('hgsigns.config').config.current_line_blame_formatter = function()
          return 'not virt_text'
        end
      end)

      setup_test_repo()
      edit(test_file)
      feed('gg')
      check({ signs = {} })

      expectf(function()
        local line = exec_lua('return vim.b.hgsigns_blame_line')
        return line ~= nil and line ~= 'not virt_text' and line:match('^ You, ') ~= nil
      end)
    end)
  end)

  describe('falls back from right_align to eol when text is too long  (#1322)', function()
    before_each(function()
      setup_test_repo({
        test_file_text = {
          'short',
          string.rep('a', 25),
          string.rep('b', 40),
        },
      })

      config.current_line_blame = true
      config.current_line_blame_formatter = ' <author>, <author_time:%R> - <summary>'
      config.current_line_blame_opts = {
        virt_text_pos = 'right_align',
        delay = 1,
      }
      setup_hgsigns(config)
    end)

    it('with nowrap', function()
      edit(test_file)
      command('set nowrap')
      feed('gg')

      screen:expect({
        grid = [[
        ^short {MATCH:{6: You, .*}}|
        aaaaaaaaaaaaaaaaaaaa|
        bbbbbbbbbbbbbbbbbbbb|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
      ]],
      })

      -- Medium line: blame should fallback to eol (no space for right_align)
      feed('j')
      screen:expect({
        grid = [[
        short               |
        ^aaaaaaaaaaaaaaaaaaaa|
        bbbbbbbbbbbbbbbbbbbb|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
      ]],
      })

      -- Move to very long line
      feed('j')
      screen:expect({
        grid = [[
        short               |
        aaaaaaaaaaaaaaaaaaaa|
        ^bbbbbbbbbbbbbbbbbbbb|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
      ]],
      })
    end)

    it('with wrap', function()
      edit(test_file)
      command('set wrap')
      feed('gg')

      -- Short line: blame should appear with right_align (normal behavior)
      screen:expect({
        grid = [[
        ^short {MATCH:{6: You, .*}}|
        aaaaaaaaaaaaaaaaaaaa|
        aaaaa               |
        bbbbbbbbbbbbbbbbbbbb|
        bbbbbbbbbbbbbbbbbbbb|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
      ]],
      })

      -- Move to medium line (will wrap and blame appears at end of wrapped line)
      feed('j')
      screen:expect({
        grid = [[
        short               |
        ^aaaaaaaaaaaaaaaaaaaa|
        {MATCH:aaaaa {6: You, .*}}|
        bbbbbbbbbbbbbbbbbbbb|
        bbbbbbbbbbbbbbbbbbbb|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
      ]],
      })

      -- Move to very long line (wraps across multiple lines, no blame visible)
      feed('j')
      screen:expect({
        grid = [[
        short               |
        aaaaaaaaaaaaaaaaaaaa|
        aaaaa               |
        ^bbbbbbbbbbbbbbbbbbbb|
        bbbbbbbbbbbbbbbbbbbb|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
        {6:~                   }|
      ]],
      })
    end)
  end)

  describe('configuration', function()
    it('validates union-typed fields', function()
      helpers.setup_path()

      for _, case in ipairs({
        { field = 'current_line_blame_formatter', value = 1 },
        { field = 'current_line_blame_formatter_nc', value = 1 },
        { field = 'blame_formatter', value = true },
      }) do
        local result = exec_lua(function(field, value)
          local ok, err = pcall(require('hgsigns.config').build, {
            [field] = value,
          })
          return {
            ok = ok,
            err = tostring(err),
          }
        end, case.field, case.value)

        eq(false, result.ok)
        eq(true, result.err:find(case.field, 1, true) ~= nil)
      end
    end)
  end)

  describe('on_attach()', function()
    it('can prevent attaching to a buffer', function()
      setup_test_repo({ no_add = true })
      setup_hgsigns(config, true)

      edit(test_file)
      match_debug_messages({
        'attach.attach(1): Attaching (trigger=BufReadPost)',
        np('attach%.attach%(1%): User on_attach%(%) returned false'),
      })
    end)
  end)

  describe('change_base()', function()
    it('works', function()
      setup_test_repo()
      edit(test_file)

      feed('oEDIT<esc>')
      command('write')

      hg('add', test_file)
      hg('commit', '-m', 'commit on main', '-u', 'tester')

      -- Don't setup hgsigns until the repo has two commits
      setup_hgsigns(config)

      check({
        status = { head = 'default', added = 0, changed = 0, removed = 0 },
        signs = {},
      })

      command('Hgsigns change_base ~')

      check({
        status = { head = 'default', added = 1, changed = 0, removed = 0 },
        signs = { added = 1 },
      })
    end)
  end)

  local function testsuite(internal_diff)
    return function()
      before_each(function()
        config.diff_opts = {
          internal = internal_diff,
        }
        setup_test_repo()
      end)

      it('apply basic signs', function()
        setup_hgsigns(config)
        edit(test_file)
        command('set signcolumn=yes')

        feed('dd') -- Top delete
        feed('j')
        feed('o<esc>') -- Add
        feed('2j')
        feed('x') -- Change
        feed('3j')
        feed('dd') -- Delete
        feed('j')
        feed('ddx') -- Change delete

        check({
          status = { head = 'default', added = 1, changed = 2, removed = 3 },
          signs = { topdelete = 1, changedelete = 1, added = 1, delete = 1, changed = 1 },
        })
      end)

      it('can enable numhl', function()
        config.numhl = true
        setup_hgsigns(config)
        edit(test_file)
        command('set signcolumn=no')
        command('set number')

        feed('dd') -- Top delete
        feed('j')
        feed('o<esc>') -- Add
        feed('2j')
        feed('x') -- Change
        feed('3j')
        feed('dd') -- Delete
        feed('j')
        feed('ddx') -- Change delete

        -- screen:snapshot_util()
        screen:expect({
          grid = [[
          {4:  1 }is              |
          {5:  2 }a               |
          {3:  3 }                |
          {5:  4 }file            |
          {2:  5 }sed             |
          {5:  6 }for             |
          {4:  7 }testing         |
          {5:  8 }The             |
          {2:  9 }^oesn't          |
          {5: 10 }matter,         |
          {5: 11 }it              |
          {5: 12 }just            |
          {5: 13 }needs           |
          {5: 14 }to              |
          {5: 15 }be              |
          {5: 16 }static.         |
          {6:~                   }|
        ]],
        })
      end)

      it('attaches to newly created files', function()
        setup_hgsigns(config)
        edit(newfile)
        command('write')
        wait_for_attach()

        check({
          status = { head = 'default', added = 1, changed = 0, removed = 0 },
          signs = { untracked = 1 },
        })
      end)

      it('can manually attach untracked files with --force (#1026)', function()
        config.attach_to_untracked = false
        setup_hgsigns(config)

        edit(newfile)
        feed('iline<esc>')
        command('write')

        check({
          status = { head = 'default' },
          signs = {},
        })

        command('Hgsigns attach --force')

        check({
          status = { head = 'default', added = 1, changed = 0, removed = 0 },
          signs = { untracked = 1 },
        })
      end)

      it('can detach from buffers', function()
        setup_hgsigns(config)
        edit(test_file)
        command('set signcolumn=yes')

        feed('dd') -- Top delete
        feed('j')
        feed('o<esc>') -- Add
        feed('2j')
        feed('x') -- Change
        feed('3j')
        feed('dd') -- Delete
        feed('j')
        feed('ddx') -- Change delete

        check({
          status = { head = 'default', added = 1, changed = 2, removed = 3 },
          signs = { topdelete = 1, added = 1, changed = 1, delete = 1, changedelete = 1 },
        })

        command('Hgsigns detach')

        check({ status = {}, signs = {} })
      end)

      it('handle files with spaces', function()
        setup_hgsigns(config)
        command('set signcolumn=yes')

        local spacefile = scratch .. '/a b c d'

        write_to_file(spacefile, { 'spaces', 'in', 'file' })

        edit(spacefile)

        check({
          status = { head = 'default', added = 3, removed = 0, changed = 0 },
          signs = { untracked = 3 },
        })

        hg('add', spacefile)
        hg('commit', '-m', 'add spaced file', '-u', 'tester')
        edit(spacefile)

        check({
          status = { head = 'default', added = 0, removed = 0, changed = 0 },
          signs = {},
        })
      end)
    end
  end

  -- Run regular config
  describe('diff-ext', testsuite(false))

  -- Run with:
  --   - internal diff (ffi)
  --   - decoration provider
  describe('diff-int', testsuite(true))

  describe('mercurial hunks', function()
    before_each(function()
      config.diff_opts = {
        internal = true,
      }
      setup_test_hg_repo()
      setup_hgsigns(config)
    end)

    it('renders hg add files from an empty parent baseline without staged signs', function()
      write_to_file(newfile, { 'alpha', 'beta' })
      helpers.hg('add', newfile)

      edit(newfile)
      wait_for_attach()

      check({
        status = { head = 'default', added = 2, changed = 0, removed = 0 },
        signs = { added = 2 },
      })

      local result = exec_lua(function(bufnr)
        local bcache = assert(require('hgsigns.cache').cache[bufnr])
        return {
          file_state = bcache.git_obj.file_state,
          compare_text = bcache.compare_text,
          has_staged_diffs = bcache.staged_diffs ~= nil,
        }
      end, api.nvim_get_current_buf())

      eq('added', result.file_state)
      eq({ '' }, result.compare_text)
      eq(false, result.has_staged_diffs)
    end)

    it('navigates previews and resets mercurial hunks against parent content', function()
      edit(test_file)
      wait_for_attach()
      exec_lua(function()
        require('hgsigns').statuscolumn(0, 1)
      end)

      feed('ggccEDIT<esc>')
      feed('5GoADDED<esc>')
      feed('10Gdd')

      check({
        status = { head = 'default', added = 1, changed = 1, removed = 1 },
        signs = { changed = 1, added = 1, delete = 1 },
      })

      local starts = exec_lua(function()
        local hunks = assert(require('hgsigns').get_hunks())
        return vim.tbl_map(function(hunk)
          return hunk.added.start
        end, hunks)
      end)

      eq(3, #starts)

      command([[lua require('hgsigns').nav_hunk('first', { navigation_message = false })]])
      expectf(function()
        eq(math.max(starts[1], 1), api.nvim_win_get_cursor(0)[1])
      end)

      command([[lua require('hgsigns').preview_hunk()]])
      local preview_lines = exec_lua(function()
        local popup = require('hgsigns.popup')
        local winid = assert(popup.is_open('hunk'))
        local bufnr = vim.api.nvim_win_get_buf(winid)
        return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      end)
      match_lines(preview_lines, {
        n('Hunk 1 of 3'),
        n('-This'),
        n('+EDIT'),
      })

      local inline_preview = exec_lua(function()
        require('hgsigns').preview_hunk_inline()
        return vim.wait(5000, function()
          return require('hgsigns.actions.preview').has_preview_inline(0)
        end)
      end)
      eq(true, inline_preview)
      local statuscolumn = exec_lua(function()
        local lnum = vim.api.nvim_win_get_cursor(0)[1]
        return require('hgsigns').statuscolumn(0, lnum)
      end)
      assert(type(statuscolumn) == 'string', vim.inspect(statuscolumn))
      assert(#statuscolumn >= 2, statuscolumn)
      eq(nil, statuscolumn:find('HgsignsStaged', 1, true))

      command([[lua require('hgsigns').nav_hunk('next', { navigation_message = false })]])
      expectf(function()
        eq(math.max(starts[2], 1), api.nvim_win_get_cursor(0)[1])
      end)

      command([[lua require('hgsigns').reset_buffer()]])

      check({
        status = { head = 'default', added = 0, changed = 0, removed = 0 },
        signs = {},
      })
      eq('This', api.nvim_buf_get_lines(0, 0, 1, false)[1])

      local message = exec_lua(function()
        local echoed --- @type string?
        local old_echo = vim.api.nvim_echo
        vim.api.nvim_echo = function(chunks, history, opts)
          echoed = chunks[1] and chunks[1][1] or ''
          return old_echo(chunks, history, opts)
        end
        require('hgsigns').nav_hunk('next', { navigation_message = true })
        vim.api.nvim_echo = old_echo
        return echoed or ''
      end)
      assert(message:find('No hunks', 1, true), message)
    end)

    it('reports mercurial file states for unknown and removed files', function()
      local unknown = scratch .. '/unknown.txt'
      write_to_file(unknown, { 'mystery' })
      helpers.hg('remove', test_file)

      local states = exec_lua(function(unknown0, removed0)
        local async = require('hgsigns.async')
        return async
          .run(function()
            local Repo = require('hgsigns.git').Repo
            local repo = assert(Repo.get(vim.fs.dirname(unknown0), nil, nil))
            local unknown_info = assert(repo:file_info(unknown0))
            local removed_info = assert(repo:file_info(removed0))
            return {
              unknown = {
                file_state = unknown_info.file_state,
                relpath = unknown_info.relpath,
              },
              removed = {
                file_state = removed_info.file_state,
                relpath = removed_info.relpath,
              },
            }
          end)
          :wait(5000)
      end, unknown, test_file)

      eq('unknown', states.unknown.file_state)
      eq('unknown.txt', states.unknown.relpath)
      eq('removed', states.removed.file_state)
      eq('dummy.txt', states.removed.relpath)
    end)
  end)

  it('can handle vimgrep', function()
    setup_test_repo()

    write_to_file(scratch .. '/t1.txt', { 'hello ben' })
    write_to_file(scratch .. '/t2.txt', { 'hello ben' })
    write_to_file(scratch .. '/t3.txt', { 'hello lewis' })

    setup_hgsigns(config)

    helpers.exc_exec('vimgrep ben ' .. scratch .. '/*')

    -- Neovim may emit a varying number of path echoes before the stable quickfix message.
    expectf(function()
      screen:sleep(10)

      local messages = screen.messages
      local message = messages[#messages]
      local scratch_path = vim.fs.normalize((scratch:gsub('\\', '/')))
      local scratch_suffix = assert(scratch_path:match('(hgsigns%-scratch/.+)$'))

      eq('quickfix', message.kind)
      eq('(1 of 2): hello ben', message.content[1][2])

      for i = 1, #messages - 1 do
        local entry = messages[i]
        local raw = entry.content[1][2]

        if type(raw) ~= 'string' then
          goto continue
        end

        local path0 = raw:gsub('\\', '/')
        local path = vim.fs.normalize(path0)

        eq('', entry.kind)
        assert(
          path == scratch_path .. '/dummy.txt'
            or path == scratch_suffix .. '/dummy.txt'
            or vim.startswith(path, scratch_path .. '/t')
            or vim.startswith(path, scratch_suffix .. '/t'),
          ('unexpected path message: %s'):format(path)
        )

        ::continue::
      end
    end, 10)

    match_debug_messages({
      'hgsigns.attach_autocmd(2): Attaching is disabled',
      n('hgsigns.attach_autocmd(3): Attaching is disabled'),
      n('hgsigns.attach_autocmd(4): Attaching is disabled'),
      n('hgsigns.attach_autocmd(5): Attaching is disabled'),
    })
  end)

  it('handles a quick undo', function()
    setup_test_repo()
    setup_hgsigns(config)
    edit(test_file)
    -- This test isn't deterministic so run it a few times
    for _ = 1, 3 do
      feed('x')
      check({ signs = { changed = 1 } })
      feed('u')
      check({ signs = {} })
    end
  end)

  it('redraws statuscolumn signs after async updates', function()
    setup_test_repo()
    setup_hgsigns(config)
    edit(test_file)
    exec_lua(function()
      vim.wo.signcolumn = 'yes'
      vim.wo.statuscolumn = "%{%v:lua.require'hgsigns'.statuscolumn()%}"
    end)

    wait_for_attach()
    feed('x')
    check({
      status = { head = 'default', added = 0, changed = 1, removed = 0 },
      signs = { changed = 1 },
    })

    screen:expect({ any = [[{2:~}{5: }^his]] })
  end)

  it('handles filenames with unicode characters', function()
    screen:try_resize(20, 2)
    setup_test_repo()
    setup_hgsigns(config)
    local uni_filename = scratch .. '/föobær'

    write_to_file(uni_filename, { 'Lorem ipsum' })

    hg('add', uni_filename)
    hg('commit', '-m', 'another commit', '-u', 'tester')

    edit(uni_filename)

    screen:expect({
      grid = [[
      ^Lorem ipsum         |
      {6:~                   }|
    ]],
    })

    feed('x')

    if fn.has('nvim-0.11') > 0 then
      screen:expect({
        grid = [[
        {12:~ }^orem ipsum        |
        {6:~                   }|
        ]],
      })
    else
      screen:expect({
        grid = [[
        {2:~ }^orem ipsum        |
        {6:~                   }|
        ]],
      })
    end
  end)

  it('handle #521', function()
    screen:detach()
    screen:attach()
    screen:try_resize(20, 4)
    setup_test_repo()
    setup_hgsigns(config)
    edit(test_file)
    feed('dd')

    local function check_screen(unchanged)
      if fn.has('nvim-0.11') > 0 then
        -- TODO(lewis6991): ???
        screen:expect({
          grid = [[
          {11:^ }^is                |
          {1:  }a                 |
          {1:  }file              |
                              |
        ]],
          unchanged = unchanged,
        })
      else
        screen:expect({
          grid = [[
          {4:^ }^is                |
          {1:  }a                 |
          {1:  }file              |
          {1:  }used              |
        ]],
          unchanged = unchanged,
        })
      end
    end

    check_screen()

    -- Write over the text with itself. This will remove all the signs but the
    -- calculated hunks won't change.
    exec_lua(function()
      local text = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      vim.api.nvim_buf_set_lines(0, 0, -1, true, text)
    end)

    check_screen(true)
  end)

  it('shows "No newline at end of file" in preview popup', function()
    setup_test_repo({ test_file_text = { 'a' } })
    setup_hgsigns(config)
    screen:try_resize(30, 5)
    edit(test_file)
    wait_for_attach()

    -- Remove newline at end of file (`printf a >a`)
    local f = assert(io.open(test_file, 'wb'))
    f:write('a') -- Write without trailing newline
    f:close()

    command_wait_hgsigns_update('checktime')
    expectf(function()
      local hunk = exec_lua(function()
        return require('hgsigns').get_hunks()[1]
      end)
      return hunk and (hunk.added.no_nl_at_eof or hunk.removed.no_nl_at_eof)
    end)
    feed('mhp')
    screen:expect({ any = [[\ No newline at end of file]] })
  end)
end)

describe('hgsigns attach', function()
  local config --- @type table

  before_each(function()
    clear()
    refresh_paths()
    config = vim.deepcopy(test_config)
    helpers.chdir_tmp()
  end)

  after_each(function()
    cleanup()
  end)

  --- @param bufnr integer
  --- @param ctx Hgsigns.GitContext
  local function attach_with_context(bufnr, ctx)
    exec_lua(function(bufnr0, ctx0)
      local async = require('hgsigns.async')
      async
        .run(require('hgsigns.attach').attach, {
          bufnr = bufnr0,
          ctx = ctx0,
          trigger = 'test',
        })
        :wait(5000)
    end, bufnr, ctx)
    wait_for_attach(bufnr)
  end

  it('handle #888', function()
    setup_test_repo()

    local path1 = scratch .. '/cargo.toml'
    local subdir = scratch .. '/subdir'
    local path2 = subdir .. '/cargo.toml'

    write_to_file(path1, { 'some text' })
    hg('add', path1)
    hg('commit', '-m', 'add cargo', '-u', 'tester')

    -- move file and record the move
    helpers.mkdir(subdir)
    hg('mv', path1, path2)

    config.base = '.'
    setup_hgsigns(config)
    edit(path1)
    wait_for_attach()
    command('write')
    expectf(function()
      return exec_lua(function()
        local bufnr = vim.api.nvim_get_current_buf()
        local cache = require('hgsigns.cache').cache[bufnr]
        return cache ~= nil and cache.git_obj.file == vim.api.nvim_buf_get_name(bufnr)
      end)
    end)
  end)

  it('attaches to a tracked file in a subdirectory', function()
    helpers.hg_init_scratch()

    local relpath = 'sub/test.txt'
    local file = scratch .. '/' .. relpath

    write_to_file(file, { 'hello', 'world' })
    hg('add', file)
    hg('commit', '-m', 'add nested file', '-u', 'tester')

    setup_hgsigns(config)
    edit(file)
    wait_for_attach()

    local result = exec_lua(function(bufnr)
      local cache = assert(require('hgsigns.cache').cache[bufnr])
      return {
        relpath = cache.git_obj.relpath,
        object_name = cache.git_obj.object_name or '',
        toplevel = cache.git_obj.repo.toplevel,
      }
    end, api.nvim_get_current_buf())

    eq(relpath, result.relpath)
    eq(false, result.object_name == '')
    eq_path(scratch, result.toplevel)
  end)

  it('can run diffthis/show when cwd is a subdir of a hg repo (#1277)', function()
    helpers.hg_init_scratch()
    local file = scratch .. '/sub/test'
    write_to_file(file, { 'hello' })
    hg('add', file)
    hg('commit', '-m', 'commit 1', '-u', 'tester')
    command('cd ' .. vim.fs.dirname(file))

    setup_hgsigns(config)

    edit('test')
    wait_for_attach()

    command('Hgsigns show')

    local show_bufnr --- @type integer?
    expectf(function()
      show_bufnr = exec_lua(function()
        local bufnr = vim.api.nvim_get_current_buf()
        if not vim.api.nvim_buf_get_name(bufnr):match('^hgsigns://') then
          return
        end
        return bufnr
      end)
      return show_bufnr ~= nil
    end)
    wait_for_attach(show_bufnr)

    local gfile, toplevel, gitdir, abbrev_head = exec_lua(function()
      local git_obj = assert(require('hgsigns.cache').cache[1]).git_obj
      return git_obj.file, git_obj.repo.toplevel, git_obj.repo.gitdir, git_obj.repo.abbrev_head
    end)

    eq(('hgsigns://%s//:0:sub/test'):format(gitdir), api.nvim_buf_get_name(0))

    eq_path(file, gfile)
    eq_path(scratch, toplevel)
    eq_path(scratch .. '/.hg', gitdir)
    eq('default', abbrev_head)
  end)

  it('does not error after hg system callbacks (#1425)', function()
    setup_test_repo()
    setup_hgsigns(config)

    edit(test_file)
    wait_for_attach()

    local ok = exec_lua(function()
      local async = require('hgsigns.async')
      local hg_cmd = require('hgsigns.git.cmd')

      return async
        .run(function()
          -- `hg_cmd()` ultimately uses `vim.system`, whose on_exit callback runs
          -- in fast event context. Ensure we yield to the scheduler after the
          -- command completes so Neovim API calls here don't raise E5560.
          hg_cmd({ '--version' }, { text = true })

          local b = vim.api.nvim_create_buf(false, true)
          vim.bo[b].buftype = 'nofile'
          vim.api.nvim_buf_delete(b, { force = true })
          return true
        end)
        :wait()
    end)

    eq(true, ok)
  end)
end)
