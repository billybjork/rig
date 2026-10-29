-- Shipyard and the Sprites in Rex: the ship workers, each
-- project's queue and gate pool, and a console on any Sprite. Find them in
-- the command palette under "Shipyard" and "Sprites".
--
-- The projects are shipyard's own list, ~/.config/shipyard/projects (one
-- checkout per line), and the Sprites are `sprite ls`'s, both read when the
-- config loads: run `rex config reload` after adding either.

local terminal = "com.superlogical.terminal"
local home = os.getenv("HOME")
local shipyard = (os.getenv("SHIPYARD") or (home .. "/dev/rig/shipyard")) .. "/bin/shipyard"
-- A pane an action opens gets the Rex server's environment, which has no
-- mix or sprite on its PATH, so its command runs in an interactive login
-- zsh, which sets them up (~/.zshrc).
local function login(command)
  local wrapped = { "/bin/zsh", "-lic", 'exec "$@"', "zsh" }
  for _, word in ipairs(command) do wrapped[#wrapped + 1] = word end
  return wrapped
end

-- A pane below the focused one, in its tab, running command at dir and kept
-- open once it ends so its output can be read.
local function pane(ctx, label, dir, command)
  local s, err = rex.session.new_split{
    anchor_id = ctx.block_id,
    direction = "vertical",
    side = "after",
    ratio = 0.6,
    focus = true,
    layout = {
      block = {
        flavor = terminal .. ".shell",
        label = label,
        options = { cwd = dir, command = login(command), exit = { on_completion = false } },
      },
    },
  }
  if s == nil then error(err, 0) end
  return s
end

local function exists(path)
  local f = io.open(path, "r")
  if f then f:close() end
  return f ~= nil
end

-- The workers run in background terminals in the session Shipyard (blocks
-- no tab shows; `bin/shipyard start`). Showing them gives each its own tab
-- there: a placeholder opens the tab, the worker goes beside it, and the
-- placeholder closes. "Background: Hide This Pane" sends one back.
rex.action{
  name = "shipyard_workers",
  title = "Shipyard: Show the Workers",
  description = "Switch to the Shipyard session, giving each ship worker (and each wait there) its own tab.",
  category = "Shipyard",
  keywords = "ship worker queue gate roll shipyard background",
  run = function()
    local list, err = rex.call("session.list", {})
    if list == nil then error(err, 0) end
    local session
    for _, s in ipairs(list.sessions or {}) do
      if s.label == "Shipyard" then session = s.session_id end
    end
    if session == nil then
      error("no worker runs in Rex: the next ship starts one in a Shipyard session", 0)
    end
    local blocks, berr = rex.call("session.list_blocks", { session_id = session })
    if blocks == nil then error(berr, 0) end
    for _, b in ipairs(blocks.blocks or {}) do
      if b.placement == "detached" and b.creator_name == terminal then
        local w, werr = rex.call("session.new_window", {
          session_id = session,
          window_label = b.label,
          focus = false,
          layout = { block = { flavor = terminal .. ".shell", label = "placeholder" } },
        })
        if w == nil then error(werr, 0) end
        local placeholder = w.block_ids[1]
        local _, merr = rex.call("session.move_block", {
          session_id = session,
          block_id = b.block_id,
          anchor_block_id = placeholder,
        })
        rex.call("block.close", { session_id = session, block_id = placeholder })
        if merr ~= nil then error(merr, 0) end
      end
    end
    rex.client.queue("session.select", { session_id = session })
    return { session_id = session }
  end,
}

-- Each project shipyard knows: its queue, its numbers, and its gate pool.
local list = io.open(home .. "/.config/shipyard/projects", "r")
for line in (list and list:read("*a") or ""):gmatch("[^\n]+") do
  local dir = line:gsub("^~", home):gsub("%s+$", "")
  if dir ~= "" and not dir:find("^#") then
    local name = dir:match("([^/]+)$")
    local key = name:lower():gsub("[^%w]", "_")

    rex.action{
      name = "shipyard_queue_" .. key,
      title = "Shipyard: Queue (" .. name .. ")",
      description = "The ship queue, the entry the worker is on, what waits for a roll, and the last results.",
      category = "Shipyard",
      keywords = "ship queue list results " .. name,
      run = function(ctx) return pane(ctx, name .. " ships", dir, { shipyard, "list", dir }) end,
    }

    rex.action{
      name = "shipyard_numbers_" .. key,
      title = "Shipyard: Numbers (" .. name .. ")",
      description = "Gate time p50 and p90, queue wait, and reds and retries by cause.",
      category = "Shipyard",
      keywords = "ship summary numbers gate time causes " .. name,
      run = function(ctx)
        return pane(ctx, name .. " numbers", dir, { shipyard, "list", dir, "--summary" })
      end,
    }

    for _, script in ipairs({ "tooling/gate-pool.sh", "scripts/gate-pool.sh" }) do
      if exists(dir .. "/" .. script) then
        rex.action{
          name = "sprites_pool_" .. key,
          title = "Sprites: Gate Pool (" .. name .. ")",
          description = "Each gate Sprite's provision stamp and checkpoint, against this checkout's.",
          category = "Sprites",
          keywords = "sprite pool gate status stamp checkpoint " .. name,
          run = function(ctx) return pane(ctx, name .. " pool", dir, { "bash", script, "status" }) end,
        }
        break
      end
    end
  end
end
if list then list:close() end

-- A console on each Sprite, beside the focused pane. Ctrl+\ detaches and
-- leaves its shell running on the Sprite (`sprite sessions`).
local sprites = rex.exec({ "sh", "-lc", "sprite ls" }, { timeout = 15 })
for name in ((sprites and sprites.ok) and sprites.stdout or ""):gmatch("[^\n]+") do
  name = name:gsub("%s+$", "")
  if name:match("^[%w-]+$") then
    rex.action{
      name = "sprites_console_" .. name:gsub("[^%w]", "_"),
      title = "Sprites: Console on " .. name,
      description = "An interactive shell on " .. name .. " in a pane beside this one.",
      category = "Sprites",
      keywords = "sprite console shell ssh remote " .. name,
      run = function(ctx)
        local s, err = rex.session.new_split{
          anchor_id = ctx.block_id,
          direction = "horizontal",
          side = "after",
          focus = true,
          layout = rex.layout.block{
            flavor = terminal .. ".shell",
            options = { cwd = home, command = login({ "sprite", "console", "-s", name }) },
          },
        }
        if s == nil then error(err, 0) end
        return s
      end,
    }
  end
end
