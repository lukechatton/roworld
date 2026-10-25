-- Test-only maps, not in the game: the two small maps many tests were written on (Pangaea, Onion), kept
-- here so those tests keep their numbers after the game's fictional maps were removed (2026-10-25).
-- WorldMap finds them through a provider, by id.
local WorldMap = require("../../src/shared/Core/WorldMap")

local FixtureMaps = { pangaea = "Pangaea", onion = "Onion" }

WorldMap.add_provider(function(id: string): { [string]: any }?
	local module = FixtureMaps[id]
	return if module ~= nil then (require :: any)("./maps/" .. module) else nil
end)

return FixtureMaps
