--!native
-- Port of scripts/core/sim_state.gd: base of the Sim class chain
-- (SimState → SimAttacks → SimStructures → SimNaval → SimWarships → SimNukes → Sim), installed as a
-- mixin into the single Sim class table (see Sim.luau / build/notes/sim-core.md).
-- Holds every piece of mutable match state in flat arrays so the hot loops can read and write them
-- directly. Owns tile ownership changes, per-owner border lists, delta/event buffers and diplomacy.
--
-- Representation: per-tile arrays are buffers (owner/struct_at/bnext/bprev: i32 at t*4;
-- flags/def_cover/in_border: u8 at t; land/terr/coast are the map's read-only u8 buffers);
-- per-owner arrays are Luau tables keyed by owner id 0..MAXO-1 (o_scount & co. by
-- id*STRUCT_KINDS+kind); lists are 1-based arrays.
--
-- Geometry: the map's flat grid (no wrap). The instance carries its map's size (self.W / self.H /
-- self.N) and metrics (self.dist2 / range_d2 / geo_manhattan / geo_span / gc_dist, closures from
-- WorldMap — call them without ':'), and its map's scaled rules in self.R (Rules.for_map).
-- Neighbour order everywhere: west, east, north, south (tiles outside the map are skipped).
local Defs = require("./Defs")
local Ev = require("./Ev")
local Rules = require("./Rules")
local Rng = require("./Rng")
local Coop = require("../Net/Coop")

local MAXO = Defs.MAX_OWNERS
local STRUCT_KINDS = 16
local F_FALLOUT = Defs.F_FALLOUT

local readi32 = buffer.readi32
local writei32 = buffer.writei32
local readu8 = buffer.readu8
local writeu8 = buffer.writeu8

local SimState = {}
SimState.MAXO = MAXO
SimState.STRUCT_KINDS = STRUCT_KINDS

--- A table with keys 0..n-1 set to `v` (per-owner arrays; index 0 exists like a Packed array).
local function filled(n: number, v: any): { [number]: any }
	local t = table.create(n, v)
	t[0] = v
	return t
end
SimState.filled = filled

function SimState.pair_key(a: number, b: number): number
	if a < b then
		return a * 1024 + b
	end
	return b * 1024 + a
end
local pair_key = SimState.pair_key

--- "an Atom Bomb", "a City": indefinite article + word.
function SimState.a_an(word: string): string
	if word == "" then
		return word
	end
	local c = string.sub(word, 1, 1)
	if string.find("AEIOUaeiou", c, 1, true) then
		return "an " .. word
	end
	return "a " .. word
end

function SimState.cap_first(text: string): string
	if text == "" then
		return text
	end
	return string.upper(string.sub(text, 1, 1)) .. string.sub(text, 2)
end

-- =============================================================================================
-- Border list primitives (module-level for speed; also installed as methods)
-- =============================================================================================

local function _is_border(self: any, t: number, o: number): boolean
	local land = self.land
	local owner = self.owner
	local W = self.W
	local x = t % W
	local n
	if x > 0 then
		n = t - 1
		if readu8(land, n) == 1 and readi32(owner, n * 4) ~= o then
			return true
		end
	end
	if x < W - 1 then
		n = t + 1
		if readu8(land, n) == 1 and readi32(owner, n * 4) ~= o then
			return true
		end
	end
	if t >= W then
		n = t - W
		if readu8(land, n) == 1 and readi32(owner, n * 4) ~= o then
			return true
		end
	end
	if t < self.N - W then
		n = t + W
		if readu8(land, n) == 1 and readi32(owner, n * 4) ~= o then
			return true
		end
	end
	return false
end

local function _badd(self: any, t: number, o: number)
	writeu8(self.in_border, t, 1)
	local bhead = self.bhead
	local h = bhead[o]
	local bnext = self.bnext
	local bprev = self.bprev
	writei32(bnext, t * 4, h)
	writei32(bprev, t * 4, -1)
	if h ~= -1 then
		writei32(bprev, h * 4, t)
	end
	bhead[o] = t
	self.bcount[o] += 1
end

local function _bremove(self: any, t: number, o: number)
	writeu8(self.in_border, t, 0)
	local bnext = self.bnext
	local bprev = self.bprev
	local p = readi32(bprev, t * 4)
	local nx = readi32(bnext, t * 4)
	if p ~= -1 then
		writei32(bnext, p * 4, nx)
	else
		self.bhead[o] = nx
	end
	if nx ~= -1 then
		writei32(bprev, nx * 4, p)
	end
	self.bcount[o] -= 1
end

local function _cadd(self: any, t: number, o: number)
	local chead = self.chead
	local h = chead[o]
	self.cnext[t] = h
	self.cprev[t] = -1
	if h ~= -1 then
		self.cprev[h] = t
	end
	chead[o] = t
end

local function _cremove(self: any, t: number, o: number)
	local cnext = self.cnext
	local cprev = self.cprev
	local p = cprev[t]
	local nx = cnext[t]
	if p == nil then
		return
	end
	if p ~= -1 then
		cnext[p] = nx
	else
		self.chead[o] = nx
	end
	if nx ~= -1 then
		cprev[nx] = p
	end
	cnext[t] = nil
	cprev[t] = nil
end

local function _touch(self: any, n: number, old: number, nw: number)
	if readu8(self.land, n) == 0 then
		return
	end
	local on = readi32(self.owner, n * 4)
	if on == 0 then
		return
	end
	if on == nw then
		if readu8(self.in_border, n) == 1 and not _is_border(self, n, nw) then
			_bremove(self, n, nw)
		end
	elseif on == old then
		if readu8(self.in_border, n) == 0 then
			_badd(self, n, old)
		end
	end
end

--- Changes the owner of tile `t`, maintaining counts, border lists, deltas and structures.
local function set_owner(self: any, t: number, nw: number)
	local owner = self.owner
	local old = readi32(owner, t * 4)
	if old == nw then
		return
	end
	writei32(owner, t * 4, nw)
	local d_tiles = self.d_tiles
	d_tiles[#d_tiles + 1] = t * 1024 + nw
	local is_coast = readu8(self.coast, t) == 1
	local W = self.W
	local tx = t % W
	local ty = (t - tx) // W
	local o_tiles = self.o_tiles
	if old ~= 0 then
		self.o_cx[old] -= tx
		self.o_cy[old] -= ty
		o_tiles[old] -= 1
		if is_coast then
			self.o_coast[old] -= 1
			_cremove(self, t, old)
		end
		if readu8(self.in_border, t) == 1 then
			_bremove(self, t, old)
		end
		if o_tiles[old] <= 0 then
			local po = self.pending_out
			po[#po + 1] = old
			self.o_killer[old] = nw
		end
	end
	if nw ~= 0 then
		local flags = self.flags
		local f = readu8(flags, t)
		if bit32.band(f, F_FALLOUT) ~= 0 then
			f = bit32.band(f, 0xFE)
			writeu8(flags, t, f)
			local d_flags = self.d_flags
			d_flags[#d_flags + 1] = t * 256 + f
			self.fallout_count -= 1
		end
		self.o_cx[nw] += tx
		self.o_cy[nw] += ty
		o_tiles[nw] += 1
		if is_coast then
			self.o_coast[nw] += 1
			self.o_coast_tile[nw] = t
			_cadd(self, t, nw)
		end
		if _is_border(self, t, nw) then
			_badd(self, t, nw)
		end
	end
	if tx > 0 then
		_touch(self, t - 1, old, nw)
	end
	if tx < W - 1 then
		_touch(self, t + 1, old, nw)
	end
	if t >= W then
		_touch(self, t - W, old, nw)
	end
	if t < self.N - W then
		_touch(self, t + W, old, nw)
	end
	if readi32(self.struct_at, t * 4) ~= 0 then
		self:_struct_tile_changed(t, old, nw)
	end
end

--- True if `id` owns a 4-neighbour of `t`.
local function touches(self: any, t: number, id: number): boolean
	local owner = self.owner
	local W = self.W
	local x = t % W
	if x > 0 and readi32(owner, (t - 1) * 4) == id then
		return true
	end
	if x < W - 1 and readi32(owner, (t + 1) * 4) == id then
		return true
	end
	if t >= W and readi32(owner, (t - W) * 4) == id then
		return true
	end
	if t < self.N - W and readi32(owner, (t + W) * 4) == id then
		return true
	end
	return false
end

SimState.set_owner = set_owner
SimState.touches = touches
SimState._is_border = _is_border
SimState._badd = _badd
SimState._bremove = _bremove
SimState._touch = _touch

-- =============================================================================================
-- Install
-- =============================================================================================

function SimState.install(C: any)
	C.MAXO = MAXO
	C.STRUCT_KINDS = STRUCT_KINDS
	C.pair_key = SimState.pair_key
	C.a_an = SimState.a_an
	C.cap_first = SimState.cap_first

	--- Initialises every SimState member (GDScript declarations + _init_state).
	function C._init_state(self: any, world: any)
		self.map = world
		-- Grid size, metrics (closures: self.range_d2(a, b), no ':') and scaled rules of the map.
		self.W = world.W
		self.H = world.H
		self.N = world.N
		self.dist2 = world.dist2
		self.range_d2 = world.range_d2
		self.geo_manhattan = world.geo_manhattan
		self.geo_span = world.geo_span
		self.gc_dist = world.gc_dist
		self.R = Rules.for_map(world)
		local N = world.N
		if self.rng == nil then
			self.rng = Rng.new(0)
		end
		self.tick = 0
		self.phase = Defs.PHASE_SPAWN
		if self.difficulty == nil then
			self.difficulty = 1
		end
		if self.max_humans == nil then
			self.max_humans = 0
		end
		--- Tick at which PLAYING started (-1 before that).
		self.playing_since = -1
		--- Land tiles carrying fallout (fallout stays until the land is conquered again).
		self.fallout_count = 0
		--- Diagnostics (bench only): troops spent / lost per owner, reset by the reader.
		--- [id*5+0] attacks launched, +1 boats launched, +2 lost defending, +3 lost to nukes, +4 refunded
		self.dbg_flow = filled(MAXO * 5, 0.0)

		-- tiles
		self.owner = buffer.create(N * 4)
		self.flags = buffer.create(N)
		--- 1 for contestable land (the map's buffer, read-only).
		self.land = world.land
		self.terr = world.terrain -- read-only alias (GDScript kept a private copy)
		Coop.check()
		--- Structure id standing on the tile (0 = none).
		self.struct_at = buffer.create(N * 4)
		--- Number of defense posts (any owner) covering the tile.
		self.def_cover = buffer.create(N)

		-- per-owner border lists (intrusive doubly linked lists over tile indices)
		Coop.check()
		self.in_border = buffer.create(N)
		self.bnext = buffer.create(N * 4)
		self.bprev = buffer.create(N * 4)
		self.bhead = filled(MAXO, -1)
		self.bcount = filled(MAXO, 0)

		Coop.check()
		-- owners (indexed by owner id)
		self.owner_total = 0
		self.o_name = filled(MAXO, "")
		self.o_color = filled(MAXO, 0)
		self.o_kind = filled(MAXO, 0)
		self.o_alive = filled(MAXO, 0)
		self.o_spawned = filled(MAXO, 0)
		--- 1 when the AI drives this owner (nations and tribes).
		self.o_ai = filled(MAXO, 0)
		--- 1 = a bot player: an AI commander that plays (and looks) like a human (public-match fill)
		self.o_bot = filled(MAXO, 0)
		--- Team games (Core/Teams): the owner's team, 1..#team_names; 0 = none (every owner outside a
		--- team game, and tribes in one). Sent as OWNER_ADD's last field.
		self.o_team = filled(MAXO, 0)
		--- Per-owner AI difficulty (-1: the match's). Novice bot players play at 0 with Easy nation
		--- troop numbers; see Sim.ai_difficulty / Sim.add_bot_players.
		self.o_skill = filled(MAXO, -1)
		--- 1 for humans that left the match (their nation stays, passive).
		self.o_left = filled(MAXO, 0)
		self.o_tiles = filled(MAXO, 0)
		self.o_troops = filled(MAXO, 0.0)
		self.o_gold = filled(MAXO, 0.0)
		self.o_cap = filled(MAXO, 0.0)
		--- Passive income per second.
		self.o_income = filled(MAXO, 0.0)
		--- Smoothed per-second income from trade ships and trucks.
		self.o_bonus_rate = filled(MAXO, 0.0)
		self.o_bonus_acc = filled(MAXO, 0.0)
		self.o_traitor_until = filled(MAXO, 0)
		self.o_spawn_tile = filled(MAXO, -1)
		self.o_killer = filled(MAXO, 0)
		--- Owners whose conquest (Ev.CONQUEST, Sim._conquest_gold) was already announced.
		self._conquest_sent = {} :: { [number]: boolean }
		--- Structure counts: o_scount[id * STRUCT_KINDS + kind].
		self.o_scount = filled(MAXO * STRUCT_KINDS, 0)
		--- Level sums of owned structures (one under construction counts 1) and of finished ones only.
		self.o_slevel = filled(MAXO * STRUCT_KINDS, 0)
		self.o_alevel = filled(MAXO * STRUCT_KINDS, 0)
		--- Structures built + levels added per owner (see cost_count); slot
		--- Rules.BUILT_WARSHIP counts warships.
		self.o_built = filled(MAXO * STRUCT_KINDS, 0)
		self.o_warships = filled(MAXO, 0)
		self.o_boats = filled(MAXO, 0)
		--- Tick of the last attack against this owner (by anyone) — AI threat sensing.
		self.o_attacked_tick = filled(MAXO, -100000)
		--- Owned coastal tiles and the most recently gained one (may be stale; validate before use).
		self.o_coast = filled(MAXO, 0)
		self.o_coast_tile = filled(MAXO, -1)
		--- Every owner's coastal tiles as a linked list (the shore border tiles): head per
		--- owner, next / previous tile keyed by tile (-1 ends the list). See coast_tiles().
		self.chead = filled(MAXO, -1)
		self.cnext = {} :: { [number]: number }
		self.cprev = {} :: { [number]: number }
		self.human_keys = {} :: { [string]: number }
		self.humans = {} :: { number }

		-- diplomacy
		--- key = min*1024+max → true
		self.alliances = {} :: { [number]: boolean }
		--- key = min*1024+max → expiry tick (formed / last renewed + Rules.ALLIANCE_TICKS)
		self.ally_expires = {} :: { [number]: number }
		--- key = min*1024+max → renewal asked: bit 1 by the lower id, bit 2 by the higher id
		self.ally_ext = {} :: { [number]: number }
		self.o_ally_count = filled(MAXO, 0)
		--- key = from*1024+to → tick the request was made
		self.requests = {} :: { [number]: number }
		--- key = from*1024+to → when the last answered or expired request was made
		--- (past outgoing requests, for the request cooldown)
		self.req_last = {} :: { [number]: number }
		--- Insertion sequence numbers of alliances / requests (GDScript Dictionaries iterate in
		--- insertion order: allies_of() and request expiry follow formation / request order).
		self._ally_seq = {} :: { [number]: number }
		self._req_seq = {} :: { [number]: number }
		self._seq = 0
		--- key = a*1024+b → tick until which a is hostile towards b (b attacked or nuked a)
		self.grudge = {} :: { [number]: number }

		-- delta buffers
		self.d_tiles = {} :: { number }
		self.d_flags = {} :: { number }
		self.d_ev = {} :: { { any } }
		self.pending_out = {} :: { number }

		-- border scan results (see scan_border)
		self.sc_list = {} :: { number }
		self.sc_count = filled(MAXO, 0)
		self.sc_tile = filled(MAXO, 0)
		self.sc_neutral = 0
		self.sc_neutral_tile = -1
		--- Unowned fallout land touching the scanned border (one sample tile).
		self.sc_fallout_tile = -1
		self.sc_cursor = filled(MAXO, -1)
		self.coast = world.coastal
		--- Sums of the owned tiles' x and y per owner (territory centroid, maintained by set_owner).
		self.o_cx = filled(MAXO, 0.0)
		self.o_cy = filled(MAXO, 0.0)
	end

	-- =========================================================================================
	-- Events
	-- =========================================================================================

	function C.ev(self: any, e: { any })
		local d = self.d_ev
		d[#d + 1] = e
	end

	--- Queues a MSG event; only emitted for humans (or everyone with to = -1) to keep deltas small.
	function C.msg(self: any, to: number, category: number, text: string)
		if to == -1 or (to > 0 and self.o_kind[to] == Defs.KIND_HUMAN and self.o_left[to] == 0) then
			local d = self.d_ev
			d[#d + 1] = { Ev.MSG, to, category, text }
		end
	end

	--- MSG to every present human except `except_id` (who usually gets a personal message).
	function C.msg_others(self: any, except_id: number, category: number, text: string)
		for _, h in self.humans do
			if h ~= except_id then
				self:msg(h, category, text)
			end
		end
	end

	--- True when world news about owners `a`/`b` (either may be 0) concerns human `h`: it is one of
	--- them, allied or bordering with one of them, or one of them is a top-5 owner.
	function C.news_relevant(self: any, h: number, a: number, b: number, top: { number }): boolean
		for k = 1, 2 do
			local x = if k == 1 then a else b
			if x <= 0 then
				continue
			end
			if x == h or self:allied(h, x) or table.find(top, x) ~= nil or self:borders(h, x) then
				return true
			end
		end
		return false
	end

	--- The (up to) `count` (default 5) owners holding the most land (1-based array).
	function C.top_owners(self: any, count: number?): { number }
		local cnt = count or 5
		local ids = {}
		local vals = {}
		local o_alive = self.o_alive
		local o_tiles = self.o_tiles
		for id = 1, self.owner_total do
			if o_alive[id] == 0 then
				continue
			end
			local v = o_tiles[id]
			local i = #ids
			while i > 0 and vals[i] < v do
				i -= 1
			end
			if i < cnt then
				table.insert(ids, i + 1, id)
				table.insert(vals, i + 1, v)
				if #ids > cnt then
					ids[#ids] = nil
					vals[#vals] = nil
				end
			end
		end
		return ids
	end

	--- True when `a` owns a tile touching land of `b` (walks a's border list).
	function C.borders(self: any, a: number, b: number): boolean
		if a <= 0 or b <= 0 or self.o_tiles[a] <= 0 or self.o_tiles[b] <= 0 then
			return false
		end
		local owner = self.owner
		local bnext = self.bnext
		local W = self.W
		local NW = self.N - W
		local t = self.bhead[a]
		while t ~= -1 do
			local x = t % W
			if x > 0 and readi32(owner, (t - 1) * 4) == b then
				return true
			end
			if x < W - 1 and readi32(owner, (t + 1) * 4) == b then
				return true
			end
			if t >= W and readi32(owner, (t - W) * 4) == b then
				return true
			end
			if t < NW and readi32(owner, (t + W) * 4) == b then
				return true
			end
			t = readi32(bnext, t * 4)
		end
		return false
	end

	function C.is_human(self: any, id: number): boolean
		return id > 0 and self.o_kind[id] == Defs.KIND_HUMAN
	end

	function C.name_of(self: any, id: number): string
		if id <= 0 then
			return "Unclaimed land"
		end
		return self.o_name[id]
	end

	-- =========================================================================================
	-- Owners
	-- =========================================================================================

	function C.add_owner(self: any, p_name: string, color: number, kind: number): number
		if self.owner_total >= MAXO - 1 then
			return 0
		end
		self.owner_total += 1
		local id = self.owner_total
		self.o_name[id] = p_name
		self.o_color[id] = color
		self.o_kind[id] = kind
		self.o_alive[id] = 1
		self.o_ai[id] = if kind ~= Defs.KIND_HUMAN then 1 else 0
		self.o_gold[id] = Rules.START_GOLD
		self:ev({ Ev.OWNER_ADD, id, p_name, color, kind, 0 })
		return id
	end

	--- Changes an owner's colour mid-match (re-sends OWNER_ADD; the mirror updates in place).
	function C.set_owner_color(self: any, id: number, color: number)
		if id <= 0 or id > self.owner_total or self.o_color[id] == color then
			return
		end
		self.o_color[id] = color
		self:ev({ Ev.OWNER_ADD, id, self.o_name[id], color, self.o_kind[id], self.o_team[id] })
	end

	function C.struct_count(self: any, id: number, kind: number): number
		return self.o_scount[id * STRUCT_KINDS + kind]
	end

	function C.is_traitor(self: any, id: number): boolean
		return id > 0 and self.o_traitor_until[id] > self.tick
	end

	function C.land_share(self: any, id: number): number
		return self.o_tiles[id] / math.max(self.map.contestable_count, 1)
	end

	-- =========================================================================================
	-- Tile ownership and border lists
	-- =========================================================================================

	C.set_owner = set_owner
	C.touches = touches
	C._touch = _touch
	C._is_border = _is_border
	C._badd = _badd
	C._bremove = _bremove

	--- Overridden by SimStructures: a structure's tile changed hands.
	function C._struct_tile_changed(_self: any, _t: number, _old: number, _nw: number) end

	--- True when tile `t` is contestable, not fallout and may be claimed.
	function C.claimable(self: any, t: number): boolean
		return readu8(self.land, t) == 1 and bit32.band(readu8(self.flags, t), F_FALLOUT) == 0
	end

	-- =========================================================================================
	-- Border scan (AI perception)
	-- =========================================================================================

	local function _scan_nb(self: any, id: number, n: number)
		if readu8(self.land, n) == 0 then
			return
		end
		local on = readi32(self.owner, n * 4)
		if on == id then
			return
		end
		if on == 0 then
			if bit32.band(readu8(self.flags, n), 1) == 0 then
				self.sc_neutral += 1
				if self.sc_neutral_tile < 0 or bit32.band(self.rng:randi(), 15) == 0 then
					self.sc_neutral_tile = n
				end
			elseif self.sc_fallout_tile < 0 then
				self.sc_fallout_tile = n
			end
			return
		end
		local sc_count = self.sc_count
		if sc_count[on] == 0 then
			local l = self.sc_list
			l[#l + 1] = on
			self.sc_tile[on] = n
		end
		sc_count[on] += 1
	end
	C._scan_nb = _scan_nb

	--- Walks up to `limit` tiles of `id`'s border list (resuming where the previous scan stopped)
	--- and records neighbouring owners in sc_list / sc_count / sc_tile and unclaimed contact in
	--- sc_neutral / sc_neutral_tile (and one fallout contact in sc_fallout_tile).
	function C.scan_border(self: any, id: number, limit: number)
		local sc_count = self.sc_count
		local sc_list = self.sc_list
		for _, o in sc_list do
			sc_count[o] = 0
		end
		table.clear(sc_list)
		self.sc_neutral = 0
		self.sc_neutral_tile = -1
		self.sc_fallout_tile = -1
		local total = self.bcount[id]
		if total <= 0 then
			return
		end
		local owner = self.owner
		local bnext = self.bnext
		local b = self.sc_cursor[id]
		if b < 0 or readi32(owner, b * 4) ~= id or readu8(self.in_border, b) == 0 then
			b = self.bhead[id]
		end
		local steps = math.min(limit, total)
		local W = self.W
		local NW = self.N - W
		for _ = 1, steps do
			if b == -1 then
				b = self.bhead[id]
			end
			local x = b % W
			if x > 0 then
				_scan_nb(self, id, b - 1)
			end
			if x < W - 1 then
				_scan_nb(self, id, b + 1)
			end
			if b >= W then
				_scan_nb(self, id, b - W)
			end
			if b < NW then
				_scan_nb(self, id, b + W)
			end
			b = readi32(bnext, b * 4)
		end
		self.sc_cursor[id] = b
	end

	--- An owned tile at (or as near as possible to) the centre of `id`'s territory; -1 if none.
	function C.centre_tile(self: any, id: number): number
		local n = self.o_tiles[id]
		if n <= 0 then
			return -1
		end
		local owner = self.owner
		local W = self.W
		local H = self.H
		local cx = math.clamp(math.floor(self.o_cx[id] / n + 0.5), 0, W - 1)
		local cy = math.clamp(math.floor(self.o_cy[id] / n + 0.5), 0, H - 1)
		local c = cy * W + cx
		if readi32(owner, c * 4) == id then
			return c
		end
		-- Nearest owned tile on growing square rings (bounded).
		local rmax = math.max(39, math.ceil(40.0 / self.R.K_LIN))
		for r = 1, rmax do
			for dy = -r, r do
				local y = cy + dy
				if y < 0 or y >= H then
					continue
				end
				local step_x = if math.abs(dy) == r then 1 else 2 * r
				local dx = -r
				while dx <= r do
					local x = cx + dx
					if x >= 0 and x < W then
						local t = y * W + x
						if readi32(owner, t * 4) == id then
							return t
						end
					end
					dx += step_x
				end
			end
		end
		return self.bhead[id]
	end

	--- Every coastal tile `id` owns (1-based array, in coast-list order: newest first).
	function C.coast_tiles(self: any, id: number): { number }
		local out = table.create(math.max(self.o_coast[id], 0))
		local cnext = self.cnext
		local c = self.chead[id]
		while c ~= -1 do
			out[#out + 1] = c
			c = cnext[c]
		end
		return out
	end

	--- A coastal tile owned by `id` (-1 if none). Uses the cached tile or scans the coast list.
	function C.own_coast_tile(self: any, id: number): number
		if self.o_coast[id] <= 0 then
			return -1
		end
		local owner = self.owner
		local c = self.o_coast_tile[id]
		if c >= 0 and readi32(owner, c * 4) == id then
			return c
		end
		local map = self.map
		local coast_list = map.coast_list
		for k = 0, map.coast_count - 1 do
			local t = readi32(coast_list, k * 4)
			if readi32(owner, t * 4) == id then
				self.o_coast_tile[id] = t
				return t
			end
		end
		return -1
	end

	-- =========================================================================================
	-- Geometry helpers
	-- =========================================================================================

	--- Every tile (contestable land only when `only_land`, default true) with
	--- range_d2(center, t) <= radius² (1-based array, row by row).
	function C.disk_tiles(self: any, center: number, radius: number, only_land: boolean?): { number }
		local land_only = only_land ~= false
		local land = self.land
		local W = self.W
		local H = self.H
		local out = {}
		local n = 0
		local cx = center % W
		local cy = center // W
		local r = math.ceil(radius)
		local r2 = radius * radius
		for dy = -r, r do
			local y = cy + dy
			if y < 0 or y >= H then
				continue
			end
			local dy2 = dy * dy
			local rem = r2 - dy2
			if rem < 0.0 then
				continue
			end
			local half = math.ceil(math.sqrt(rem)) + 1
			local lo = math.max(-half, -cx)
			local hi = math.min(half, W - 1 - cx)
			local row = y * W + cx
			for dx = lo, hi do
				if dx * dx + dy2 > r2 then
					continue
				end
				local t = row + dx
				if not land_only or readu8(land, t) == 1 then
					n += 1
					out[n] = t
				end
			end
		end
		return out
	end

	-- =========================================================================================
	-- Diplomacy
	-- =========================================================================================

	--- Friendly: allies, and in a team game teammates (a teammate who has left
	--- is not, and may be attacked). Every rule that keeps two owners from fighting asks this.
	function C.allied(self: any, a: number, b: number): boolean
		if a <= 0 or b <= 0 or a == b then
			return false
		end
		if self.alliances[pair_key(a, b)] ~= nil then
			return true
		end
		local t = self.o_team[a]
		return t ~= 0 and t == self.o_team[b] and self.o_left[a] == 0 and self.o_left[b] == 0
	end

	--- An alliance (not a team): what can be renewed, broken or betrayed.
	function C.has_alliance(self: any, a: number, b: number): boolean
		if a <= 0 or b <= 0 or a == b then
			return false
		end
		return self.alliances[pair_key(a, b)] ~= nil
	end

	--- Teammates in a team game (whether present or not).
	function C.same_team(self: any, a: number, b: number): boolean
		local t = self.o_team[a]
		return a ~= b and t ~= 0 and t == self.o_team[b]
	end

	--- `victim` holds a grudge against `offender` for `ticks`.
	function C.add_grudge(self: any, victim: number, offender: number, ticks: number)
		if victim <= 0 or offender <= 0 then
			return
		end
		local k = victim * 1024 + offender
		local until_tick = self.tick + ticks
		local g = self.grudge
		if (g[k] or 0) < until_tick then
			g[k] = until_tick
		end
	end

	--- True when either side has a live grudge against the other (recent attack or nuke).
	function C.hostile(self: any, a: number, b: number): boolean
		if a <= 0 or b <= 0 or a == b then
			return false
		end
		local g = self.grudge
		local t = self.tick
		return (g[a * 1024 + b] or 0) > t or (g[b * 1024 + a] or 0) > t
	end

	function C.grudge_of(self: any, victim: number, offender: number): boolean
		return (self.grudge[victim * 1024 + offender] or 0) > self.tick
	end

	function C.form_alliance(self: any, a: number, b: number)
		if self:has_alliance(a, b) then
			return
		end
		local key = pair_key(a, b)
		self.alliances[key] = true
		-- An alliance expires ALLIANCE_TICKS after it forms.
		self.ally_expires[key] = self.tick + Rules.ALLIANCE_TICKS
		self.ally_ext[key] = 0
		self._seq += 1
		self._ally_seq[key] = self._seq
		self.o_ally_count[a] += 1
		self.o_ally_count[b] += 1
		-- (the mirror clears both requests on ALLY; accepted requests count for the cooldown)
		self:_forget_request(a * 1024 + b)
		self:_forget_request(b * 1024 + a)
		self:ev({ Ev.ALLY, a, b, self.ally_expires[key] })
		self:msg(a, Defs.MSG_ALLIANCE, "You are now allied with " .. self.o_name[b])
		self:msg(b, Defs.MSG_ALLIANCE, "You are now allied with " .. self.o_name[a])
		self:_on_alliance_formed(a, b)
	end

	--- Overridden by SimAttacks to stop fighting between new allies.
	function C._on_alliance_formed(_self: any, _a: number, _b: number) end

	--- Ends the alliance of `a` and `b`: broken by `traitor` (> 0), or ended by an elimination (0), or
	--- `expired` (no traitor, a message to both).
	function C.end_alliance(self: any, a: number, b: number, traitor: number, expired: boolean?)
		local k = pair_key(a, b)
		if self.alliances[k] == nil then
			return
		end
		self.alliances[k] = nil
		self.ally_expires[k] = nil
		self.ally_ext[k] = nil
		self._ally_seq[k] = nil
		self.o_ally_count[a] -= 1
		self.o_ally_count[b] -= 1
		self:ev({ Ev.ALLY_END, a, b, traitor, expired == true })
		if expired then
			self:msg(a, Defs.MSG_INFO, "Your alliance with " .. self.o_name[b] .. " has expired")
			self:msg(b, Defs.MSG_INFO, "Your alliance with " .. self.o_name[a] .. " has expired")
		end
		if traitor > 0 then
			local victim = if traitor == a then b else a
			self.o_traitor_until[traitor] = self.tick + Rules.TRAITOR_TICKS
			self:ev({ Ev.TRAITOR, traitor, self.o_traitor_until[traitor] })
			self:add_grudge(victim, traitor, Rules.HOSTILE_TICKS * 3)
			local o_name = self.o_name
			self:msg(victim, Defs.MSG_BAD, o_name[traitor] .. " betrayed your alliance!")
			self:msg(
				traitor,
				Defs.MSG_ALERT,
				"You broke your alliance with " .. o_name[victim] .. " — you are marked a traitor"
			)
			local top = self:top_owners()
			for _, h in self.humans do
				if h ~= traitor and h ~= victim and self:news_relevant(h, traitor, victim, top) then
					self:msg(h, Defs.MSG_INFO, o_name[traitor] .. " betrayed " .. o_name[victim])
				end
			end
		end
	end

	--- Allies of `id` (1-based array) in alliance formation order (GDScript Dictionary order).
	function C.allies_of(self: any, id: number): { number }
		local out = {}
		if self.o_ally_count[id] <= 0 then
			return out
		end
		local seq = self._ally_seq
		local keys = {}
		for k in self.alliances do
			if k // 1024 == id or k % 1024 == id then
				keys[#keys + 1] = k
			end
		end
		table.sort(keys, function(x, y)
			return seq[x] < seq[y]
		end)
		for _, k in keys do
			local a = k // 1024
			out[#out + 1] = if a == id then k % 1024 else a
		end
		return out
	end

	--- Keys of `tbl` (alliances / requests) in insertion order (GDScript Dictionary iteration).
	function C._ordered_keys(self: any, tbl: { [number]: any }): { number }
		local seq = if tbl == self.alliances then self._ally_seq else self._req_seq
		local keys = {}
		for k in tbl do
			keys[#keys + 1] = k
		end
		table.sort(keys, function(x, y)
			return (seq[x] or 0) < (seq[y] or 0)
		end)
		return keys
	end

	function C.add_request(self: any, from: number, to: number)
		local k = from * 1024 + to
		if self.requests[k] == nil then
			self._seq += 1
			self._req_seq[k] = self._seq
		end
		self.requests[k] = self.tick
		-- No MSG: the UI renders ALLY_REQ itself as an actionable card.
		self:ev({ Ev.ALLY_REQ, from, to, self.tick })
	end

	--- Drops request `k` (from*1024+to), remembering when it was made for the cooldown
	--- (an accepted or rejected request still counts for it).
	function C._forget_request(self: any, k: number): boolean
		local made = self.requests[k]
		if made == nil then
			return false
		end
		self.req_last[k] = made
		self.requests[k] = nil
		self._req_seq[k] = nil
		return true
	end

	function C.close_request(self: any, from: number, to: number)
		if self:_forget_request(from * 1024 + to) then
			self:ev({ Ev.ALLY_REQ_END, from, to })
		end
	end

	--- Ticks until `from` may ask `to` for an alliance again (ALLY_REQUEST_COOLDOWN_TICKS, counted from
	--- when the previous request was made); 0 = now.
	function C.request_cooldown_left(self: any, from: number, to: number): number
		local last = self.req_last[from * 1024 + to]
		if last == nil then
			return 0
		end
		return math.max(0, last + Rules.ALLY_REQUEST_COOLDOWN_TICKS - self.tick)
	end

	--- Tick at which the alliance of `a` and `b` expires (-1: not allied).
	function C.alliance_expires(self: any, a: number, b: number): number
		local e = self.ally_expires[pair_key(a, b)]
		return if e ~= nil then e else -1
	end

	--- True inside the renewal window (expiry <=
	--- now + ALLIANCE_EXTEND_WINDOW_TICKS).
	function C.in_extension_window(self: any, a: number, b: number): boolean
		local e = self.ally_expires[pair_key(a, b)]
		return e ~= nil and e <= self.tick + Rules.ALLIANCE_EXTEND_WINDOW_TICKS
	end

	--- True when `id` asked to renew its alliance with `other`.
	function C.asked_to_extend(self: any, id: number, other: number): boolean
		local bits = self.ally_ext[pair_key(id, other)]
		if bits == nil then
			return false
		end
		return bit32.band(bits, if id < other then 1 else 2) ~= 0
	end

	--- `id` asks to renew its alliance with `other`. Returns "renewed"
	--- when both have now asked (expiresAt = now + ALLIANCE_TICKS, both marks cleared), "asked" when
	--- only `id` has, "" when refused (no alliance, someone is out, outside the renewal window — the
	--- window is a client rule, enforced here too because clients are untrusted — or already
	--- asked).
	function C.extend_alliance(self: any, id: number, other: number): string
		if id <= 0 or other <= 0 or id == other or not self:has_alliance(id, other) then
			return ""
		end
		if self.o_alive[id] == 0 or self.o_alive[other] == 0 then
			return ""
		end
		if not self:in_extension_window(id, other) or self:asked_to_extend(id, other) then
			return ""
		end
		local k = pair_key(id, other)
		local bits = bit32.bor(self.ally_ext[k], if id < other then 1 else 2)
		local o_name = self.o_name
		if bits == 3 then
			self.ally_ext[k] = 0
			self.ally_expires[k] = self.tick + Rules.ALLIANCE_TICKS
			self:ev({ Ev.ALLY_EXT, k // 1024, k % 1024, self.ally_expires[k], 0 })
			self:msg(id, Defs.MSG_ALLIANCE, "Your alliance with " .. o_name[other] .. " was renewed")
			self:msg(other, Defs.MSG_ALLIANCE, "Your alliance with " .. o_name[id] .. " was renewed")
			return "renewed"
		end
		self.ally_ext[k] = bits
		self:ev({ Ev.ALLY_EXT, k // 1024, k % 1024, self.ally_expires[k], bits })
		self:msg(other, Defs.MSG_ALLIANCE, o_name[id] .. " wants to renew your alliance")
		return "asked"
	end

	--- Alliance expiry and the alliance request timeout, every tick
	--- (in formation / request order).
	function C._alliances_tick(self: any)
		local tick = self.tick
		if next(self.alliances) ~= nil then
			local any = false
			for _, e in self.ally_expires do
				if e <= tick then
					any = true
					break
				end
			end
			if any then
				for _, k in self:_ordered_keys(self.alliances) do
					local e = self.ally_expires[k]
					if e ~= nil and e <= tick then
						self:end_alliance(k // 1024, k % 1024, 0, true)
					end
				end
			end
		end
		if next(self.requests) ~= nil then
			local limit = tick - Rules.ALLY_REQUEST_TICKS
			local any = false
			for _, made in self.requests do
				if made < limit then
					any = true
					break
				end
			end
			if any then
				for _, k in self:_ordered_keys(self.requests) do
					local made = self.requests[k]
					if made ~= nil and made < limit then
						local from = k // 1024
						local to = k % 1024
						self:close_request(from, to)
						self:msg(from, Defs.MSG_INFO, self.o_name[to] .. " did not answer your alliance request")
					end
				end
			end
		end
	end

	function C.has_request(self: any, from: number, to: number): boolean
		return self.requests[from * 1024 + to] ~= nil
	end

	--- Credits event income (trade, trucks, captures) and tracks it for the income stat.
	--- `tile`: where it was earned (a bonus event: the "+ 25K" that
	--- rises there on the earner's map). Only a person gets the event: nobody watches an AI's.
	function C.add_bonus_gold(self: any, id: number, amount: number, tile: number?)
		if id <= 0 or self.o_alive[id] == 0 then
			return
		end
		self.o_gold[id] += amount
		self.o_bonus_acc[id] += amount
		if
			tile ~= nil
			and amount > 0
			and self.o_kind[id] == Defs.KIND_HUMAN
			and self.o_ai[id] == 0
			and self.o_left[id] == 0
		then
			self:ev({ Ev.BONUS, id, tile, math.floor(amount + 0.5) })
		end
	end
end

return SimState
