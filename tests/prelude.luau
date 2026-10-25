-- Lune test prelude: expose the Roblox datatypes shared code may use as globals.
local roblox = require("@lune/roblox")
for _, name in ipairs({
	"Vector2",
	"Vector3",
	"Color3",
	"CFrame",
	"Vector2int16",
	"Vector3int16",
	"Rect",
	"UDim",
	"UDim2",
	"NumberRange",
}) do
	(getfenv() :: any)[name] = (roblox :: any)[name]
end
-- the test-only maps (after the globals: WorldMap uses them)
require("./fixtures/fixture_maps")
return roblox
