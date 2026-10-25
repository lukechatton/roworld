--!strict
-- Port of scripts/view/view_rules.gd — gameplay numbers the view draws (SAM / defense ranges, nuke
-- radii, interception odds), read from Rules at runtime so range rings and aim previews follow the
-- Sim when it is retuned. Prefers Rules' functions and falls back to the older constants.
--
-- Range metric (must match the Sim): covered <=> (dx * xs)^2 + dy^2 <= r^2 in grid tiles, dx wrapping
-- at W, xs = max(cos(lat of the target tile's row), 0.08) — Defs.range_d2 == SimState.range_d2.
local RS = game:GetService("ReplicatedStorage")
local Core = RS:WaitForChild("Airfront"):WaitForChild("Core")
local Defs = require(Core:WaitForChild("Defs")) :: any
local BaseRules = require(Core:WaitForChild("Rules")) :: any
--- The bound map's scaled rules (GameState.rules = Rules.for_map): ranges are in its tiles.
local Rules = BaseRules

local ViewRules = {}

--- Draw with `rules` (the bound state's Rules.for_map table); nil = the K_LIN 1 defaults.
function ViewRules.use(rules: any?)
	Rules = if rules ~= nil then rules else BaseRules
end

local function num(v: any, default: number): number
	return if type(v) == "number" then v else default
end

--- SAM interception range (tiles) for a SAM of `level`.
function ViewRules.sam_range(level: number?): number
	if type(Rules.sam_range) == "function" then
		return Rules.sam_range(level or 1)
	end
	return num(Rules.SAM_RADIUS, 0)
end

--- SAM range `ticks_since_upgrade` ticks after it reached `level` (grows over SAM_UPGRADE_TICKS).
function ViewRules.sam_range_at(level: number, ticks_since_upgrade: number): number
	if type(Rules.sam_range_at) == "function" then
		return Rules.sam_range_at(level, ticks_since_upgrade)
	end
	return ViewRules.sam_range(level)
end

function ViewRules.sam_upgrade_ticks(): number
	return num(Rules.SAM_UPGRADE_TICKS, 0)
end

--- Construction time (ticks) of structure kind `kind` (Defs.S_*).
function ViewRules.build_ticks(kind: number): number
	local bt = Rules.BUILD_TICKS
	if type(bt) == "table" then
		return num(bt[kind], 0)
	end
	return 0
end

--- Warship patrol radius around its patrol point (tiles).
function ViewRules.warship_patrol_range(): number
	if type(Rules.warship_patrol_range) == "function" then
		return Rules.warship_patrol_range()
	end
	if Rules.WARSHIP_PATROL_FULL ~= nil and Rules.K_LIN ~= nil then
		return Rules.WARSHIP_PATROL_FULL / Rules.K_LIN
	end
	return num(Rules.WARSHIP_PATROL_RADIUS, 0)
end

--- Warship targeting range (tiles).
function ViewRules.warship_target_range(): number
	if type(Rules.warship_target_range) == "function" then
		return Rules.warship_target_range()
	end
	if type(Rules.warship_range) == "function" then
		return Rules.warship_range()
	end
	return num(Rules.WARSHIP_RANGE, 0)
end

--- Train-station reach of a factory (tiles), shown by its ghost.
function ViewRules.factory_range(): number
	return num(Rules.ROAD_MAX_TILES, 0)
end

--- The Arsenal (Data/Arsenal): an Artillery battery's range and an Airfield's reach (tiles).
function ViewRules.artillery_range(): number
	return if type(Rules.artillery_range) == "function" then Rules.artillery_range() else 45
end

function ViewRules.airfield_range(): number
	return if type(Rules.launch_range) == "function" then Rules.launch_range(Defs.N_AIRSTRIKE) else 156
end

--- Defense-post protection radius (tiles).
function ViewRules.defense_range(): number
	if type(Rules.defense_range) == "function" then
		return Rules.defense_range()
	end
	return num(Rules.DEFENSE_RADIUS, 0)
end

--- inner, outer blast radii in tiles of nuke kind `kind` (Defs.N_*). MIRV: 0, spread.
function ViewRules.nuke_radii(kind: number): (number, number)
	if type(Rules.nuke_radii) == "function" then
		local a, b = Rules.nuke_radii(kind)
		if type(a) == "number" and type(b) == "number" then
			return a, b
		end
	end
	if kind == Defs.N_MIRV then
		return 0, num(Rules.MIRV_SPREAD, 0)
	end
	local radii = Rules.NUKE_RADIUS
	local outer = if type(radii) == "table" then num(radii[kind], 0) else 0
	return outer * num(Rules.NUKE_INNER, 1.0), outer
end

--- Nuke kind (Defs.N_*) whose outer radius rounds to `radius_tiles`, or -1.
function ViewRules.nuke_kind_for_radius(radius_tiles: number): number
	for _, k in { Defs.N_ATOM, Defs.N_HYDROGEN, Defs.N_MIRV } do
		local _, o = ViewRules.nuke_radii(k)
		if o > 0 and (math.floor(o) == radius_tiles or Defs.round(o) == radius_tiles) then
			return k
		end
	end
	return -1
end

--- Radius of a human player's spawn disk (Sim._claim_disk claims sqrt(R^2 + R)).
function ViewRules.spawn_radius(): number
	return num(Rules.SPAWN_RADIUS_HUMAN, 4)
end

--- Chance that one ready hostile SAM shoots down nuke kind `kind` (0 = can't be intercepted).
function ViewRules.intercept_p(kind: number): number
	local p = Rules.NUKE_INTERCEPT_P
	if type(p) == "table" and p[kind] ~= nil then
		return p[kind]
	end
	return 1.0
end

--- Squared range distance (tiles) from structure tile `centre` to tile `t` in the Sim's metric.
function ViewRules.range_d2(centre: number, t: number): number
	return Defs.range_d2(centre, t)
end

return ViewRules
