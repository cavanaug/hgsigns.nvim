local _MODREV, _SPECREV = 'scm', '-1'

rockspec_format = "3.0"
package = 'hgsigns.nvim'
version = _MODREV .. _SPECREV

description = {
  summary = 'Mercurial signs written in pure lua',
  detailed = [[
    Super fast Mercurial decorations implemented purely in Lua.
  ]],
  homepage = 'http://github.com/lewis6991/hgsigns.nvim',
  license = 'MIT/X11',
  labels = { 'neovim' }
}

dependencies = {
  'lua == 5.1',
}

source = {
  url = 'http://github.com/lewis6991/hgsigns.nvim/archive/v' .. _MODREV .. '.zip',
  dir = 'hgsigns.nvim-' .. _MODREV,
}

if _MODREV == 'scm' then
  source = {
    url = 'git://github.com/lewis6991/hgsigns.nvim',
  }
end

build = {
  type = 'builtin',
  copy_directories = {
    'doc',
    'plugin',
  },
}
