local helpers = require('test.gs_helpers')

local eq = helpers.eq
local expectf = helpers.expectf
local debug_messages = helpers.debug_messages

helpers.env()

describe('git locale', function()
  before_each(function()
    helpers.clear()
    helpers.setup_path()
    helpers.chdir_tmp()
  end)

  after_each(function()
    helpers.cleanup()
  end)

  it('attaches in fresh hg repos with normalized mercurial commands', function()
    helpers.setup_test_hg_repo({ no_add = true })

    helpers.exec_lua(function()
      package.loaded['hgsigns.git.cmd'] = nil
      local orig_git_cmd = require('hgsigns.git.cmd')

      _G.hgsigns_git_envs = {}

      package.loaded['hgsigns.git.cmd'] = function(args, spec)
        spec = spec or {}

        local stdout, stderr, code = orig_git_cmd(args, spec)

        _G.hgsigns_git_envs[#_G.hgsigns_git_envs + 1] = {
          args = vim.deepcopy(args),
          env = vim.deepcopy(spec.env or {}),
          vcs = spec.vcs or 'git',
        }

        return stdout, stderr, code
      end

      package.loaded['hgsigns.git.repo'] = nil
      package.loaded['hgsigns.git'] = nil

      vim.env.LANG = 'zh_CN.UTF-8'
      vim.env.LC_ALL = 'zh_CN.UTF-8'
      vim.env.LC_MESSAGES = nil
      vim.env.LANGUAGE = nil
    end)

    local config = vim.deepcopy(helpers.test_config)
    config.watch_gitdir = { interval = 100 }
    helpers.setup_hgsigns(config)

    helpers.edit(helpers.test_file)

    helpers.check({
      status = { head = 'default', added = 18, changed = 0, removed = 0 },
    })

    expectf(function()
      return helpers.exec_lua(function()
        return _G.hgsigns_git_envs ~= nil and #_G.hgsigns_git_envs > 0
      end)
    end)

    local envs = helpers.exec_lua(function()
      return _G.hgsigns_git_envs
    end)

    local saw_hg = false
    for _, item in ipairs(envs) do
      if item.vcs == 'hg' then
        saw_hg = true
        eq('1', item.env.HGPLAIN)
        eq('C', item.env.LC_ALL)
        eq('C', item.env.LANGUAGE)
      end
    end
    eq(true, saw_hg)

    local completion_result = helpers.exec_lua(function()
      local before = #_G.hgsigns_git_envs
      local complete = require('hgsigns.actions')._get_cmp_func('show_commit')
      local items = complete('.')
      local calls = {}
      for i = before + 1, #_G.hgsigns_git_envs do
        calls[#calls + 1] = _G.hgsigns_git_envs[i]
      end
      return {
        items = items,
        calls = calls,
      }
    end)

    local saw_completion_hg = false
    local saw_completion_git = false
    for _, item in ipairs(completion_result.calls) do
      if item.vcs == 'hg' then
        saw_completion_hg = true
        eq('1', item.env.HGPLAIN)
        eq('C', item.env.LC_ALL)
        eq('C', item.env.LANGUAGE)
      elseif item.vcs == 'git' then
        saw_completion_git = true
      end
    end

    eq(true, saw_completion_hg)
    eq(false, saw_completion_git)
    eq(true, vim.tbl_contains(completion_result.items, '.'))

    local saw_hg_config = false
    for _, line in ipairs(debug_messages()) do
      if line:find('system.system: hg %-%-config ui%.relative%-paths=false ', 1) then
        saw_hg_config = true
      end
    end
    eq(true, saw_hg_config)
  end)
end)
