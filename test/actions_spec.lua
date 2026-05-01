local helpers = require('test.gs_helpers')

local setup_hgsigns = helpers.setup_hgsigns
local feed = helpers.feed
local test_file = helpers.test_file
local edit = helpers.edit
local check = helpers.check
local exec_lua = helpers.exec_lua
local api = helpers.api
local test_config = helpers.test_config
local clear = helpers.clear
local setup_test_repo = helpers.setup_test_repo
local setup_test_hg_repo = helpers.setup_test_hg_repo
local eq = helpers.eq
local expectf = helpers.expectf
local hg = helpers.hg
local scratch = helpers.scratch
local write_to_file = helpers.write_to_file

helpers.env()

--- @param exp_hunks string[]
local function expect_hunks(exp_hunks)
  expectf(function()
    --- @type table[]
    local hunks = exec_lua("return require('hgsigns').get_hunks()")
    if #exp_hunks ~= #hunks then
      local msg = {} --- @type string[]
      msg[#msg + 1] = ''
      msg[#msg + 1] = string.format(
        'Number of hunks do not match. Expected: %d, passed in: %d',
        #exp_hunks,
        #hunks
      )

      msg[#msg + 1] = '\nExpected hunks:'
      for _, h in ipairs(exp_hunks) do
        msg[#msg + 1] = h
      end

      msg[#msg + 1] = '\nPassed in hunks:'
      for _, h in ipairs(hunks) do
        msg[#msg + 1] = h.head
      end

      error(table.concat(msg, '\n'))
    end

    for i, hunk in ipairs(hunks) do
      eq(exp_hunks[i], hunk.head)
    end
  end)
end

local delay = 1

--- @param cmd string
local function command(cmd)
  api.nvim_command(cmd)

  -- Flaky tests, add a large delay between commands.
  -- Flakiness is due to actions being async and problems occur when an action
  -- is run while another action or update is running.
  -- Must wait for actions and updates to finish.
  if delay > 0 then
    helpers.sleep(delay)
  end
end

local function complete(arglead, line)
  return exec_lua(function(arglead0, line0)
    return require('hgsigns.cli').complete(arglead0, line0)
  end, arglead, line)
end

local function retry(f)
  local orig_delay = delay
  local ok, err --- @type boolean, string?

  for _ = 1, 20 do
    --- @type boolean, string?
    ok, err = pcall(f)
    if ok then
      delay = orig_delay
      return
    end
    delay = math.ceil(delay * 1.6)
    print('failed, retrying with delay', delay)
  end

  delay = orig_delay
  if err then
    error(err)
  end
end

describe('actions', function()
  local orig_it = it
  local function it(desc, f)
    orig_it(desc, function()
      retry(f)
    end)
  end

  before_each(function()
    clear()
    helpers.chdir_tmp()
    setup_hgsigns(test_config)
  end)

  it('show_commit does not include ansi color codes', function()
    setup_test_repo()
    edit(test_file)
    check({
      status = { head = 'main', added = 0, changed = 0, removed = 0 },
      signs = {},
    })

    local lines = exec_lua(function()
      local async = require('hgsigns.async')
      local commit_buf = async
        .run(function()
          return require('hgsigns.actions.show_commit')('main', 'edit')
        end)
        :wait(1000)

      return vim.api.nvim_buf_get_lines(commit_buf, 0, -1, false)
    end)

    for _, line in ipairs(lines) do
      assert(not line:find('\27', 1, true), ('unexpected ANSI escape in line: %q'):format(line))
    end
  end)

  it('completes action command arguments', function()
    eq({ '--bufnr=', '--force', '--trigger=' }, complete('', 'Hgsigns attach '))
    eq({ '--ignore_whitespace' }, complete('', 'Hgsigns blame '))
    eq({ '--full', '--ignore_whitespace' }, complete('', 'Hgsigns blame_line '))
    eq({ '--force' }, complete('--f', 'Hgsigns attach --f'))
    eq({ '--force=true', '--force=false' }, complete('--force=', 'Hgsigns attach --force='))
    eq({ '--trigger=' }, complete('--t', 'Hgsigns attach --t'))
    eq({ '--force' }, complete('--f', 'vertical Gitsigns attach --f'))

    eq({ 'true', 'false', '--global' }, complete('', 'Hgsigns change_base main '))
    eq(
      { '--global=true', '--global=false' },
      complete('--global=', 'Hgsigns change_base main --global=')
    )
    eq({ '--split=', '--vertical' }, complete('--', 'Hgsigns diffthis --'))
    eq(
      { '--vertical=true', '--vertical=false' },
      complete('--vertical=', 'Hgsigns diffthis --vertical=')
    )
    eq({
      '--split=aboveleft',
      '--split=belowright',
      '--split=topleft',
      '--split=botright',
    }, complete('--split=', 'Hgsigns diffthis --split='))
    eq({ 'vsplit', 'tabnew' }, complete('', 'Hgsigns show_commit main '))
    eq({ 'next' }, complete('n', 'Hgsigns nav_hunk n'))
    eq(
      { '--target=unstaged', '--target=staged', '--target=all' },
      complete('--target=', 'Hgsigns next_hunk --target=')
    )
    eq({ '--full' }, complete('--f', 'Hgsigns blame_line --f'))
    eq({ '--full=true', '--full=false' }, complete('--full=', 'Hgsigns blame_line --full='))
    eq({ '--open' }, complete('--o', 'Hgsigns setqflist attached --o'))
    eq(
      { '--open=true', '--open=false' },
      complete('--open=', 'Hgsigns setqflist attached --open=')
    )
    eq({}, complete('', 'Hgsigns stage_hunk '))
    eq({}, complete('--g', 'Hgsigns reset_hunk --g'))
    eq({ 'attached', 'all' }, complete('', 'Hgsigns setloclist 0 '))
    eq({ 'true', 'false', 'nil' }, complete('', 'Hgsigns toggle_signs '))
  end)

  it('parses named flag assignments', function()
    local result = exec_lua(function()
      local parse_args = require('hgsigns.cli.argparse').parse_args
      local _, named = parse_args('attach --force=true --trigger=git=hook --bufnr=5 key=va=lue')
      local _, extra = parse_args('blame --extra_opts=--ignore-revs-file=.git-blame-ignore-revs')

      return {
        force = named.force,
        trigger = named.trigger,
        bufnr = named.bufnr,
        key = named.key,
        extra_opts = extra.extra_opts,
      }
    end)

    eq('true', result.force)
    eq('git=hook', result.trigger)
    eq('5', result.bufnr)
    eq('va=lue', result.key)
    eq('--ignore-revs-file=.git-blame-ignore-revs', result.extra_opts)
  end)

  it('runs actions with named flags', function()
    local result = exec_lua(function()
      local actions = require('hgsigns.actions')
      local cli = require('hgsigns.cli')

      local saved = {
        attach = actions.attach,
        blame = actions.blame,
        change_base = actions.change_base,
        diffthis = actions.diffthis,
        nav_hunk = actions.nav_hunk,
        setqflist = actions.setqflist,
      }

      local ret = {}

      actions.attach = function(opts)
        ret.attach = {
          bufnr = opts.bufnr,
          force = opts.force,
          trigger = opts.trigger,
        }
      end

      actions.blame = function(opts)
        ret.blame = {
          ignore_whitespace = opts.ignore_whitespace,
        }
      end

      actions.change_base = function(base, global)
        ret.change_base = { base = base, global = global }
      end

      actions.diffthis = function(base, opts)
        ret.diffthis = {
          base = base,
          split = opts.split,
          vertical = opts.vertical,
        }
      end

      actions.nav_hunk = function(direction, opts)
        ret.nav_hunk = {
          count = opts.count,
          direction = direction,
          preview = opts.preview,
          target = opts.target,
        }
      end

      actions.setqflist = function(target, opts)
        ret.setqflist = {
          nr = opts.nr,
          open = opts.open,
          target = target,
        }
      end

      local ok, err = pcall(function()
        cli.run({ args = 'attach --bufnr=5 --force=true --trigger=command', range = 0, smods = {} })
        cli.run({ args = 'blame --ignore_whitespace=true', range = 0, smods = {} })
        cli.run({ args = 'change_base HEAD~2 --global=true', range = 0, smods = {} })
        cli.run({
          args = 'diffthis HEAD~1 --vertical=true --split=aboveleft',
          range = 0,
          smods = {},
        })
        cli.run({ args = 'next_hunk --target=all --preview=false --count=2', range = 0, smods = {} })
        cli.run({ args = 'setqflist attached --open=false --nr=4', range = 0, smods = {} })
      end)

      actions.attach = saved.attach
      actions.blame = saved.blame
      actions.change_base = saved.change_base
      actions.diffthis = saved.diffthis
      actions.nav_hunk = saved.nav_hunk
      actions.setqflist = saved.setqflist

      if not ok then
        error(err)
      end

      return ret
    end)

    eq(5, result.attach.bufnr)
    eq(true, result.attach.force)
    eq('command', result.attach.trigger)

    eq(true, result.blame.ignore_whitespace)

    eq('HEAD~2', result.change_base.base)
    eq(true, result.change_base.global)

    eq('HEAD~1', result.diffthis.base)
    eq(true, result.diffthis.vertical)
    eq('aboveleft', result.diffthis.split)

    eq(2, result.nav_hunk.count)
    eq('next', result.nav_hunk.direction)
    eq(false, result.nav_hunk.preview)
    eq('all', result.nav_hunk.target)

    eq('attached', result.setqflist.target)
    eq(false, result.setqflist.open)
    eq(4, result.setqflist.nr)
  end)

  it('does not emit duplicate GitSignsUpdate events for stage_hunk', function()
    setup_test_repo()
    edit(test_file)

    feed('jjjccEDIT<esc>')
    check({
      status = { head = 'main', added = 0, changed = 1, removed = 0 },
      signs = { changed = 1 },
    })

    exec_lua(function()
      _G.test_hgsigns_update_events = {}

      vim.api.nvim_create_autocmd('User', {
        group = vim.api.nvim_create_augroup('GitsignsUpdateTest', { clear = true }),
        pattern = 'HgsignsUpdate',
        callback = function(args)
          local bufnr = args.data and args.data.buffer
          if bufnr ~= vim.api.nvim_get_current_buf() then
            return
          end

          local status = vim.b[bufnr].hgsigns_status_dict
          _G.test_hgsigns_update_events[#_G.test_hgsigns_update_events + 1] = {
            added = status and status.added,
            changed = status and status.changed,
            removed = status and status.removed,
            head = status and status.head,
          }
        end,
      })
    end)

    eq('.~', result.hg_tilde)
    eq('.^', result.hg_parent)
    eq('.~1', result.hg_prev)
    eq('.~1', result.hg_explicit)
    eq('HEAD~1', result.git_prev)
  end)

  it(
    'show_commit renders mercurial metadata and git-style patch headers for relative revisions',
    function()
      setup_test_hg_repo()
      write_to_file(test_file, { 'This', 'IS', 'a', 'file' })
      hg('commit', '-A', '-m', 'second commit', '-u', 'tester')

      edit(test_file)
      check({
        status = { head = 'default', added = 0, changed = 0, removed = 0 },
        signs = {},
      })

      local result = exec_lua(function()
        local async = require('hgsigns.async')
        local commit_buf = async
          .run(function()
            return require('hgsigns.actions.show_commit')('.~1', 'edit')
          end)
          :wait(2000)

        return {
          name = vim.api.nvim_buf_get_name(commit_buf),
          lines = vim.api.nvim_buf_get_lines(commit_buf, 0, -1, false),
        }
      end)

      eq(true, result.name:find('^hgsigns://', 1) ~= nil)
      eq(true, result.lines[1]:match('^commit %x+$') ~= nil)
      eq(true, vim.tbl_contains(result.lines, 'summary init commit'))
      eq(true, vim.tbl_contains(result.lines, 'diff --git a/dummy.txt b/dummy.txt'))
      eq(true, vim.tbl_contains(result.lines, '--- /dev/null'))
      eq(true, vim.tbl_contains(result.lines, '+++ b/dummy.txt'))

      for _, line in ipairs(result.lines) do
        assert(not line:find('\27', 1, true), ('unexpected ANSI escape in line: %q'):format(line))
      end
    end
  )

  it(
    'diffthis accepts mercurial relative revisions for nested files from a subdirectory cwd',
    function()
      helpers.hg_init_scratch()

      local relpath = 'sub/dir/dummy.txt'
      local file = scratch .. '/' .. relpath
      write_to_file(file, { 'one', 'two', 'three' })
      hg('add', file)
      hg('commit', '-m', 'init commit', '-u', 'tester')
      write_to_file(file, { 'one', 'TWO', 'three' })
      hg('commit', '-m', 'second commit', '-u', 'tester', file)

      helpers.api.nvim_command('cd ' .. helpers.fn.fnameescape(scratch .. '/sub'))
      edit(file)
      check({
        status = { head = 'default', added = 0, changed = 0, removed = 0 },
        signs = {},
      })

      exec_lua(function()
        local async = require('hgsigns.async')
        async.run(require('hgsigns.actions.diffthis').diffthis, '.~1', {}):wait(2000)
      end)

      eq(
        true,
        exec_lua(function()
          return vim.wait(5000, function()
            for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
              local buf = vim.api.nvim_win_get_buf(win)
              if vim.wo[win].diff and vim.api.nvim_buf_get_name(buf):find('^hgsigns://', 1) then
                return true
              end
            end
            return false
          end)
        end)
      )

      local result = exec_lua(function()
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          local buf = vim.api.nvim_win_get_buf(win)
          local name = vim.api.nvim_buf_get_name(buf)
          if vim.wo[win].diff and name:find('^hgsigns://', 1) then
            return {
              name = name,
              line = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1],
              diff = vim.wo[win].diff,
            }
          end
        end
      end)

      eq(true, type(result) == 'table')
      eq(true, result.name:find('//.~1:sub/dir/dummy.txt', 1, true) ~= nil)
      eq(true, result.diff)
      eq('two', result.line)
    end
  )

  it('preserves foldenable in diffthis windows after a hunk reset', function()
    command('silent! %bwipe!')
    setup_test_repo()
    edit(test_file)

    feed('jjjccEDIT<esc>')
    check({
      status = { head = 'main', added = 0, changed = 1, removed = 0 },
      signs = { changed = 1 },
    })

    exec_lua(function()
      local async = require('hgsigns.async')
      async.run(require('hgsigns.actions.diffthis').diffthis, nil, {}):wait(1000)
    end)

    local rev_win --- @type integer?
    expectf(function()
      eq(2, #api.nvim_list_wins())
      local current = api.nvim_get_current_win()
      for _, win in ipairs(api.nvim_list_wins()) do
        if win ~= current then
          local buf = api.nvim_win_get_buf(win)
          if api.nvim_buf_get_name(buf):find('^hgsigns://') then
            rev_win = win
            break
          end
        end
      end
      eq(true, type(rev_win) == 'number' and rev_win > 0)
    end)
    assert(rev_win)

    api.nvim_set_option_value('foldenable', false, { scope = 'local', win = rev_win })

    command('Hgsigns reset_hunk')

    check({
      status = { head = 'main', added = 0, changed = 0, removed = 0 },
      signs = {},
    })

    expectf(function()
      eq(true, api.nvim_win_is_valid(rev_win))
      eq(false, api.nvim_get_option_value('foldenable', { scope = 'local', win = rev_win }))
    end)
  end)

  local function check_cursor(pos)
    eq(pos, api.nvim_win_get_cursor(0))
  end

  it('can navigate hunks', function()
    setup_test_repo()
    edit(test_file)

    feed('dd')
    feed('4Gx')
    feed('6Gx')

    expect_hunks({
      '@@ -1,1 +0 @@',
      '@@ -5,1 +4,1 @@',
      '@@ -7,1 +6,1 @@',
    })

    check_cursor({ 6, 0 })
    command('Hgsigns next_hunk') -- Wrap
    check_cursor({ 1, 0 })
    command('Hgsigns next_hunk')
    check_cursor({ 4, 0 })
    command('Hgsigns next_hunk')
    check_cursor({ 6, 0 })

    command('Hgsigns prev_hunk')
    check_cursor({ 4, 0 })
    command('Hgsigns prev_hunk')
    check_cursor({ 1, 0 })
    command('Hgsigns prev_hunk') -- Wrap
    check_cursor({ 6, 0 })
  end)

  it('can navigate hunks (nowrap)', function()
    setup_test_repo()
    edit(test_file)

    feed('4Gx')
    feed('6Gx')
    feed('gg')

    expect_hunks({
      '@@ -4,1 +4,1 @@',
      '@@ -6,1 +6,1 @@',
    })

    command('set nowrapscan')

    check_cursor({ 1, 0 })
    command('Hgsigns next_hunk')
    check_cursor({ 4, 0 })
    command('Hgsigns next_hunk')
    check_cursor({ 6, 0 })
    command('Hgsigns next_hunk')
    check_cursor({ 6, 0 })

    feed('G')
    check_cursor({ 18, 0 })
    command('Hgsigns prev_hunk')
    check_cursor({ 6, 0 })
    command('Hgsigns prev_hunk')
    check_cursor({ 4, 0 })
    command('Hgsigns prev_hunk')
    check_cursor({ 4, 0 })
  end)

  it('can navigate EOF delete hunks', function()
    setup_test_repo()
    edit(test_file)

    check({
      status = { head = 'main', added = 0, changed = 0, removed = 0 },
      signs = {},
    })

    local line_count = exec_lua(function()
      local Hunks = require('hgsigns.hunks')
      local bufnr = vim.api.nvim_get_current_buf()
      local cache = assert(require('hgsigns.cache').cache[bufnr])
      local line_count0 = vim.api.nvim_buf_line_count(bufnr)

      cache.hunks = {
        Hunks.create_hunk(4, 1, 4, 1),
        Hunks.create_hunk(line_count0, 1, line_count0 + 1, 0),
      }

      return line_count0
    end)

    feed('gg')
    command('Hgsigns next_hunk')
    check_cursor({ 4, 0 })

    command('Hgsigns next_hunk')
    check_cursor({ line_count, 0 })

    eq(
      true,
      exec_lua(function()
        local bufnr = vim.api.nvim_get_current_buf()
        local bcache = assert(require('hgsigns.cache').cache[bufnr])
        local hunk, index = bcache:get_cursor_hunk()

        return hunk ~= nil
          and index == 2
          and hunk.type == 'delete'
          and hunk.added.start == vim.api.nvim_buf_line_count(bufnr) + 1
      end)
    )

    eq(
      'Hunk 2 of 2',
      exec_lua(function()
        require('hgsigns').preview_hunk()

        local popup = require('hgsigns.popup')
        local win = assert(popup.is_open('hunk'))
        local title =
          assert(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, 1, false)[1])

        popup.close('hunk')

        return title
      end)
    )

    command('Hgsigns next_hunk') -- Wrap
    check_cursor({ 4, 0 })

    command('set nowrapscan')
    api.nvim_win_set_cursor(0, { 4, 0 })

    command('Hgsigns next_hunk --count=2')
    check_cursor({ line_count, 0 })
  end)
end)
