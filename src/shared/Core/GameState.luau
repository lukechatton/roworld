--!native
-- Port of scripts/core/game_state.gd: client-side mirror of the match. Built from Sim.snapshot()
-- and kept current with Sim.step() deltas (locally in solo, via the network in multiplayer).
-- Views and UI read only this object.
--
-- Representation (see build/notes/READY-core-api for the full contract):
-- * owner: buffer of i32 per tile (buffer.readi32(state.owner, t * 4)); use state:tile_owner(t).
-- * flags: buffer of u8 per tile (bit0 = fallout); use state:has_fallout(t).
-- * owners / structures / roads / units / nukes / attacks / shells / sam_missiles: tables keyed by
--   id (iteration order is unspecified — sort when order matters). Info records are plain tables
--   with the GDScript member names (OwnerInfo.color is a Color3 in Roblox; OwnerInfo.rgba is the
--   RGBA8 int).
-- * alliances: key min(a,b)*1024+max(a,b) → true; requests: key from*1024+to → tick.
-- * Signals (Core/Signal): same names and argument order as the GDScript signals.
-- * The map: state.map (a WorldMap; flat W x H grid, no wrap), state.W / state.H / state.N, its
--   scaled rules in state.rules (Rules.for_map) and state.map_id. Positions are MAP SPACE: x right,
--   y down, in tiles (tile i covers [x, x+1) x [y, y+1), centre (x + 0.5, y + 0.5)); z is height
--   above the map (nuke arcs), 0 on the ground.
-- * Vector-returning helpers (tile_dir, unit_pose, nuke_pose) return Vector3s (Roblox or the Lune
--   prelude); *_xyz variants return plain numbers.
local Defs = require("./Defs")
local Ev = require("./Ev")
local Rules = require("./Rules")
local Signal = require("./Signal")
local WorldMap = require("./WorldMap")
local Coop = require("../Net/Coop")

local F_FALLOUT = Defs.F_FALLOUT

local GameState = {}
GameState.__index = GameState

local SIGNALS = {
	"snapshot_loaded",
	"cosmetics_changed", -- (ids: {number}) owners whose equipped skin / flag changed (set_cosmetics)
	"tiles_changed", -- (changed: {number}, olds: {number}) packed tile * 1024 + owner, new values; olds[k]: the owner changed[k]'s tile had (the list is reused: read it in the handler)
	"flags_changed", -- (changed: {number}) packed tile * 256 + flags
	"ticked", -- (tick)
	"stats_changed",
	"owner_added", -- (id)
	"owner_eliminated", -- (id, killer)
	"conquest", -- (conqueror, conquered, gold) Ev.CONQUEST: the gold the conqueror took
	"reinforced", -- (owner, troops, ready_tick) the Arsenal's Reinforcements arrived
	"bonus", -- (owner, tile, gold) Ev.BONUS: gold earned at a tile (a train's stop)
	"owner_spawned", -- (id, tile)
	"structure_added", -- (sid)
	"structure_changed", -- (sid, old_owner)
	"structure_removed", -- (sid)
	"structure_leveled", -- (sid) level or construction state changed (Ev.STRUCT_LEVEL)
	"road_added", -- (rid)
	"road_removed", -- (rid)
	"unit_added", -- (uid)
	"unit_moved", -- (uid)
	"unit_removed", -- (uid, reason)
	"unit_hp_changed", -- (uid)
	"unit_veterancy_changed", -- (uid)
	"unit_state_changed", -- (uid)
	"shell_fired", -- (id)
	"shell_impact", -- (id, hit)
	"sam_launched", -- (nuke_uid)
	"nuke_launched", -- (uid)
	"nuke_detonated", -- (uid, kind, tile, radius, owner)
	"attack_started", -- (aid)
	"attack_updated", -- (aid)
	"attack_ended", -- (aid)
	"alliance_requested", -- (from, to)
	"alliance_request_closed", -- (from, to)
	"alliance_changed", -- (a, b, formed, traitor, expired)
	"alliance_extension", -- (a, b, expires_at, asked) a renewal was asked for or granted (Ev.ALLY_EXT)
	"traitor_marked", -- (id, until_tick)
	"message", -- (to, category, text)
	"phase_changed", -- (phase, ticks_left)
	"game_over", -- (winner, reason)
}
GameState.SIGNAL_NAMES = SIGNALS

local function new_owner_info(id: number)
	return {
		id = id,
		name = "",
		rgba = 0xFFFFFFFF,
		color = Defs.color_from_int(0xFFFFFFFF),
		kind = Defs.KIND_NATION,
		--- team games (Core/Teams): 1..#team_names; 0 = none
		team = 0,
		alive = true,
		spawned = false,
		spawn_tile = -1,
		tiles = 0,
		troops = 0,
		gold = 0,
		max_troops = 0,
		income = 0, -- gold per second
		traitor_until = 0, -- tick
		killer = 0,
		-- sums of the owned tiles' x and y (territory centroid = (cx, cy) / tiles); cz unused (0)
		cx = 0.0,
		cy = 0.0,
		cz = 0.0,
		label_tile = -1,
	}
end
GameState.new_owner_info = new_owner_info

export type OwnerInfo = typeof(new_owner_info(0))
export type StructInfo = {
	sid: number,
	kind: number,
	owner: number,
	tile: number,
	level: number,
	active_tick: number,
	--- SAMs / silos: launch or upgrade ticks of missiles still reloading (Ev.STRUCT_SHOTS; entries
	--- older than the cooldown have reloaded)
	shots: { number }?,
}
--- A railroad: stations a and b (structure ids) and its tiles from a's end to b's end.
export type RoadInfo = { rid: number, a: number, b: number, tiles: { number } }
export type UnitInfo = {
	uid: number,
	kind: number,
	owner: number,
	path: { number },
	start_tick: number,
	ticks_per_tile_x100: number,
	troops: number,
	prev_tile: number,
	move_tick: number,
	hp: number,
	max_hp: number,
	veterancy: number,
	state: number,
	patrol_tile: number,
}
export type SamMissileInfo = {
	sam_sid: number,
	nuke_uid: number,
	fire_tick: number,
	intercept_tick: number,
	will_hit: boolean,
}
export type ShellInfo = {
	id: number,
	shooter_kind: number,
	shooter_id: number,
	from_tile: number,
	target_uid: number,
	fire_tick: number,
	impact_tick: number,
	damage: number,
}
export type NukeInfo = {
	uid: number,
	kind: number,
	owner: number,
	from_tile: number,
	to_tile: number,
	launch_tick: number,
	flight_ticks: number,
}
--- retreating: a retreat was ordered (the attack is frozen until its troops come home).
export type AttackInfo = {
	aid: number,
	attacker: number,
	target: number,
	troops: number,
	anchor_tile: number,
	retreating: boolean,
}

function GameState.new(world: any?)
	local self: any = setmetatable({}, GameState)
	for _, name in SIGNALS do
		self[name] = Signal.new()
	end
	local map = world or WorldMap.shared()
	self.map = map
	self.map_id = map.id
	Defs.set_view_map(map) -- deprecated UI shims follow the displayed map
	self.W = map.W
	self.H = map.H
	self.N = map.N
	--- The map's scaled rules (Rules.for_map): ranges / radii for this map.
	self.rules = Rules.for_map(map)
	self.tick = 0
	--- Smoothed fractional tick used for animation (set every frame by Session).
	self.render_tick = 0.0
	self.phase = Defs.PHASE_SPAWN
	self.phase_ticks_left = 0
	self.time_limit_ticks = 0
	--- Tick at which PLAYING began (-1 before that): from the snapshot or the PHASE event.
	self.playing_since = -1
	--- MIRVs launched this match (the next MIRV costs Rules.nuke_cost("mirv", mirvs_launched)).
	self.mirvs_launched = 0
	--- Shells in flight (Ev.SHELL), by shell id; removed at their impact tick (signal shell_impact).
	self.shells = {} :: { [number]: ShellInfo }
	--- SAM missiles in flight, by the uid of the nuke they chase; removed by that nuke's BOOM.
	self.sam_missiles = {} :: { [number]: SamMissileInfo }
	self._removed_now = {} :: { [number]: number }
	--- Per owner: {[slot] = count} (slot = Defs.S_* or Rules.BUILT_WARSHIP; 0-based) — how many
	--- were built, used by Rules.cost_of(). Read with built_count(id, slot).
	self.built = {} :: { [number]: { [number]: number } }
	self.winner = 0
	self.over_reason = -1
	--- Team games (Core/Teams): the team names (empty outside one) and the team that won (0: none).
	self.team_names = {} :: { string }
	self.winner_team = 0
	--- Owner id controlled by this client (0 = spectator / not yet joined).
	self.local_owner = 0
	self.loaded = false
	self.owner = buffer.create(map.N * 4)
	self.flags = buffer.create(map.N)
	--- Tiles currently irradiated (victory counts land that is not fallout; see Rules).
	self.fallout_count = 0
	self.owners = {} :: { [number]: OwnerInfo }
	self.structures = {} :: { [number]: StructInfo }
	self.roads = {} :: { [number]: RoadInfo }
	self.units = {} :: { [number]: UnitInfo }
	self.nukes = {} :: { [number]: NukeInfo }
	--- owner id -> the tick its next Reinforcements call is ready (Ev.REINFORCE; absent: now)
	self.reinforce_ready = {} :: { [number]: number }
	self.attacks = {} :: { [number]: AttackInfo }
	--- key = min(a,b) * 1024 + max(a,b)
	self.alliances = {} :: { [number]: boolean }
	--- key as alliances → tick at which the alliance expires (Rules.ALLIANCE_TICKS after it was
	--- formed or last renewed)
	self.alliance_expires = {} :: { [number]: number }
	--- key as alliances → renewal asked: bit 1 by min(a, b), bit 2 by max(a, b)
	self.alliance_ext = {} :: { [number]: number }
	self._ally_seq = {} :: { [number]: number } -- formation order (GDScript Dictionary order)
	self._seq = 0
	--- key = from * 1024 + to → tick the request was made
	self.requests = {} :: { [number]: number }
	--- key = from * 1024 + to → when the last request the mirror saw closed was made
	self._req_last = {} :: { [number]: number }
	--- owner id → { skin = id?, flag = id? } (Data/Cosmetics): outside the Sim — the match server
	--- sends it (OP.COSMETICS), a solo match sets the player's own
	self.cosmetics = {} :: { [number]: { skin: string?, flag: string?, face: number? } }
	return self
end

--- Replace the equipped cosmetics of the owners in `map` (owner id → {skin, flag, face}; an owner
--- mapped to false loses theirs). `face` is the player's Roblox user id (their head shot beside their
--- name). `full`: owners not in `map` lose theirs too. Fires cosmetics_changed.
function GameState.set_cosmetics(self: any, map: { [any]: any }, full: boolean?)
	local changed = {}
	local seen = {}
	for k, v in map do
		local id = tonumber(k)
		if id == nil or id <= 0 then
			continue
		end
		seen[id] = true
		local skin = if type(v) == "table" and type(v.skin) == "string" then v.skin else nil
		local flag = if type(v) == "table" and type(v.flag) == "string" then v.flag else nil
		local face = if type(v) == "table" and type(v.face) == "number" and v.face > 0 then v.face else nil
		local old = self.cosmetics[id]
		if skin == nil and flag == nil and face == nil then
			if old ~= nil then
				self.cosmetics[id] = nil
				table.insert(changed, id)
			end
		elseif old == nil or old.skin ~= skin or old.flag ~= flag or old.face ~= face then
			self.cosmetics[id] = { skin = skin, flag = flag, face = face }
			table.insert(changed, id)
		end
	end
	if full then
		for id in table.clone(self.cosmetics) do
			if not seen[id] then
				self.cosmetics[id] = nil
				table.insert(changed, id)
			end
		end
	end
	if #changed > 0 then
		self.cosmetics_changed:Fire(changed)
	end
end

export type GameState = typeof(GameState.new())

local function count_keys(t: { [any]: any }): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end
GameState.count_keys = count_keys

-- ---------------------------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------------------------

function GameState.get_owner(self: GameState, id: number): OwnerInfo?
	return self.owners[id]
end

function GameState.local_info(self: GameState): OwnerInfo?
	return self.owners[self.local_owner]
end

function GameState.owner_name(self: GameState, id: number): string
	if id == 0 then
		return "Unclaimed land"
	end
	local o = self.owners[id]
	return if o ~= nil then o.name else "Unknown"
end

local GREY = 0x999999FF -- Color(0.6, 0.6, 0.6)

--- Owner colour as a Color3 (grey for unknown owners).
function GameState.owner_color(self: GameState, id: number): any
	local o = self.owners[id]
	if o ~= nil then
		return o.color
	end
	return Defs.color_from_int(GREY)
end

--- Owner colour as an RGBA8 int.
function GameState.owner_rgba(self: GameState, id: number): number
	local o = self.owners[id]
	return if o ~= nil then o.rgba else GREY
end

--- Friendly: allies, and teammates in a team game (the Sim's `allied`).
function GameState.are_allies(self: GameState, a: number, b: number): boolean
	if a == 0 or b == 0 or a == b then
		return false
	end
	return self.alliances[math.min(a, b) * 1024 + math.max(a, b)] == true or self:same_team(a, b)
end

--- An alliance (not a team): what can be renewed or broken.
function GameState.has_alliance(self: GameState, a: number, b: number): boolean
	if a == 0 or b == 0 or a == b then
		return false
	end
	return self.alliances[math.min(a, b) * 1024 + math.max(a, b)] == true
end

-- ---------------------------------------------------------------------------------------------
-- Teams (team games; Core/Teams)
-- ---------------------------------------------------------------------------------------------

function GameState.is_team_game(self: GameState): boolean
	return #self.team_names > 0
end

--- `id`'s team (0: none).
function GameState.team_of(self: GameState, id: number): number
	local o = self.owners[id]
	return if o ~= nil then o.team or 0 else 0
end

function GameState.same_team(self: GameState, a: number, b: number): boolean
	local t = self:team_of(a)
	return a ~= b and t ~= 0 and t == self:team_of(b)
end

function GameState.team_name(self: GameState, t: number): string
	return self.team_names[t] or ""
end

--- The colour a team is shown in: its first member's.
function GameState.team_color(self: GameState, t: number): Color3
	local best = nil
	for id, o in self.owners do
		if o.team == t and (best == nil or id < best) then
			best = id
		end
	end
	return if best ~= nil then self.owners[best].color else Color3.new(0.6, 0.6, 0.6)
end

--- The teams by land: { {team, tiles, members (alive), alive} } sorted by tiles, most first.
function GameState.team_ranking(self: GameState): { { [string]: any } }
	local rows = {}
	for t = 1, #self.team_names do
		rows[t] = { team = t, tiles = 0, members = 0 }
	end
	for _, o in self.owners do
		local r = rows[o.team or 0]
		if r ~= nil and o.alive then
			r.tiles += o.tiles or 0
			r.members += 1
		end
	end
	local out = {}
	for t = 1, #self.team_names do
		table.insert(out, rows[t])
	end
	table.sort(out, function(a, b)
		if a.tiles ~= b.tiles then
			return a.tiles > b.tiles
		end
		return a.team < b.team
	end)
	return out
end

function GameState.has_request(self: GameState, from: number, to: number): boolean
	return self.requests[from * 1024 + to] ~= nil
end

--- Alliance info for `me` and ally `other`, or nil when not allied:
--- {expires_at, ticks_left, in_window (renewal may be asked: the last
--- Rules.ALLIANCE_EXTEND_WINDOW_TICKS), me_asked, other_asked, can_extend (in the window, both
--- alive, `me` has not asked yet)}. Send {type = "ally_extend", target = other} to ask.
function GameState.alliance_info(self: GameState, me: number, other: number): { [string]: any }?
	if not self:has_alliance(me, other) then
		return nil
	end
	local key = math.min(me, other) * 1024 + math.max(me, other)
	local expires = self.alliance_expires[key] or -1
	local bits = self.alliance_ext[key] or 0
	local mine = if me < other then 1 else 2
	local me_asked = bit32.band(bits, mine) ~= 0
	local other_asked = bit32.band(bits, 3 - mine) ~= 0
	local in_window = expires >= 0 and expires <= self.tick + Rules.ALLIANCE_EXTEND_WINDOW_TICKS
	local a, b = self.owners[me], self.owners[other]
	local alive = a ~= nil and a.alive and b ~= nil and b.alive
	return {
		expires_at = expires,
		ticks_left = math.max(0, expires - self.tick),
		in_window = in_window,
		me_asked = me_asked,
		other_asked = other_asked,
		can_extend = in_window and alive and not me_asked,
	}
end

--- Ticks until `from` may send `to` a new alliance request (the Sim's request cooldown is
--- counted from when the previous request was made; the mirror only knows requests it saw).
function GameState.request_cooldown_left(self: GameState, from: number, to: number): number
	local last = self._req_last[from * 1024 + to]
	if last == nil then
		return 0
	end
	return math.max(0, last + Rules.ALLY_REQUEST_COOLDOWN_TICKS - self.tick)
end

--- Allies of `id` (1-based array) in alliance formation order.
function GameState.allies_of(self: GameState, id: number): { number }
	local keys = {}
	for key in self.alliances do
		if key // 1024 == id or key % 1024 == id then
			table.insert(keys, key)
		end
	end
	local seq = self._ally_seq
	table.sort(keys, function(x, y)
		return (seq[x] or 0) < (seq[y] or 0)
	end)
	local out = {}
	for _, key in keys do
		local a = key // 1024
		table.insert(out, if a == id then key % 1024 else a)
	end
	return out
end

function GameState._set_alliance(self: GameState, a: number, b: number, on: boolean)
	local key = math.min(a, b) * 1024 + math.max(a, b)
	if on then
		if not self.alliances[key] then
			self._seq += 1
			self._ally_seq[key] = self._seq
		end
		self.alliances[key] = true
	else
		self.alliances[key] = nil
		self._ally_seq[key] = nil
		self.alliance_expires[key] = nil
		self.alliance_ext[key] = nil
	end
end

function GameState.is_traitor(self: GameState, id: number): boolean
	local o = self.owners[id]
	return o ~= nil and o.traitor_until > self.tick
end

--- Switches the mirror to another map (clears the grids; a snapshot must follow).
function GameState.set_map(self: GameState, map: any)
	self.map = map
	self.map_id = map.id
	Defs.set_view_map(map)
	self.W = map.W
	self.H = map.H
	self.N = map.N
	self.rules = Rules.for_map(map)
	self.owner = buffer.create(map.N * 4)
	self.flags = buffer.create(map.N)
	self.fallout_count = 0
end

--- Owner id of tile `i` (0 = unowned / out of range).
function GameState.tile_owner(self: GameState, i: number): number
	if i >= 0 and i < self.N then
		return buffer.readi32(self.owner, i * 4)
	end
	return 0
end
GameState.owner_of = GameState.tile_owner

function GameState.tile_flags(self: GameState, i: number): number
	if i >= 0 and i < self.N then
		return buffer.readu8(self.flags, i)
	end
	return 0
end

function GameState.has_fallout(self: GameState, i: number): boolean
	return i >= 0 and i < self.N and bit32.band(buffer.readu8(self.flags, i), F_FALLOUT) ~= 0
end

--- True when `id` owns a tile 4-adjacent to `i` (used for UI hints; the Sim validates for real).
function GameState.borders_tile(self: GameState, id: number, i: number): boolean
	local owner = self.owner
	local W = self.W
	local x = i % W
	if x > 0 and buffer.readi32(owner, (i - 1) * 4) == id then
		return true
	end
	if x < W - 1 and buffer.readi32(owner, (i + 1) * 4) == id then
		return true
	end
	if i >= W and buffer.readi32(owner, (i - W) * 4) == id then
		return true
	end
	if i < self.N - W and buffer.readi32(owner, (i + W) * 4) == id then
		return true
	end
	return false
end

--- Fraction (0..1) of contestable land held by `id`.
function GameState.land_share(self: GameState, id: number): number
	local o = self.owners[id]
	if o == nil or self.map.contestable_count <= 0 then
		return 0.0
	end
	return o.tiles / self.map.contestable_count
end

--- Alive owners holding land, sorted by territory, largest first (ties: lower id first).
function GameState.ranking(self: GameState): { OwnerInfo }
	local list = {}
	for _, o in self.owners do
		if o.alive and o.tiles > 0 then
			table.insert(list, o)
		end
	end
	table.sort(list, function(p, q)
		if p.tiles ~= q.tiles then
			return p.tiles > q.tiles
		end
		return p.id < q.id
	end)
	return list
end

--- Structures of `id` (of `kind`, or all kinds when kind < 0), sorted by sid.
function GameState.structures_of(self: GameState, id: number, kind: number?): { StructInfo }
	local k = kind or -1
	local out = {}
	for _, s in self.structures do
		if s.owner == id and (k < 0 or s.kind == k) then
			table.insert(out, s)
		end
	end
	table.sort(out, function(a, b)
		return a.sid < b.sid
	end)
	return out
end

function GameState.count_structures(self: GameState, id: number, kind: number): number
	local n = 0
	for _, s in self.structures do
		if s.owner == id and s.kind == kind then
			n += 1
		end
	end
	return n
end

--- Sum of the levels of `id`'s structures of `kind` (one under construction counts 1).
function GameState.struct_level_sum(self: GameState, id: number, kind: number): number
	local n = 0
	for _, s in self.structures do
		if s.owner == id and s.kind == kind then
			n += s.level
		end
	end
	return n
end

--- Structures (slot Defs.S_*) or warships (Rules.BUILT_WARSHIP) `id` has built or upgraded.
function GameState.built_count(self: GameState, id: number, slot: number): number
	local b = self.built[id]
	if b == nil then
		return 0
	end
	return b[slot] or 0
end

function GameState._count_built(self: GameState, id: number, slot: number, n: number?)
	local b = self.built[id]
	if b == nil then
		b = {}
		for k = 0, Rules.BUILT_SLOTS - 1 do
			b[k] = 0
		end
		self.built[id] = b
	end
	if slot >= 0 and slot < Rules.BUILT_SLOTS then
		b[slot] += n or 1
	end
end

function GameState.count_units(self: GameState, id: number, kind: number): number
	local n = 0
	for _, u in self.units do
		if u.owner == id and u.kind == kind then
			n += 1
		end
	end
	return n
end

--- Map-space centre of tile `i` as numbers: x + 0.5, y + 0.5, 0.
function GameState.tile_dir_xyz(self: any, i: number): (number, number, number)
	local W = self.W
	local x = i % W
	return x + 0.5, (i - x) // W + 0.5, 0.0
end
local tile_dir_xyz = GameState.tile_dir_xyz

--- Map-space centre of tile `i` (x, y in tiles) as two numbers.
function GameState.tile_xy(self: any, i: number): (number, number)
	local W = self.W
	local x = i % W
	return x + 0.5, (i - x) // W + 0.5
end

--- Map-space centre of tile `i` as a Vector3 (z = 0).
function GameState.tile_dir(self: any, i: number): Vector3
	local x, y, z = tile_dir_xyz(self, i)
	return Vector3.new(x, y, z)
end

-- Straight-line interpolation (map space), as numbers.
local function lerp_xyz(ax: number, ay: number, az: number, bx: number, by: number, bz: number, w: number)
	return ax + (bx - ax) * w, ay + (by - ay) * w, az + (bz - az) * w
end
GameState.lerp_xyz = lerp_xyz

local function normalize(x: number, y: number, z: number): (number, number, number)
	local l = math.sqrt(x * x + y * y + z * z)
	if l > 0 then
		return x / l, y / l, z / l
	end
	return 0, 0, 0
end

local function clamp01(v: number): number
	if v < 0 then
		return 0
	elseif v > 1 then
		return 1
	end
	return v
end

--- Map-space position of a moving unit at `at_tick` (fractional), plus its unit heading, as
--- numbers: px, py, pz (0), fx, fy, fz (0), progress (0..1).
function GameState.unit_pose_xyz(
	self: GameState,
	u: UnitInfo,
	at_tick: number
): (number, number, number, number, number, number, number)
	local path = u.path
	local n = #path
	if (u.kind == Defs.U_WARSHIP and u.prev_tile >= 0) or n < 2 then
		local cx, cy, cz = tile_dir_xyz(self, if n > 0 then path[1] else 0)
		if u.kind == Defs.U_WARSHIP and u.prev_tile >= 0 then
			local f = clamp01((at_tick - u.move_tick) / Defs.TICK_RATE)
			local ax, ay, az = tile_dir_xyz(self, u.prev_tile)
			local px, py, pz = lerp_xyz(ax, ay, az, cx, cy, cz, f)
			local dx, dy, dz = cx - ax, cy - ay, cz - az
			if dx * dx + dy * dy + dz * dz > 1e-12 then
				dx, dy, dz = normalize(dx, dy, dz)
			else
				dx, dy, dz = 0, 0, 0
			end
			return px, py, pz, dx, dy, dz, f
		end
		return cx, cy, cz, 0, 0, 0, 1.0
	end
	local tiles_done = math.max(0.0, (at_tick - u.start_tick) * 100.0 / math.max(u.ticks_per_tile_x100, 1))
	local last = n - 1
	local seg = math.min(Defs.trunc(tiles_done), last - 1)
	local frac = clamp01(tiles_done - seg)
	local ax, ay, az = tile_dir_xyz(self, path[seg + 1])
	local bx, by, bz = tile_dir_xyz(self, path[seg + 2])
	local px, py, pz = lerp_xyz(ax, ay, az, bx, by, bz, frac)
	local fx, fy, fz = normalize(bx - ax, by - ay, bz - az)
	return px, py, pz, fx, fy, fz, clamp01(tiles_done / last)
end

--- Map-space position (Vector3), forward (Vector3) and progress (0..1) of a moving unit at
--- `at_tick`. (GDScript returned [position, forward, progress].)
function GameState.unit_pose(self: GameState, u: UnitInfo, at_tick: number): (Vector3, Vector3, number)
	local px, py, pz, fx, fy, fz, p = self:unit_pose_xyz(u, at_tick)
	return Vector3.new(px, py, pz), Vector3.new(fx, fy, fz), p
end

--- Map-space ground position (x, y), height above the map (z, tiles: a parabola peaking at
--- 4 + 0.35 x the flight distance) and progress 0..1 of a nuke in flight.
function GameState.nuke_pose_xyz(self: GameState, n: NukeInfo, at_tick: number): (number, number, number, number)
	local t = clamp01((at_tick - n.launch_tick) / math.max(n.flight_ticks, 1))
	local ax, ay = self:tile_xy(n.from_tile)
	local bx, by = self:tile_xy(n.to_tile)
	local dx = bx - ax
	local dy = by - ay
	local height = 4.0 + math.sqrt(dx * dx + dy * dy) * 0.35
	return ax + dx * t, ay + dy * t, height * 4.0 * t * (1.0 - t), t
end

--- Map-space position (Vector3; z = height) and progress 0..1 of a nuke in flight.
function GameState.nuke_pose(self: GameState, n: NukeInfo, at_tick: number): (Vector3, number)
	local x, y, z, t = self:nuke_pose_xyz(n, at_tick)
	return Vector3.new(x, y, z), t
end

--- A tile inside `id`'s territory near its centre of mass; cached, refreshed on demand (-1 if none).
function GameState.label_tile(self: GameState, id: number): number
	local o = self.owners[id]
	if o == nil or o.tiles <= 0 then
		return -1
	end
	local owner = self.owner
	local W = self.W
	local H = self.H
	local guess = o.spawn_tile
	if o.tiles > 0 then
		local gx0 = math.clamp(math.floor(o.cx / o.tiles + 0.5), 0, W - 1)
		local gy0 = math.clamp(math.floor(o.cy / o.tiles + 0.5), 0, H - 1)
		guess = gy0 * W + gx0
	end
	if guess >= 0 and buffer.readi32(owner, guess * 4) == id then
		o.label_tile = guess
		return guess
	end
	if o.label_tile >= 0 and buffer.readi32(owner, o.label_tile * 4) == id then
		return o.label_tile
	end
	-- Spiral outward (bounded) from the guess.
	if guess >= 0 then
		local gx = guess % W
		local gy = guess // W
		for r = 1, 47 do
			for dx = -r, r do
				for k = 0, 1 do
					local yy = gy + (if k == 0 then -r else r)
					local xx = gx + dx
					if yy < 0 or yy >= H or xx < 0 or xx >= W then
						continue
					end
					local t = yy * W + xx
					if buffer.readi32(owner, t * 4) == id then
						o.label_tile = t
						return t
					end
				end
			end
			for dy = -r + 1, r - 1 do
				for k = 0, 1 do
					local yy2 = gy + dy
					local xx2 = gx + (if k == 0 then -r else r)
					if yy2 < 0 or yy2 >= H or xx2 < 0 or xx2 >= W then
						continue
					end
					local t2 = yy2 * W + xx2
					if buffer.readi32(owner, t2 * 4) == id then
						o.label_tile = t2
						return t2
					end
				end
			end
		end
	end
	o.label_tile = if o.spawn_tile >= 0 and buffer.readi32(owner, o.spawn_tile * 4) == id then o.spawn_tile else -1
	return o.label_tile
end

-- ---------------------------------------------------------------------------------------------
-- Snapshot / delta application
-- ---------------------------------------------------------------------------------------------

local function clear(t: { [any]: any })
	table.clear(t)
end

--- Loads a Sim.snapshot() table (see READY-core-api for its shape). Fires snapshot_loaded. A
--- snapshot of another map (snap.map_id) switches the mirror to that map (WorldMap.get: the map's
--- data must be available — clients fetch it with MapFetch first).
function GameState.load_snapshot(self: GameState, snap: { [string]: any })
	local mid = snap.map_id
	if type(mid) == "string" and mid ~= "" and mid ~= self.map_id then
		self:set_map(WorldMap.get(mid))
	end
	local N = self.N
	self.tick = snap.t or 0
	self.render_tick = self.tick
	self.phase = snap.phase or Defs.PHASE_SPAWN
	self.phase_ticks_left = snap.phase_left or 0
	self.time_limit_ticks = snap.time_limit_ticks or 0
	self.playing_since = snap.playing_since or -1
	self.mirvs_launched = snap.mirvs_launched or 0
	clear(self.built)
	for _, row in snap.built or {} do
		local b = {}
		for k = 0, Rules.BUILT_SLOTS - 1 do
			b[k] = row[k + 2] or 0
		end
		self.built[row[1]] = b
	end
	self.winner = snap.winner or 0
	self.over_reason = snap.over_reason or -1
	self.team_names = if type(snap.teams) == "table" then snap.teams else {}
	self.winner_team = tonumber(snap.winner_team) or 0
	clear(self.owners)
	clear(self.structures)
	clear(self.roads)
	clear(self.units)
	clear(self.nukes)
	clear(self.reinforce_ready)
	clear(self.shells)
	clear(self.sam_missiles)
	clear(self.attacks)
	clear(self.alliances)
	clear(self._ally_seq)
	clear(self.alliance_expires)
	clear(self.alliance_ext)
	clear(self.requests)
	clear(self._req_last)

	local grid = snap.owner
	if typeof(grid) == "buffer" and buffer.len(grid) == N * 4 then
		local b = buffer.create(N * 4)
		buffer.copy(b, 0, grid, 0, N * 4)
		self.owner = b
	else
		self.owner = buffer.create(N * 4)
	end
	local fl = snap.flags
	if typeof(fl) == "buffer" and buffer.len(fl) == N then
		local b = buffer.create(N)
		buffer.copy(b, 0, fl, 0, N)
		self.flags = b
	else
		self.flags = buffer.create(N)
	end
	local fc = 0
	local flags = self.flags
	for i = 0, N - 1 do
		if i % 65536 == 0 then
			Coop.check()
		end
		if buffer.readu8(flags, i) == F_FALLOUT then
			fc += 1
		end
	end
	self.fallout_count = fc

	for _, row in snap.owners or {} do
		local o = new_owner_info(row[1])
		o.name = tostring(row[2])
		o.rgba = row[3]
		o.color = Defs.color_from_int(row[3])
		o.kind = row[4]
		o.team = tonumber(row[5]) or 0
		o.alive = row[6] == true
		o.troops = row[8]
		o.gold = row[9]
		o.max_troops = row[10]
		o.income = row[11]
		o.traitor_until = row[12]
		o.spawn_tile = row[13]
		o.spawned = o.spawn_tile >= 0
		self.owners[o.id] = o
	end
	self:_recount_tiles()

	Coop.check()
	for _, row in snap.structs or {} do
		self:_add_struct(row[1], row[2], row[3], row[4])
		if #row >= 6 then
			local si = self.structures[row[1]]
			si.level = row[5]
			si.active_tick = row[6]
			if type(row[7]) == "table" then
				si.shots = row[7]
			end
		end
	end
	for _, row in snap.roads or {} do
		self:_add_road(row[1], row[2], row[3], row[4])
	end
	for _, row in snap.units or {} do
		self:_add_unit(row, 0)
	end
	for _, row in snap.nukes or {} do
		self:_add_nuke(row, 0)
	end
	for _, row in snap.shells or {} do
		self:_add_shell(row, 0)
	end
	for _, row in snap.sam_missiles or {} do
		self:_add_sam_missile(row, 0)
	end
	for _, row in snap.attacks or {} do
		self:_set_attack(row, 0)
	end
	for _, row in snap.allies or {} do
		self:_set_alliance(row[1], row[2], true)
		local key = math.min(row[1], row[2]) * 1024 + math.max(row[1], row[2])
		self.alliance_expires[key] = row[3]
		self.alliance_ext[key] = row[4] or 0
	end
	for _, row in snap.requests or {} do
		self.requests[row[1] * 1024 + row[2]] = row[3] or self.tick
	end
	self.loaded = true
	self.snapshot_loaded:Fire()
end

local HANDLERS: { [number]: (GameState, { any }) -> () } = {}

--- Applies one Sim.step() delta table {t, tiles, flags, stats?, ev}. Fires the signals.
function GameState.apply_delta(self: GameState, delta: { [string]: any })
	self.tick = delta.t or (self.tick + 1)
	local tiles = delta.tiles
	if tiles ~= nil and #tiles > 0 then
		self.tiles_changed:Fire(tiles, self:_apply_tiles(tiles))
	end
	local fl = delta.flags
	if fl ~= nil and #fl > 0 then
		local flags = self.flags
		local fc = self.fallout_count
		for _, v in fl do
			local fi = v // 256
			local was = bit32.band(buffer.readu8(flags, fi), F_FALLOUT) ~= 0
			buffer.writeu8(flags, fi, v % 256)
			local now = bit32.band(v, F_FALLOUT) ~= 0
			if was ~= now then
				fc += if now then 1 else -1
			end
		end
		self.fallout_count = fc
		self.flags_changed:Fire(fl)
	end
	local stats = delta.stats
	if stats ~= nil and #stats > 0 then
		self:_apply_stats(stats)
	end
	table.clear(self._removed_now)
	local evs = delta.ev
	if evs ~= nil then
		for _, e in evs do
			local h = HANDLERS[e[1]]
			if h ~= nil then
				h(self, e)
			end
		end
	end
	if next(self.shells) ~= nil then
		local landed = {}
		for id, sh in self.shells do
			if sh.impact_tick <= self.tick then
				table.insert(landed, id)
			end
		end
		if #landed > 0 then
			table.sort(landed)
			for _, id in landed do
				local sh = self.shells[id]
				self.shells[id] = nil
				local hit = sh.damage > 0
					and (self.units[sh.target_uid] ~= nil or self._removed_now[sh.target_uid] == Defs.DEL_DESTROYED)
				self.shell_impact:Fire(id, hit)
			end
		end
	end
	self.ticked:Fire(self.tick)
end

--- Applies one event array (e[1] = Ev id). Normally called by apply_delta.
function GameState._apply_event(self: GameState, e: { any })
	local h = HANDLERS[e[1]]
	if h ~= nil then
		h(self, e)
	end
end

--- Returns the owners the tiles had, in the order of `tiles` (one list, reused by the next call:
--- the map's surface repaints only the neighbours whose look depends on the old or the new owner).
function GameState._apply_tiles(self: GameState, tiles: { number }): { number }
	local owner = self.owner
	local owners = self.owners
	local W = self.W
	local olds = (self :: any)._tiles_old
	if olds == nil then
		olds = {}
		;(self :: any)._tiles_old = olds
	end
	for k = #tiles + 1, #olds do
		olds[k] = nil
	end
	for k, v in tiles do
		local i = v // 1024
		local nw = v % 1024
		local old = buffer.readi32(owner, i * 4)
		olds[k] = old
		if old == nw then
			continue
		end
		buffer.writei32(owner, i * 4, nw)
		local x = i % W
		local y = (i - x) // W
		local po = owners[old]
		if po ~= nil then
			po.tiles -= 1
			po.cx -= x
			po.cy -= y
		end
		local no = owners[nw]
		if no ~= nil then
			no.tiles += 1
			no.cx += x
			no.cy += y
		end
	end
	return olds
end

function GameState._apply_stats(self: GameState, stats: { number })
	local owners = self.owners
	local n = #stats // 6
	for k = 0, n - 1 do
		local b = k * 6
		local o = owners[stats[b + 1]]
		if o == nil then
			continue
		end
		o.troops = stats[b + 3]
		o.gold = stats[b + 4]
		o.max_troops = stats[b + 5]
		o.income = stats[b + 6]
	end
	self.stats_changed:Fire()
end

HANDLERS[Ev.OWNER_ADD] = function(self, e)
	-- Idempotent: a late joiner's snapshot may already contain this owner.
	local o = self.owners[e[2]]
	if o == nil then
		o = new_owner_info(e[2])
		self.owners[o.id] = o
	end
	o.name = tostring(e[3])
	o.rgba = e[4]
	o.color = Defs.color_from_int(e[4])
	o.kind = e[5]
	o.team = tonumber(e[6]) or 0
	o.alive = true -- a re-sent OWNER_ADD also revives an owner (join → leave → join)
	self.owner_added:Fire(o.id)
end

HANDLERS[Ev.OWNER_OUT] = function(self, e)
	local o = self.owners[e[2]]
	if o ~= nil then
		o.alive = false
		o.killer = e[3]
	end
	self.owner_eliminated:Fire(e[2], e[3])
end

HANDLERS[Ev.CONQUEST] = function(self, e)
	self.conquest:Fire(e[2], e[3], e[4])
end

HANDLERS[Ev.BONUS] = function(self, e)
	self.bonus:Fire(e[2], e[3], e[4])
end

--- The Arsenal's Reinforcements arrived for owner e[2]: when its next call is ready.
HANDLERS[Ev.REINFORCE] = function(self, e)
	self.reinforce_ready[e[2]] = e[4]
	self.reinforced:Fire(e[2], e[3], e[4])
end

HANDLERS[Ev.PHASE] = function(self, e)
	self.phase = e[2]
	if self.phase == Defs.PHASE_PLAYING and self.playing_since < 0 then
		self.playing_since = self.tick
	end
	self.phase_ticks_left = e[3]
	self.phase_changed:Fire(self.phase, self.phase_ticks_left)
end

HANDLERS[Ev.SPAWNED] = function(self, e)
	local o = self.owners[e[2]]
	if o ~= nil then
		o.spawned = true
		o.spawn_tile = e[3]
		o.label_tile = e[3]
	end
	self.owner_spawned:Fire(e[2], e[3])
end

HANDLERS[Ev.STRUCT_ADD] = function(self, e)
	self:_add_struct(e[2], e[3], e[4], e[5])
	self:_count_built(e[4], e[3])
	self.structure_added:Fire(e[2])
end

HANDLERS[Ev.STRUCT_LEVEL] = function(self, e)
	local sl = self.structures[e[2]]
	if sl ~= nil then
		if e[3] > sl.level then
			self:_count_built(sl.owner, sl.kind, e[3] - sl.level)
		end
		sl.level = e[3]
		sl.active_tick = e[4]
		self.structure_leveled:Fire(sl.sid)
	end
end

HANDLERS[Ev.STRUCT_SHOTS] = function(self, e)
	local s = self.structures[e[2]]
	if s ~= nil and type(e[3]) == "table" then
		s.shots = e[3]
		self.structure_leveled:Fire(s.sid) -- (views redraw its reload bar)
	end
end

HANDLERS[Ev.STRUCT_OWNER] = function(self, e)
	local s = self.structures[e[2]]
	if s ~= nil then
		local old_owner = s.owner
		s.owner = e[3]
		self.structure_changed:Fire(s.sid, old_owner)
	end
end

HANDLERS[Ev.STRUCT_DEL] = function(self, e)
	if self.structures[e[2]] ~= nil then
		self.structure_removed:Fire(e[2])
		self.structures[e[2]] = nil
	end
end

HANDLERS[Ev.ROAD_ADD] = function(self, e)
	self:_add_road(e[2], e[3], e[4], e[5])
	self.road_added:Fire(e[2])
end

HANDLERS[Ev.ROAD_DEL] = function(self, e)
	if self.roads[e[2]] ~= nil then
		self.road_removed:Fire(e[2])
		self.roads[e[2]] = nil
	end
end

HANDLERS[Ev.UNIT_ADD] = function(self, e)
	self:_add_unit(e, 1)
	if e[3] == Defs.U_WARSHIP then
		self:_count_built(e[4], Rules.BUILT_WARSHIP)
	end
	self.unit_added:Fire(e[2])
end

HANDLERS[Ev.UNIT_MOVE] = function(self, e)
	local u = self.units[e[2]]
	if u ~= nil then
		u.prev_tile = if #u.path > 0 then u.path[1] else e[3]
		u.path = { e[3] }
		u.move_tick = self.tick
		self.unit_moved:Fire(u.uid)
	end
end

HANDLERS[Ev.SHELL] = function(self, e)
	self:_add_shell(e, 1)
	self.shell_fired:Fire(e[2])
end

HANDLERS[Ev.SAM_LAUNCH] = function(self, e)
	self:_add_sam_missile(e, 1)
	self.sam_launched:Fire(e[3])
end

HANDLERS[Ev.UNIT_HP] = function(self, e)
	local u = self.units[e[2]]
	if u ~= nil then
		u.hp = e[3]
		u.max_hp = e[4]
		self.unit_hp_changed:Fire(u.uid)
	end
end

HANDLERS[Ev.UNIT_VET] = function(self, e)
	local u = self.units[e[2]]
	if u ~= nil then
		u.veterancy = e[3]
		self.unit_veterancy_changed:Fire(u.uid)
	end
end

HANDLERS[Ev.UNIT_STATE] = function(self, e)
	local u = self.units[e[2]]
	if u ~= nil then
		u.state = e[3]
		u.patrol_tile = e[4]
		self.unit_state_changed:Fire(u.uid)
	end
end

HANDLERS[Ev.UNIT_PATH] = function(self, e)
	local u = self.units[e[2]]
	if u ~= nil then
		u.path = table.clone(e[3])
		u.start_tick = e[4]
		u.ticks_per_tile_x100 = e[5]
		u.prev_tile = -1
		u.move_tick = u.start_tick
		self.unit_moved:Fire(u.uid)
	end
end

HANDLERS[Ev.UNIT_DEL] = function(self, e)
	self._removed_now[e[2]] = e[3]
	if self.units[e[2]] ~= nil then
		self.unit_removed:Fire(e[2], e[3])
		self.units[e[2]] = nil
	end
end

HANDLERS[Ev.NUKE] = function(self, e)
	if e[3] == Defs.N_MIRV then
		self.mirvs_launched += 1
	end
	self:_add_nuke(e, 1)
	self.nuke_launched:Fire(e[2])
end

HANDLERS[Ev.BOOM] = function(self, e)
	self.nuke_detonated:Fire(e[2], e[3], e[4], e[5], e[6])
	self.nukes[e[2]] = nil
	self.sam_missiles[e[2]] = nil
end

HANDLERS[Ev.ATTACK] = function(self, e)
	local existed = self.attacks[e[2]] ~= nil
	self:_set_attack(e, 1)
	if existed then
		self.attack_updated:Fire(e[2])
	else
		self.attack_started:Fire(e[2])
	end
end

HANDLERS[Ev.ATTACK_END] = function(self, e)
	if self.attacks[e[2]] ~= nil then
		self.attack_ended:Fire(e[2])
		self.attacks[e[2]] = nil
	end
end

HANDLERS[Ev.ALLY_REQ] = function(self, e)
	self.requests[e[2] * 1024 + e[3]] = e[4] or self.tick
	self.alliance_requested:Fire(e[2], e[3])
end

--- Drops request `k`, remembering when it was made (request_cooldown_left).
local function forget_request(self, k: number)
	local made = self.requests[k]
	if made ~= nil then
		self._req_last[k] = made
		self.requests[k] = nil
	end
end

HANDLERS[Ev.ALLY_REQ_END] = function(self, e)
	forget_request(self, e[2] * 1024 + e[3])
	self.alliance_request_closed:Fire(e[2], e[3])
end

HANDLERS[Ev.ALLY] = function(self, e)
	local a, b = e[2], e[3]
	self:_set_alliance(a, b, true)
	local key = math.min(a, b) * 1024 + math.max(a, b)
	self.alliance_expires[key] = e[4] or (self.tick + Rules.ALLIANCE_TICKS)
	self.alliance_ext[key] = 0
	forget_request(self, a * 1024 + b)
	forget_request(self, b * 1024 + a)
	self.alliance_changed:Fire(a, b, true, 0, false)
end

HANDLERS[Ev.ALLY_END] = function(self, e)
	local a, b = e[2], e[3]
	self:_set_alliance(a, b, false)
	self.alliance_changed:Fire(a, b, false, e[4], e[5] == true)
end

HANDLERS[Ev.ALLY_EXT] = function(self, e)
	local a, b = e[2], e[3]
	local key = math.min(a, b) * 1024 + math.max(a, b)
	if self.alliances[key] then
		self.alliance_expires[key] = e[4]
		self.alliance_ext[key] = e[5] or 0
	end
	self.alliance_extension:Fire(a, b, e[4], e[5] or 0)
end

HANDLERS[Ev.TRAITOR] = function(self, e)
	local o = self.owners[e[2]]
	if o ~= nil then
		o.traitor_until = e[3]
	end
	self.traitor_marked:Fire(e[2], e[3])
end

HANDLERS[Ev.MSG] = function(self, e)
	local to = e[2]
	if to == -1 or to == self.local_owner then
		self.message:Fire(to, e[3], tostring(e[4]))
	end
end

HANDLERS[Ev.GAME_OVER] = function(self, e)
	self.winner = e[2]
	self.over_reason = e[3]
	self.winner_team = tonumber(e[4]) or 0
	self.phase = Defs.PHASE_OVER
	self.game_over:Fire(self.winner, self.over_reason)
end

GameState.HANDLERS = HANDLERS

function GameState._add_struct(self: GameState, sid: number, kind: number, own: number, tile: number)
	self.structures[sid] = { sid = sid, kind = kind, owner = own, tile = tile, level = 1, active_tick = 0 }
end

function GameState._add_road(self: GameState, rid: number, a: number, b: number, tiles: { number }?)
	self.roads[rid] = { rid = rid, a = a, b = b, tiles = if type(tiles) == "table" then tiles else {} }
end

-- The _add_* helpers read their arguments from `args` starting at index o + 1 (o = 0 for
-- snapshot rows, 1 for event arrays whose first element is the Ev id).
function GameState._add_sam_missile(self: GameState, args: { any }, o: number)
	local m = {
		sam_sid = args[o + 1],
		nuke_uid = args[o + 2],
		fire_tick = args[o + 3],
		intercept_tick = args[o + 4],
		will_hit = args[o + 5] == true,
	}
	self.sam_missiles[m.nuke_uid] = m
end

function GameState._add_shell(self: GameState, args: { any }, o: number)
	local sh = {
		id = args[o + 1],
		shooter_kind = args[o + 2],
		shooter_id = args[o + 3],
		from_tile = args[o + 4],
		target_uid = args[o + 5],
		fire_tick = args[o + 6],
		impact_tick = args[o + 7],
		damage = args[o + 8],
	}
	self.shells[sh.id] = sh
end

function GameState._add_unit(self: GameState, args: { any }, o: number)
	local path = args[o + 4]
	local u: UnitInfo = {
		uid = args[o + 1],
		kind = args[o + 2],
		owner = args[o + 3],
		path = if path ~= nil then table.clone(path) else {},
		start_tick = args[o + 5],
		ticks_per_tile_x100 = args[o + 6],
		troops = args[o + 7],
		prev_tile = -1,
		move_tick = args[o + 5],
		hp = 0,
		max_hp = 0,
		veterancy = 0,
		state = 0,
		patrol_tile = -1,
	}
	if #args - o >= 12 then
		u.hp = args[o + 8]
		u.max_hp = args[o + 9]
		u.veterancy = args[o + 10]
		u.state = args[o + 11]
		u.patrol_tile = args[o + 12]
	end
	self.units[u.uid] = u
end

function GameState._add_nuke(self: GameState, args: { any }, o: number)
	local n = {
		uid = args[o + 1],
		kind = args[o + 2],
		owner = args[o + 3],
		from_tile = args[o + 4],
		to_tile = args[o + 5],
		launch_tick = args[o + 6],
		flight_ticks = args[o + 7],
	}
	self.nukes[n.uid] = n
end

function GameState._set_attack(self: GameState, args: { any }, o: number)
	local aid = args[o + 1]
	local at = self.attacks[aid]
	if at == nil then
		at = { aid = aid, attacker = 0, target = 0, troops = 0, anchor_tile = -1, retreating = false }
		self.attacks[aid] = at
	end
	at.attacker = args[o + 2]
	at.target = args[o + 3]
	at.troops = args[o + 4]
	at.anchor_tile = args[o + 5]
	at.retreating = args[o + 6] == true
end

function GameState._recount_tiles(self: GameState)
	local owners = self.owners
	for _, o in owners do
		o.tiles = 0
		o.cx = 0.0
		o.cy = 0.0
		o.cz = 0.0
	end
	local owner = self.owner
	local W = self.W
	for i = 0, self.N - 1 do
		if i % 32768 == 0 then
			Coop.check()
		end
		local id = buffer.readi32(owner, i * 4)
		if id == 0 then
			continue
		end
		local o = owners[id]
		if o ~= nil then
			o.tiles += 1
			local x = i % W
			o.cx += x
			o.cy += (i - x) // W
		end
	end
end

--- Encodes an owner grid for snapshots: a copy of the i32 buffer (Sim.snapshot() uses this).
function GameState.encode_grid(grid: buffer): buffer
	local b = buffer.create(buffer.len(grid))
	buffer.copy(b, 0, grid, 0, buffer.len(grid))
	return b
end

return GameState
