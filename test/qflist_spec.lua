local helpers = require('test.gs_helpers')

local clear = helpers.clear
local cleanup = helpers.cleanup
local command = helpers.api.nvim_command
local eq = helpers.eq
local eq_path = helpers.eq_path
local exec_lua = helpers.exec_lua
local hg = helpers.hg
local scratch = helpers.scratch
local setup_hgsigns = helpers.setup_hgsigns
local setup_test_hg_repo = helpers.setup_test_hg_repo
local test_config = helpers.test_config
local test_file = helpers.test_file
local write_to_file = helpers.write_to_file

helpers.env()

local function qflist_snapshot()
  return exec_lua(function()
    local items0 = vim.fn.getqflist()
    local names0 = {} --- @type string[]
    local texts0 = {} --- @type string[]
    for i, item in ipairs(items0) do
      names0[i] = item.filename or vim.api.nvim_buf_get_name(item.bufnr)
      texts0[i] = item.text
    end
    return items0, names0, texts0
  end) --- @type vim.quickfix.entry[], string[], string[]
end

describe('qflist (mercurial)', function()
  before_each(function()
    clear()
    helpers.chdir_tmp()
  end)

  after_each(function()
    cleanup()
  end)

  it('diffs renamed hg files against their source path when using a base revision', function()
    helpers.hg_init_scratch()

    local old_name = scratch .. '/old name.txt'
    local new_name = scratch .. '/new name.txt'

    write_to_file(old_name, { 'one', 'two' })
    hg('add', old_name)
    hg('commit', '-m', 'init commit', '-u', 'tester')

    command('cd ' .. scratch)
    setup_hgsigns(vim.tbl_extend('force', test_config, { base = '0' }))

    hg('mv', old_name, new_name)
    exec_lua(function(path)
      local lines = vim.fn.readfile(path)
      lines[2] = 'renamed and edited'
      vim.fn.writefile(lines, path)
    end, new_name)

    exec_lua(function()
      require('hgsigns.actions').setqflist('all', { open = false })
    end)

    helpers.expectf(function()
      local items, names, texts = qflist_snapshot()

      eq(1, #items)
      eq_path(new_name, names[1])
      eq(true, texts[1]:match('^Changed') ~= nil)
    end)
  end)

  it('enumerates mercurial hunks for one or many changed files', function()
    helpers.hg_init_scratch()

    local file2 = scratch .. '/second.txt'
    write_to_file(test_file, { 'alpha', 'beta' })
    write_to_file(file2, { 'one', 'two' })
    hg('add', test_file, file2)
    hg('commit', '-m', 'init commit', '-u', 'tester')

    command('cd ' .. scratch)
    setup_hgsigns(test_config)

    exec_lua(function(path1, path2)
      local lines1 = vim.fn.readfile(path1)
      lines1[1] = 'alpha changed'
      vim.fn.writefile(lines1, path1)

      local lines2 = vim.fn.readfile(path2)
      lines2[2] = 'two changed'
      vim.fn.writefile(lines2, path2)
    end, test_file, file2)

    exec_lua(function()
      require('hgsigns.actions').setqflist('all', { open = false })
    end)

    helpers.expectf(function()
      local items, names, texts = qflist_snapshot()

      eq(2, #items)
      eq_path(test_file, names[1])
      eq_path(file2, names[2])
      eq(true, texts[1]:match('^Changed') ~= nil)
      eq(true, texts[2]:match('^Changed') ~= nil)
    end)
  end)

  it('returns an empty qflist for a clean hg repo', function()
    setup_test_hg_repo()
    command('cd ' .. scratch)
    setup_hgsigns(test_config)

    exec_lua(function()
      require('hgsigns.actions').setqflist('all', { open = false })
    end)

    helpers.expectf(function()
      local items = exec_lua(function()
        return vim.fn.getqflist()
      end)
      eq(0, #items)
    end)
  end)

  it('skips removed hg files that no longer exist on disk', function()
    setup_test_hg_repo()
    command('cd ' .. scratch)
    setup_hgsigns(test_config)

    hg('remove', test_file)

    exec_lua(function()
      require('hgsigns.actions').setqflist('all', { open = false })
    end)

    helpers.expectf(function()
      local items = exec_lua(function()
        return vim.fn.getqflist()
      end)
      eq(0, #items)
    end)
  end)
end)
