-- Marks tabs where Claude Code is idle but still has a background shell
-- running: the tab label gets a "⚙ " prefix until the shell exits.
--
-- Rex has no indicator for this (Claude Code only reports idle/done), so this
-- watches for Claude's Bash children (zsh -c source …/shell-snapshots/…) and
-- relabels the window. Runs as a long-lived `rex do` script, started by the
-- LaunchAgent com.billy.rex-bg-shells (via bg-shells.sh).

local TERMINAL = "com.superlogical.terminal"
local MARK = "⚙ "

-- window_id -> { session_id, original label, label we set }
local marked = {}

local function is_default(label)
  return label == nil or label == "" or label:match("^Window %x+$") ~= nil
end

-- pid -> true for every process that has a Claude shell child
local function pids_with_shells()
  local r = rex.exec({ "ps", "-axo", "ppid=,command=" }, { timeout = 5 })
  local out = {}
  if not r or r.code ~= 0 then return out end
  for ppid, cmd in r.stdout:gmatch("%s*(%d+)%s+([^\n]*)") do
    if cmd:find("/.claude/shell-snapshots/", 1, true) then out[tonumber(ppid)] = true end
  end
  return out
end

-- The pid of an idle Claude Code in this block, or nil when it isn't one.
local function idle_claude(sid, bid)
  local st = rex.block.call(TERMINAL, "program_status", { session_id = sid, block_id = bid })
  for _, rec in ipairs(st and st.records or {}) do
    if rec.effective_app == "claude-code" and rec.owner and rec.state ~= "working" and rec.state ~= "blocked" then
      return rec.owner.pid
    end
  end
end

local function set_label(sid, wid, label)
  print(os.date("%H:%M:%S") .. " " .. wid .. " -> " .. (label == "" and "(default)" or label))
  rex.call("session.set_window_label", { session_id = sid, window_id = wid, label = label })
end

local HEARTBEAT = os.getenv("HOME") .. "/Library/Caches/rex-bg-shells.heartbeat"

local function tick()
  -- bg-shells.sh restarts this script when the heartbeat goes stale, since a
  -- call can hang after the Mac sleeps rather than fail
  local f = io.open(HEARTBEAT, "w")
  if f then f:close() end
  -- First pass: each window's idle Claude blocks. Only scan processes when
  -- there is at least one, since that's the costly part.
  local windows, any = {}, false
  local sessions, err = rex.call("session.list")
  if not sessions then
    -- lost the server (sleep, restart): exit so launchd starts a fresh copy
    print(os.date("%H:%M:%S") .. " session.list failed: " .. tostring(err))
    os.exit(1)
  end
  for _, s in ipairs(sessions and sessions.sessions or {}) do
    local sid = s.session_id
    local a = rex.call("session.attach", { session_id = sid })
    for _, w in ipairs(a and a.view and a.view.windows or {}) do
      local idle = {}
      for _, l in ipairs(w.layers or {}) do
        for _, b in ipairs(l.blocks or {}) do
          if b.creator_name == TERMINAL then
            local pid = idle_claude(sid, b.block_id)
            if pid then idle[#idle + 1] = { pid = pid, bid = b.block_id }; any = true end
          end
        end
      end
      windows[#windows + 1] = { sid = sid, w = w, idle = idle }
    end
  end
  local shells = any and pids_with_shells() or {}

  local seen = {}
  for _, entry in ipairs(windows) do
    local sid, w = entry.sid, entry.w
    local wid = w.window_id
    seen[wid] = true
    local busy, title = false, nil
    for _, c in ipairs(entry.idle) do
      if shells[c.pid] then
        busy = true
        local t = rex.block.call(TERMINAL, "title", { session_id = sid, block_id = c.bid })
        title = title or (t and t.title)
      end
    end

    local m = marked[wid]
    if m and w.label ~= m.set then
      -- someone renamed the tab while it was marked: keep their name
      m.original = (w.label:gsub("^" .. MARK, ""))
    end
    if busy then
      local original = m and m.original or w.label
      local base = is_default(original) and (title or original) or original
      local want = MARK .. base
      if w.label ~= want then set_label(sid, wid, want) end
      marked[wid] = { sid = sid, original = original, set = want }
    elseif m then
      set_label(sid, wid, is_default(m.original) and "" or m.original)
      marked[wid] = nil
    end
  end
  for wid in pairs(marked) do
    if not seen[wid] then marked[wid] = nil end
  end
end

-- Clear marks left behind if a previous run was killed mid-mark.
local sessions = rex.call("session.list")
for _, s in ipairs(sessions and sessions.sessions or {}) do
  local a = rex.call("session.attach", { session_id = s.session_id })
  for _, w in ipairs(a and a.view and a.view.windows or {}) do
    if w.label and w.label:sub(1, #MARK) == MARK then
      marked[w.window_id] = { sid = s.session_id, original = "", set = w.label }
    end
  end
end

tick()
rex.every(5, tick)
