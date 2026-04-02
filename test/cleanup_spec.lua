local helpers = require('test.gs_helpers')

local clear = helpers.clear
local edit = helpers.edit
local eq = helpers.eq
local exec_lua = helpers.exec_lua
local expectf = helpers.expectf
local setup_hgsigns = helpers.setup_hgsigns
local setup_test_hg_repo = helpers.setup_test_hg_repo
local test_config = helpers.test_config
local test_file = helpers.test_file

helpers.env()

describe('cleanup', function()
  before_each(function()
    clear()
    helpers.chdir_tmp()
  end)

  it('removes staging actions from the public entrypoint and command adapters', function()
    setup_hgsigns(test_config)

    local result = exec_lua(function()
      local hgsigns = require('hgsigns')
      local actions = require('hgsigns.actions')

      return {
        has_stage_hunk = hgsigns.stage_hunk ~= nil,
        has_undo_stage_hunk = hgsigns.undo_stage_hunk ~= nil,
        has_stage_buffer = hgsigns.stage_buffer ~= nil,
        has_reset_buffer_index = hgsigns.reset_buffer_index ~= nil,
        has_cmd_stage_hunk = actions._get_cmd_func('stage_hunk') ~= nil,
        has_cmd_stage_buffer = actions._get_cmd_func('stage_buffer') ~= nil,
      }
    end)

    eq(false, result.has_stage_hunk)
    eq(false, result.has_undo_stage_hunk)
    eq(false, result.has_stage_buffer)
    eq(false, result.has_reset_buffer_index)
    eq(false, result.has_cmd_stage_hunk)
    eq(false, result.has_cmd_stage_buffer)
  end)

  it('warns for removed config keys and does not populate config', function()
    local config = vim.deepcopy(test_config)
    config.signs_staged = { add = { text = '!' } }
    config.signs_staged_enable = false
    config.worktrees = { { toplevel = '/tmp/example', gitdir = '/tmp/example/.git' } }
    config.gh = true

    helpers.setup_path()
    exec_lua(function(config0)
      local maps = config0.on_attach --[[@as [string,string,string][] ]]
      config0.on_attach = function(bufnr)
        for _, map in ipairs(maps) do
          vim.keymap.set(map[1], map[2], map[3], { buffer = bufnr })
        end
      end
      config0._on_attach_pre = function(_, callback)
        callback({})
      end

      require('hgsigns').setup(config0)
      vim.o.diffopt = 'internal,filler,closeoff'
    end, config)

    local result = exec_lua(function()
      return {
        messages = vim.api.nvim_exec2('messages', { output = true }).output,
        signs_staged = require('hgsigns.config').config.signs_staged,
        signs_staged_enable = require('hgsigns.config').config.signs_staged_enable,
        worktrees = require('hgsigns.config').config.worktrees,
        on_attach_pre = require('hgsigns.config').config._on_attach_pre,
        gh = require('hgsigns.config').config.gh,
      }
    end)

    eq(nil, result.signs_staged)
    eq(nil, result.signs_staged_enable)
    eq(nil, result.worktrees)
    eq(nil, result.on_attach_pre)
    eq(nil, result.gh)

    for _, key in ipairs({
      'signs_staged',
      'signs_staged_enable',
      'worktrees',
      '_on_attach_pre',
      'gh',
    }) do
      assert(
        result.messages:find(("Ignoring invalid configuration field '%s'"):format(key), 1, true),
        result.messages
      )
    end
  end)

  it('fails removed command actions at dispatch time', function()
    setup_test_hg_repo()
    setup_hgsigns(test_config)
    edit(test_file)

    exec_lua(function()
      vim.cmd('Hgsigns stage_hunk')
      vim.cmd('Hgsigns stage_buffer')
    end)

    local messages = exec_lua(function()
      return vim.api.nvim_exec2('messages', { output = true }).output
    end)

    assert(messages:find('stage_hunk is not a valid function or action', 1, true), messages)
    assert(messages:find('stage_buffer is not a valid function or action', 1, true), messages)
  end)

  it('renders mercurial blame without requiring hgsigns.gh', function()
    local config = vim.deepcopy(test_config)
    config.gh = true

    setup_test_hg_repo()
    setup_hgsigns(config)
    edit(test_file)

    expectf(function()
      return exec_lua(function()
        return vim.b.hgsigns_status_dict.gitdir ~= nil
      end)
    end)

    exec_lua(function()
      package.loaded['hgsigns.gh'] = nil
      package.preload['hgsigns.gh'] = function()
        error('cleanup_spec: hgsigns.gh should not be required')
      end

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

    local popup_text = table.concat(
      exec_lua(function()
        local popup = require('hgsigns.popup')
        local winid = assert(popup.is_open('blame'))
        local bufnr = vim.api.nvim_win_get_buf(winid)
        return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      end),
      '\n'
    )

    assert(
      popup_text:find('tester', 1, true) ~= nil
        or popup_text:find('Not Committed Yet', 1, true) ~= nil,
      popup_text
    )
    assert(
      popup_text:find('Hunk 1 of 1', 1, true) ~= nil
        or popup_text:find('File added in commit', 1, true) ~= nil,
      popup_text
    )
  end)

  it('does not expose staged-only fields in cache debug dumps', function()
    setup_test_hg_repo()
    setup_hgsigns(test_config)
    edit(test_file)

    expectf(function()
      return exec_lua(function()
        return vim.b.hgsigns_status_dict.gitdir ~= nil
      end)
    end)

    expectf(function()
      return exec_lua(function()
        local bcache = require('hgsigns.cache').cache[vim.api.nvim_get_current_buf()]
        return bcache and bcache.compare_text ~= nil and bcache.hunks ~= nil
      end)
    end)

    local dump = exec_lua(function()
      local echoed --- @type string?
      local old_echo = vim.api.nvim_echo
      vim.api.nvim_echo = function(chunks, history, opts)
        echoed = chunks[1] and chunks[1][1] or ''
        return old_echo(chunks, history, opts)
      end
      require('hgsigns').dump_cache()
      vim.api.nvim_echo = old_echo
      return echoed or ''
    end)

    assert(dump:find('compare_text', 1, true), dump)
    assert(dump:find('hunks', 1, true), dump)
    eq(nil, dump:find('compare_text_head', 1, true))
    eq(nil, dump:find('hunks_staged', 1, true))
    eq(nil, dump:find('staged_diffs', 1, true))
  end)
end)
