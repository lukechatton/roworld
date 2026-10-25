-- sim-systems: shared fixture for tests/simsys_*.luau (not a test itself).
-- Builds a bare Sim class from SimState (+ SimAttacks when it exists) + the sim-systems mixins,
-- on the "world" map (2000 x 1000, k_lin 1: full-size tiles, the rules' own numbers) but with no nations /
-- tribes, so tests can place owners, land, structures and units deterministically. Also small
-- expect/near helpers and event filters.
--
-- Coordinates: the scenarios were written in tiles of the original 1024 x 512 Earth grid. F.tile /
-- F.claim map such a point onto the World map with one isotropic transform (x' = (x + 0.5) * L - 65,
-- y' = (y + 0.5) * L - 10, L = 2000 / 1024 = Rules.LEGACY_LIN: 92-97 % land/water agreement around the
-- Mediterranean and Central Asia), and radii scale by L — so every distance relation between the
-- scenario's points keeps its meaning under the full-size numbers (which are the old ones x L).
local fs = require("@lune/fs")

local Defs = require("../src/shared/Core/Defs")
local Ev = require("../src/shared/Core/Ev")
local Rng = require("../src/shared/Core/Rng")
local Rules = require("../src/shared/Core/Rules")
local WorldMap = require("../src/shared/Core/WorldMap")
local SimState = require("../src/shared/Core/SimState")
local SimStructures = require("../src/shared/Core/SimStructures")
local SimNaval = require("../src/shared/Core/SimNaval")
local SimWarships = require("../src/shared/Core/SimWarships")
local SimNukes = require("../src/shared/Core/SimNukes")
local SimArsenal = require("../src/shared/Core/SimArsenal")

local HAS_ATTACKS = fs.isFile("src/shared/Core/SimAttacks.luau")
local SimAttacks = if HAS_ATTACKS then require("../src/shared/Core/SimAttacks") :: any else nil

local F = {}
F.Defs = Defs
F.Ev = Ev
F.Rules = Rules
F.HAS_ATTACKS = HAS_ATTACKS
F.MAP_ID = "world"
F.map = WorldMap.get(F.MAP_ID)
F.W = F.map.W
F.H = F.map.H
F.N = F.map.N
--- Our tiles per tile of the original grid (Rules.LEGACY_LIN of the fixture map).
F.L = Rules.for_map(F.map).LEGACY_LIN
F.OX = -65
F.OY = -10

local C = {}
C.__index = C
SimState.install(C)
if SimAttacks then
	SimAttacks.install(C)
else
	-- Minimal stand-ins until sim-core's SimAttacks lands.
	function C:_init_attacks()
		self.attacks = {}
		self.started = {}
	end
	function C:attack_between(_a, _b)
		return nil
	end
	function C:conquer(t, nw, _via)
		self:set_owner(t, nw)
	end
	function C:start_attack(attacker, target, troops, beachhead)
		table.insert(self.started, { attacker, target, troops, beachhead })
		return nil
	end
	function C:_defense_post_covers(_t, _id)
		return false
	end
end
SimStructures.install(C)
SimNaval.install(C)
SimWarships.install(C)
SimNukes.install(C)
SimArsenal.install(C)
-- Sim-level entry points (intent_attack, capitulate, ally_*, donate …) from sim-core's Sim, for
-- the methods the parts above don't define (hooks stay recorded below).
if fs.isFile("src/shared/Core/Sim.luau") then
	local Sim = require("../src/shared/Core/Sim") :: any
	for k, v in Sim do
		if type(v) == "function" and C[k] == nil and k ~= "new" then
			C[k] = v
		end
	end
end
-- Sim-level hooks (sim.gd) recorded for assertions.
function C:_on_transport_sunk(u, killer)
	table.insert(self.hooks, { "sunk", u.uid, killer })
end
function C:_on_trade_captured(victim, captor, t)
	table.insert(self.hooks, { "captured", victim, captor, t })
end
function C:_on_transport_launched(u, tg)
	table.insert(self.hooks, { "launched", u.uid, tg })
end
F.Class = C

--- A bare PLAYING sim on the fixture map.
function F.new_sim(seed: number?): any
	local self = setmetatable({}, C)
	self.rng = Rng.new(seed or 1)
	self.difficulty = 1
	self.max_humans = 1
	self:_init_state(F.map)
	self:_init_attacks()
	self:_init_structures()
	self:_init_naval()
	self:_init_warships()
	self:_init_nukes()
	self:_init_arsenal()
	self.hooks = {}
	self.phase = Defs.PHASE_PLAYING
	self.playing_since = 0
	self.tick = 1
	self.path_budget = 2
	return self
end

--- Adds an owner of `kind` (humans get MSG events) with gold / troops.
function F.owner(sim: any, name: string, kind: number, gold: number?, troops: number?): number
	local id = sim:add_owner(name, 0x808080FF, kind)
	sim.o_spawned[id] = 1
	sim.o_gold[id] = gold or 0
	sim.o_troops[id] = troops or 10000
	if kind == Defs.KIND_HUMAN then
		table.insert(sim.humans, id)
	end
	return id
end

--- The map tile of original-grid point (x, y) (see the header).
function F.tile(x: number, y: number): number
	local tx = math.clamp(math.floor((x + 0.5) * F.L + F.OX), 0, F.W - 1)
	local ty = math.clamp(math.floor((y + 0.5) * F.L + F.OY), 0, F.H - 1)
	return ty * F.W + tx
end

--- A distance of `d` original tiles in map tiles.
function F.d(d: number): number
	return d * F.L
end

--- Claims every land tile within `r` original tiles of original-grid point (x, y) for `id`;
--- returns the centre tile.
function F.claim(sim: any, id: number, x: number, y: number, r: number): number
	local c = F.tile(x, y)
	for _, t in sim:disk_tiles(c, r * F.L, true) do
		sim:set_owner(t, id)
	end
	return c
end

--- Coastal tiles of the map (1-based array).
function F.coast_tiles(): { number }
	local out = {}
	for k = 0, F.map.coast_count - 1 do
		out[k + 1] = F.map:coast_tile(k)
	end
	return out
end

--- Contestable land tiles of the map (1-based array).
function F.land_tiles(): { number }
	local out = {}
	for k = 0, F.map.land_count - 1 do
		out[k + 1] = F.map:land_tile(k)
	end
	return out
end

--- Chebyshev step between two tiles (1 for 4/8-neighbours; never across the map edge).
function F.step(a: number, b: number): number
	local W = F.W
	return math.max(math.abs(a % W - b % W), math.abs(a // W - b // W))
end

--- Advances the tick counter without running the Sim loop (tests call subsystems directly).
function F.advance(sim: any, n: number)
	sim.tick += n
end

--- Events of type `ev_type` in the pending delta (1-based list of event arrays).
function F.events(sim: any, ev_type: number): { { any } }
	local out = {}
	for _, e in sim.d_ev do
		if e[1] == ev_type then
			table.insert(out, e)
		end
	end
	return out
end

function F.msgs(sim: any, to: number?): { string }
	local out = {}
	for _, e in sim.d_ev do
		if e[1] == Ev.MSG and (to == nil or e[2] == to) then
			table.insert(out, e[4])
		end
	end
	return out
end

function F.has_msg(sim: any, text: string, to: number?): boolean
	for _, m in F.msgs(sim, to) do
		if m == text then
			return true
		end
	end
	return false
end

function F.clear(sim: any)
	sim.d_ev = {}
	sim.d_tiles = {}
	sim.d_flags = {}
end

local fails = 0
local total = 0
function F.expect(cond: any, what: string)
	total += 1
	if cond then
		print("  ok   " .. what)
	else
		fails += 1
		print("FAIL " .. what)
	end
end

function F.near(a: number, b: number, eps: number?): boolean
	return math.abs(a - b) <= (eps or 1e-9)
end

function F.finish(name: string)
	print(string.format("%s: %d/%d passed", name, total - fails, total))
	if fails > 0 then
		error(string.format("%s: %d failures", name, fails))
	end
end

return F
