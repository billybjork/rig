-- Each part of the config lives in its own file beside this one, so pasting a
-- new version of one (such as nts.lua from nuts-to-soup's tui/rex/init.lua)
-- leaves the others alone.

local dir = os.getenv("HOME") .. "/.config/rex/"
dofile(dir .. "projects.lua")
dofile(dir .. "nts.lua")
dofile(dir .. "shipyard.lua")
dofile(dir .. "background.lua")
