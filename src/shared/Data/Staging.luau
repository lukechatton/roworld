--!strict
-- The Rofront Staging experience (2026-10-04: a separate game to test changes in before they go to
-- prod): its universe id, for what differs there (Data/Products' ids, the game menu's
-- "Replay as new player").
local Staging = {}

--- Rofront Staging's universe id.
Staging.UNIVERSE = 10769439627

--- True in the Rofront Staging experience.
function Staging.here(): boolean
	return typeof(game) == "Instance" and (game :: any).GameId == Staging.UNIVERSE
end

return Staging
