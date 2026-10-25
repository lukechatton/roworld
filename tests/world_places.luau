-- Test helper (not a test): real places on the "world" map (2000 x 1000). The tests were
-- written against the retired 1024 x 512 equirectangular Earth grid; this maps a latitude /
-- longitude through that grid onto World with the isotropic fit used by tests/simsys_fixture.luau
-- (x' = (x + 0.5) * 2000 / 1024 - 65, y' = (y + 0.5) * 2000 / 1024 - 10; 92-97 % land/water
-- agreement around Europe and Asia).
local WorldMap = require("../src/shared/Core/WorldMap")

local P = {}
P.map = WorldMap.get("world")
local L = 2000 / 1024

--- World tile nearest to latitude / longitude (degrees).
function P.latlon_to_tile(lat: number, lon: number): number
	local ex = math.floor((lon + 180.0) / 360.0 * 1024)
	local ey = math.floor((90.0 - lat) / 180.0 * 512)
	local x = math.clamp(math.floor((ex + 0.5) * L - 65), 0, P.map.W - 1)
	local y = math.clamp(math.floor((ey + 0.5) * L - 10), 0, P.map.H - 1)
	return y * P.map.W + x
end

return P
