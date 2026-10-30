-- One snapshot of Rex for rigd (~/dev/rig/rigd): every session's tabs and
-- their terminals (each one's directory, for reopening it once closed), the
-- status each agent in a terminal reports (Claude Code, Codex), and whether
-- each background terminal's command still runs.
-- Printed as one JSON line; rigd runs this with `rex do` every few seconds.

local TERMINAL = "com.superlogical.terminal"

local function call(method, args)
  local r = rex.block.call(TERMINAL, method, args)
  return r
end

-- The agent a terminal holds, from the status its program reports.
local function agent(sid, bid)
  local st = call("program_status", { session_id = sid, block_id = bid })
  for _, rec in ipairs(st and st.records or {}) do
    if rec.effective_app and rec.owner then
      return { app = rec.effective_app, state = rec.state, pid = rec.owner.pid, msg = rec.msg }
    end
  end
end

local function title(sid, bid)
  local t = call("title", { session_id = sid, block_id = bid })
  return t and t.title
end

-- The directory a terminal is in: the one its shell reports (OSC 7), else
-- its foreground program's, such as Claude Code's.
local function cwd(sid, bid)
  local pwd = call("pwd", { session_id = sid, block_id = bid })
  if pwd and pwd.pwd and pwd.pwd ~= "" then return (pwd.pwd:gsub("^file://[^/]*", "")) end
  local p = call("process", { session_id = sid, block_id = bid })
  if p == nil then return nil end
  if p.foreground and p.foreground.cwd then return p.foreground.cwd end
  for _, a in ipairs(p.ancestors or {}) do
    if a.cwd then return a.cwd end
  end
end

local list, err = rex.call("session.list")
if not list then
  io.stderr:write("session.list failed: " .. tostring(err) .. "\n")
  os.exit(1)
end

local sessions = {}
for _, s in ipairs(list.sessions or {}) do
  local sid = s.session_id
  local sess = { id = sid, label = s.label or "", windows = {}, detached = {} }
  local a = rex.call("session.attach", { session_id = sid })
  for _, w in ipairs(a and a.view and a.view.windows or {}) do
    local win = { id = w.window_id, label = w.label or "", blocks = {} }
    for _, l in ipairs(w.layers or {}) do
      for _, b in ipairs(l.blocks or {}) do
        if b.creator_name == TERMINAL then
          local blk = {
            id = b.block_id,
            agent = agent(sid, b.block_id),
            cwd = cwd(sid, b.block_id),
            floating = l.kind ~= "tiled",
          }
          if blk.agent then blk.title = title(sid, b.block_id) end
          win.blocks[#win.blocks + 1] = blk
        end
      end
    end
    sess.windows[#sess.windows + 1] = win
  end
  local lb = rex.call("session.list_blocks", { session_id = sid })
  for _, b in ipairs(lb and lb.blocks or {}) do
    if b.placement == "detached" and b.creator_name == TERMINAL then
      local p = call("process", { session_id = sid, block_id = b.block_id })
      sess.detached[#sess.detached + 1] = {
        id = b.block_id,
        label = b.label or "",
        running = (p and p.child) ~= nil,
        agent = agent(sid, b.block_id),
      }
    end
  end
  sessions[#sessions + 1] = sess
end

print(rex.json.encode({ sessions = sessions }))
