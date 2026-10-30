-- Recently Closed: the tabs and panes that closed lately, as rigd records
-- them (~/dev/rig/bin/closed). Choosing one reopens it as a new tab in its
-- session, at each pane's directory, with a Claude pane resumed. Find it in
-- the command palette, or press Shift+Cmd+T.

local terminal = "com.superlogical.terminal"
local closed = os.getenv("HOME") .. "/dev/rig/bin/closed"

rex.action{
  name = "recently_closed",
  title = "Recently Closed",
  description = "Reopen a tab or pane that closed lately, its Claude session resumed.",
  category = "Tab",
  keywords = "recently closed reopen restore undo tab pane claude resume",
  run = function()
    -- A picker in a floating layer, which closes once it is done.
    local r, err = rex.session.new_layer{
      bounds = { 0.15, 0.2, 0.7, 0.5 },
      focus = true,
      layout = rex.layout.block{
        flavor = terminal .. ".shell",
        label = "recently closed",
        options = { command = { "/bin/zsh", "-lic", 'exec "$@"', "zsh", closed, "pick" } },
      },
    }
    if r == nil then error(err, 0) end
    return r
  end,
}

rex.bind("shift+cmd+t", "recently_closed")
