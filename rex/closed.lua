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
  run = function(ctx)
    -- The picker in a tab of its own; it gives focus back to this pane when
    -- cancelled, and closes once it is done.
    local w, err = rex.session.new_window{
      window_label = "Recently Closed",
      layout = rex.layout.block{
        flavor = terminal .. ".shell",
        options = { command = { "/bin/zsh", "-lic", 'exec "$@"', "zsh", closed, "pick", ctx.block_id or "" } },
      },
    }
    if w == nil then error(err, 0) end
    return { window_id = w.window_id }
  end,
}

rex.bind("shift+cmd+t", "recently_closed")
