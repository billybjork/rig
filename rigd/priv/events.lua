-- rigd's Closed (~/dev/rig/rigd) runs this with `rex do --all`: one line
-- each time a tab or pane opens or closes in any session, so it looks at
-- Rex then rather than only on Activity's next tick, which a tab open for
-- two seconds falls between.
io.stdout:setvbuf("no")
for _, e in ipairs({ "window_created", "window_closed", "block_created", "block_closed" }) do
  rex.on(e, function() print(e) end)
end
