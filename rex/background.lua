-- Background terminals: shells, dev servers, and waits that agents start run
-- in blocks no tab shows (`~/dev/rig/bin/bg run`, shipyard's watch). These
-- actions bring one into view below the focused pane, or send a pane back.
-- Find them in the command palette under "Background".

local terminal = "com.superlogical.terminal"
local bg = os.getenv("HOME") .. "/dev/rig/bin/bg"

-- The session's background terminals, as a list of block IDs.
local function detached(session_id)
  local r, err = rex.call("session.list_blocks", { session_id = session_id })
  if r == nil then error(err, 0) end
  local out = {}
  for _, b in ipairs(r.blocks or {}) do
    if b.placement == "detached" and b.creator_name == terminal then out[#out + 1] = b.block_id end
  end
  return out
end

local function place(ctx, block_id)
  local _, err = rex.call("session.move_block", {
    session_id = ctx.session_id,
    block_id = block_id,
    anchor_block_id = ctx.block_id,
    direction = "vertical",
    side = "after",
    ratio = 0.6,
  })
  if err ~= nil then error(err, 0) end
  return { shown = block_id }
end

rex.action{
  name = "background_show",
  title = "Background: Show",
  description = "Bring a background terminal (an agent's shell, server, or wait) into view below this pane.",
  category = "Background",
  keywords = "background hidden shell server wait show unhide detached",
  run = function(ctx)
    local blocks = detached(ctx.session_id)
    if #blocks == 0 then error("no background terminals in this session", 0) end
    if #blocks == 1 then return place(ctx, blocks[1]) end
    -- Several: a picker in a floating layer, which closes once it is done.
    local r, err = rex.session.new_layer{
      bounds = { 0.15, 0.2, 0.7, 0.5 },
      focus = true,
      layout = rex.layout.block{
        flavor = terminal .. ".shell",
        label = "background",
        options = { command = { "/bin/zsh", "-lic", 'exec "$@"', "zsh", bg, "pick", ctx.block_id } },
      },
    }
    if r == nil then error(err, 0) end
    return r
  end,
}

rex.action{
  name = "background_hide",
  title = "Background: Hide This Pane",
  description = "Take the focused pane out of its tab. It keeps running; Background: Show brings it back.",
  category = "Background",
  keywords = "background hide detach pane shell",
  run = function(ctx)
    local _, err = rex.call("session.detach_block", { session_id = ctx.session_id, block_id = ctx.block_id })
    if err ~= nil then error(err, 0) end
    return { hidden = ctx.block_id }
  end,
}
