-- Restore Sessions: the sessions that were open before Rex last restarted (a
-- reboot, a crash), as rigd saves them (~/dev/rig/bin/restore). Each comes
-- back by name with its tabs and splits, each pane at its directory, with a
-- Claude pane resumed. Find it in the command palette.

local terminal = "com.superlogical.terminal"
local restore = os.getenv("HOME") .. "/dev/rig/bin/restore"

rex.action{
  name = "restore_sessions",
  title = "Restore Sessions",
  description = "Reopen the sessions that were open before Rex restarted, Claude sessions resumed.",
  category = "Session",
  keywords = "restore sessions reboot restart reopen tabs claude resume",
  run = function(ctx)
    -- The picker in a tab of its own, which closes once it is done.
    local w, err = rex.session.new_window{
      window_label = "Restore Sessions",
      layout = rex.layout.block{
        flavor = terminal .. ".shell",
        options = { command = { "/bin/zsh", "-lic", 'exec "$@"', "zsh", restore, "pick", ctx.block_id or "" } },
      },
    }
    if w == nil then error(err, 0) end
    return { window_id = w.window_id }
  end,
}
