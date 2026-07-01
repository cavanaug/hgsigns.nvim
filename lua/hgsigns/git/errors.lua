return {
  e = {
    not_in_hg = 'abort: no repository found',
    -- Legacy git-format messages still pattern-matched as fallbacks when
    -- resolving renamed paths; hg does not emit these but they are harmless.
    path_does_not_exist = "fatal: path .* does not exist in '.*'",
    path_exist_on_disk_but_not_in = "fatal: path .* exists on disk, but not in '.*'",
  },
}
