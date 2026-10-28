-- Projects in Rex: one session per repository in ~/dev, and new tabs and
-- splits that open at the project's main checkout.

local terminal = "com.superlogical.terminal"
local projects_dir = os.getenv("HOME") .. "/dev"

-- New tabs and splits open at the project's main checkout, not the worktree
-- the focused pane happens to be in: a new pane is usually a new task, which
-- gets its own worktree.

-- The directory the focused pane is in. Shells that report it (OSC 7) win;
-- otherwise use the foreground program's, such as Claude Code's.
local function pane_dir(block_id)
  if block_id == nil then return nil end
  local pwd = rex.block.call(terminal, "pwd", { block_id = block_id })
  if pwd and pwd.pwd and pwd.pwd ~= "" then return pwd.pwd end
  local p = rex.block.call(terminal, "process", { block_id = block_id })
  if p == nil then return nil end
  if p.foreground and p.foreground.cwd then return p.foreground.cwd end
  for _, a in ipairs(p.ancestors or {}) do
    if a.cwd then return a.cwd end
  end
end

-- The main worktree of the repository dir is in, or dir itself outside git.
-- A worktree can be removed while a pane is still in it, so a directory that
-- no longer exists is looked up from its nearest parent instead.
local function project_root(dir)
  local r = rex.exec(
    { "git", "-C", dir, "rev-parse", "--path-format=absolute", "--git-common-dir" },
    { timeout = 5 })
  if r and r.ok then
    local root = r.stdout:gsub("%s+$", ""):match("^(.*)/%.git$")
    if root then return root end
  elseif r and r.stderr:find("cannot change to", 1, true) then
    local parent = dir:match("^(.+)/[^/]+$")
    if parent then return project_root(parent) end
  end
  return dir
end

local function shell_at(dir)
  return rex.layout.block{ flavor = terminal .. ".shell", options = { cwd = dir } }
end

-- A shell at the project root of the pane block_id is in.
local function project_shell(block_id)
  local dir = pane_dir(block_id)
  return shell_at(dir and project_root(dir) or nil)
end

rex.action{
  name = "project_tab",
  title = "New Tab at Project Root",
  description = "Open a tab in the main checkout of the focused pane's repository.",
  category = "Tab",
  keywords = "new tab project root worktree main",
  run = function(ctx)
    local w, err = rex.session.new_window{ layout = project_shell(ctx.block_id) }
    if w == nil then error(err, 0) end
    return { window_id = w.window_id }
  end,
}

-- How each pane.split direction maps onto new_split's direction and side.
local split_sides = {
  right = { "horizontal", "after" },
  left  = { "horizontal", "before" },
  down  = { "vertical", "after" },
  up    = { "vertical", "before" },
}

rex.action{
  name = "project_split",
  title = "Split Pane at Project Root",
  description = "Split the focused pane, starting in the main checkout of its repository.",
  category = "Pane",
  keywords = "split pane project root worktree main",
  args = { direction = "string?" },
  run = function(ctx, args)
    local side = split_sides[args.direction or "right"]
    if side == nil then error("unknown direction " .. args.direction, 0) end
    local s, err = rex.session.new_split{
      anchor_id = ctx.block_id,
      direction = side[1],
      side = side[2],
      focus = true,
      layout = project_shell(ctx.block_id),
    }
    if s == nil then error(err, 0) end
    return s
  end,
}

rex.bind("cmd+t", "project_tab")
rex.bind("cmd+d", "project_split", { direction = "right" })
rex.bind("shift+cmd+d", "project_split", { direction = "down" })

-- Closing a session's last tab closes the session, so each repository in
-- ~/dev gets a "Project: name" action in the palette that switches to its
-- session, or opens a new one at the project root. A session matches when
-- its label does, ignoring case, spaces, and dashes, so "Nuts to Soup" is
-- nuts-to-soup's session.

local function squash(s)
  return (s:lower():gsub("[^%w]", ""))
end

-- The session labelled for project name, or nil.
local function project_session(name)
  local list, err = rex.call("session.list", {})
  if list == nil then error(err, 0) end
  for _, s in ipairs(list.sessions or {}) do
    if squash(s.label or "") == squash(name) then return s.session_id end
  end
end

local function open_project(name)
  local shell = shell_at(projects_dir .. "/" .. name)
  local id = project_session(name)
  if id == nil then
    local s, err = rex.call("session.create", {
      label = name,
      initial_windows = { { layout = shell } },
    })
    if s == nil then error(err, 0) end
    id = s.session_id
  end
  rex.client.queue("session.select", { session_id = id })
  return { session_id = id }
end

local repos = rex.exec({ "sh", "-c", 'for g in "$1"/*/.git; do basename "${g%/.git}"; done', "sh", projects_dir })
for name in ((repos and repos.ok) and repos.stdout or ""):gmatch("[^\n]+") do
  if not name:find("*", 1, true) then
    rex.action{
      name = "project_" .. name:lower():gsub("[^%w]", "_"),
      title = "Project: " .. name,
      description = "Switch to " .. name .. "'s session, or open one at ~/dev/" .. name .. ".",
      category = "Projects",
      keywords = "project session open switch " .. name,
      run = function() return open_project(name) end,
    }
  end
end

return { project_session = project_session, project_root = project_root }
