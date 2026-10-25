--!native
-- Port of scripts/core/sim_attacks.gd (mixin, installed after SimState): attacks — troops
-- committed against one target owner (0 = expansion into unclaimed land). The rules run in
-- full-size-tile units (see Rules: one of our tiles is K_AREA full-size tiles, border lengths
-- scale by K_LIN). On unscaled maps (K_LIN = 1) an attack works
-- tile for tile:
--
--   * the queue: a min-priority queue of the target's tiles next to the attacker. _add_neighbors
--     queues each target-owned land neighbour of a tile with priority
--     ticks + (random 0..6 + 10) * (1 - 0.5 n + mag / 2), n = the attacker's neighbours of it
--     counted BEFORE the tile being conquered changes hands, mag = PRIORITY_MAG (plains 1,
--     highland 1.5, mountain 2). 4 x priority is an integer (mag / 2 is a multiple of 1/4), so
--     the queue is a bucket queue keyed by it: same order as a priority heap up to ties.
--   * the attack's border (borderSize, `front`): tiles queued and not yet dequeued.
--   * tick: borderSize = border + random 0..4; a budget of 1; while budget > 0: stop (troops
--     lost) under 1 troop; an empty queue ends the attack and the troops go home; dequeue a tile,
--     drop it from the border, skip it unless it is still the target's and touches the attacker;
--     _add_neighbors(tile); attack logic → budget -= tickFraction, troops -= attackerTroopLoss, the
--     defender loses floor(troops / tiles); conquer; a dead defender (< 100 tiles) is annexed.
--   * init: troops are taken (floored) from the attacker; an opposing attack of the target cancels
--     troops first; an existing attack on the same target is absorbed (its troops join and the
--     queue is rebuilt from the whole border: _seed_from_border); a new attack starts conquering the
--     tick after the order (new attacks are initialised at the end of a tick).
--   * retreat: the attack keeps going for the rest of the order's tick and the
--     next one, then freezes; RETREAT_DELAY_TICKS later the troops come home (-25 % against a
--     player, malusForRetreat).
-- One attack per (attacker, target) pair, so a boat landing joins the running attack on that
-- target; MAX_TILES_PER_TICK caps an attack at ~572 full-size tiles per tick (Luau performance
-- guard).
-- For K_AREA > 1 one of our tiles is taken over one or more ticks (`chew` carries the progress in
-- full-size tiles), so the same land area falls per second on every map.
--
-- Luau: Attack objects are plain tables; `attacks` is a 1-based array in creation order.
-- The conquest queue is a bucket queue: `ring[key % RING]` holds the tiles of keys within RING of
-- each other (1-based stacks; ties pop last-in first), keys further
-- out wait in the sparse `over` (key → stack). The border set is the `fmark` i32 buffer (tile → aid
-- of the attack whose border holds it); a tile in two attacks' borders at once goes to the second
-- attack's `xb` set.
local Defs = require("./Defs")
local Ev = require("./Ev")
local Rules = require("./Rules")
local SimState = require("./SimState")
local Coop = require("../Net/Coop")

local MAXO = Defs.MAX_OWNERS
local F_FALLOUT = Defs.F_FALLOUT
local RING = 256
local RING_MASK = 255
local PRIORITY_BASE = Rules.PRIORITY_BASE
local PRIORITY_RAND = Rules.PRIORITY_RAND

local readi32 = buffer.readi32
local writei32 = buffer.writei32
local readu8 = buffer.readu8

local set_owner = SimState.set_owner
local touches = SimState.touches

local SimAttacks = {}
SimAttacks.RING = RING

--- A new Attack record (GDScript class SimAttacks.Attack).
function SimAttacks.new_attack(): any
	return {
		aid = 0,
		attacker = 0,
		target = 0,
		troops = 0.0,
		--- Full-size tiles already taken of `head`, the tile being conquered (-1: none).
		chew = 0.0,
		head = -1,
		--- borderSize: tiles in the attack's border.
		front = 0,
		--- Border tiles whose fmark belongs to another live attack (tile → true), or nil.
		xb = nil :: { [number]: boolean }?,
		--- The queue: ring buckets (slot → stack), their entry count and key range [qmin, qhi]
		--- (qhi is an upper bound); `over` holds keys outside it (key → stack), `osize` entries
		--- from key `omin` up. A tile may be queued more than once.
		ring = {} :: { [number]: { number } },
		rsize = 0,
		qmin = 0,
		qhi = 0,
		over = nil :: { [number]: { number } }?,
		osize = 0,
		omin = 0,
		last_tile = -1,
		sent_troops = -1,
		started_tick = 0,
		--- Retreat order: frozen from `frozen_from`, troops home at `retreat_at` (0 = no order).
		retreat_at = 0,
		frozen_from = 0,
		--- Troops of a new order on the same target, absorbed at the end of the tick.
		pend = 0.0,
		--- Started while the target was attacking us (a counter-attack, not a declaration of war).
		counter = false,
		dead = false,
	}
end
local new_attack = SimAttacks.new_attack

-- 4 x (1 - 0.5 n + mag / 2) by terrain code * 5 + n (n = attacker-owned neighbours, 0..4).
local PRIORITY_F4: { [number]: number } = {}
for tt = 0, 6 do
	for n = 0, 4 do
		PRIORITY_F4[tt * 5 + n] = 4 - 2 * n + math.floor(2 * Rules.PRIORITY_MAG[tt] + 0.5)
	end
end
SimAttacks.PRIORITY_F4 = PRIORITY_F4

-- =============================================================================================
-- Conquest queue and border set
-- =============================================================================================

--- Entries queued (including duplicates).
local function qsize(a: any): number
	return a.rsize + a.osize
end
SimAttacks.qsize = qsize

--- Queues `t` under `key`.
local function _enqueue(a: any, t: number, key: number)
	local rsize = a.rsize
	local in_ring
	if rsize == 0 then
		in_ring = true
		a.qmin = key
		a.qhi = key
	elseif key < a.qmin then
		in_ring = a.qhi - key < RING
		if in_ring then
			a.qmin = key
		end
	elseif key > a.qhi then
		in_ring = key - a.qmin < RING
		if in_ring then
			a.qhi = key
		end
	else
		in_ring = true
	end
	if in_ring then
		local ring = a.ring
		local slot = bit32.band(key, RING_MASK)
		local b = ring[slot]
		if b == nil then
			ring[slot] = { t }
		else
			b[#b + 1] = t
		end
		a.rsize = rsize + 1
		return
	end
	local over = a.over
	if over == nil then
		over = {}
		a.over = over
	end
	local b = over[key]
	if b == nil then
		over[key] = { t }
	else
		b[#b + 1] = t
	end
	if a.osize == 0 or key < a.omin then
		a.omin = key
	end
	a.osize += 1
end

--- True when `t` is in attack `a`'s border.
local function in_border(self: any, a: any, t: number): boolean
	if readi32(self.fmark, t * 4) == a.aid then
		return true
	end
	local xb = a.xb
	return xb ~= nil and xb[t] == true
end
SimAttacks.in_border = in_border

--- Adds `t` to attack `a`'s border.
local function _border_add(self: any, a: any, t: number)
	local fmark = self.fmark
	local m = readi32(fmark, t * 4)
	local aid = a.aid
	if m == aid then
		return
	end
	if m == 0 or self.attack_by_id[m] == nil then
		writei32(fmark, t * 4, aid)
		a.front += 1
		return
	end
	local xb = a.xb
	if xb == nil then
		xb = {}
		a.xb = xb
	elseif xb[t] then
		return
	end
	xb[t] = true
	a.front += 1
end

--- Drops `t` from attack `a`'s border.
local function _border_remove(self: any, a: any, t: number)
	local fmark = self.fmark
	if readi32(fmark, t * 4) == a.aid then
		writei32(fmark, t * 4, 0)
		a.front -= 1
		return
	end
	local xb = a.xb
	if xb ~= nil and xb[t] then
		xb[t] = nil
		a.front -= 1
	end
end

--- Queues target tile `t` (_add_neighbors' body for one neighbour): priority from the current
--- ownership of its neighbours, added to the attack's border.
local function _push(self: any, a: any, t: number)
	local owner = self.owner
	local at = a.attacker
	local W = self.W
	local x = t % W
	local n = 0
	if x > 0 and readi32(owner, (t - 1) * 4) == at then
		n += 1
	end
	if x < W - 1 and readi32(owner, (t + 1) * 4) == at then
		n += 1
	end
	if t >= W and readi32(owner, (t - W) * 4) == at then
		n += 1
	end
	if t < self.N - W and readi32(owner, (t + W) * 4) == at then
		n += 1
	end
	local key = 4 * self.tick
		+ (PRIORITY_BASE + self.rng:randi() % PRIORITY_RAND) * PRIORITY_F4[readu8(self.terr, t) * 5 + n]
	local rsize = a.rsize
	if rsize > 0 and key >= a.qmin and key <= a.qhi then
		-- (hot path of _enqueue: inside the ring's current key range)
		local ring = a.ring
		local slot = bit32.band(key, RING_MASK)
		local b = ring[slot]
		if b == nil then
			ring[slot] = { t }
		else
			b[#b + 1] = t
		end
		a.rsize = rsize + 1
	else
		_enqueue(a, t, key)
	end
	local fmark = self.fmark
	local m = readi32(fmark, t * 4)
	if m == 0 then
		writei32(fmark, t * 4, a.aid)
		a.front += 1
	elseif m ~= a.aid then
		_border_add(self, a, t)
	end
end

--- Dequeues the lowest-priority tile (without touching the border); -1 if empty.
local function _dequeue(a: any): number
	local rsize = a.rsize
	local osize = a.osize
	if rsize + osize <= 0 then
		return -1
	end
	local k = a.qmin
	local b
	if rsize > 0 then
		local ring = a.ring
		b = ring[bit32.band(k, RING_MASK)]
		while b == nil or #b == 0 do
			k += 1
			b = ring[bit32.band(k, RING_MASK)]
		end
		a.qmin = k
	end
	if osize > 0 and (rsize == 0 or a.omin < k) then
		local over = a.over :: { [number]: { number } }
		local ok = a.omin
		local ob = over[ok]
		while ob == nil do
			ok += 1
			ob = over[ok]
		end
		local n = #ob
		local t = ob[n]
		if n == 1 then
			over[ok] = nil
		else
			ob[n] = nil
		end
		a.omin = ok
		a.osize = osize - 1
		return t
	end
	local n = #b
	local t = b[n]
	b[n] = nil
	a.rsize = rsize - 1
	return t
end

--- Dequeues the lowest-priority tile and drops it from the border; -1 if empty.
local function _pop(self: any, a: any): number
	local t = _dequeue(a)
	if t >= 0 then
		local fmark = self.fmark
		if readi32(fmark, t * 4) == a.aid then
			writei32(fmark, t * 4, 0)
			a.front -= 1
		elseif a.xb ~= nil then
			_border_remove(self, a, t)
		end
	end
	return t
end

--- Queues every target-owned land 4-neighbour of `t`.
local function _add_neighbors(self: any, a: any, t: number)
	local owner = self.owner
	local land = self.land
	local tg = a.target
	local W = self.W
	local x = t % W
	local n
	if t >= W then
		n = t - W
		if readi32(owner, n * 4) == tg and readu8(land, n) == 1 then
			_push(self, a, n)
		end
	end
	if t < self.N - W then
		n = t + W
		if readi32(owner, n * 4) == tg and readu8(land, n) == 1 then
			_push(self, a, n)
		end
	end
	if x > 0 then
		n = t - 1
		if readi32(owner, n * 4) == tg and readu8(land, n) == 1 then
			_push(self, a, n)
		end
	end
	if x < W - 1 then
		n = t + 1
		if readi32(owner, n * 4) == tg and readu8(land, n) == 1 then
			_push(self, a, n)
		end
	end
end

--- Empties the queue and the border set.
local function _clear_queue(self: any, a: any)
	local fmark = self.fmark
	local aid = a.aid
	for _, b in a.ring do
		for i = #b, 1, -1 do
			local t = b[i]
			if readi32(fmark, t * 4) == aid then
				writei32(fmark, t * 4, 0)
			end
			b[i] = nil
		end
	end
	if a.over ~= nil then
		for _, b in a.over do
			for _, t in b do
				if readi32(fmark, t * 4) == aid then
					writei32(fmark, t * 4, 0)
				end
			end
		end
		a.over = nil
	end
	a.rsize = 0
	a.osize = 0
	a.xb = nil
	a.front = 0
	a.head = -1
	a.chew = 0.0
end

--- Clears the queue and the border, then _add_neighbors of every
--- border tile of the attacker. Returns the border size.
local function _seed_from_border(self: any, a: any): number
	_clear_queue(self, a)
	local bnext = self.bnext
	local b = self.bhead[a.attacker]
	while b ~= -1 do
		_add_neighbors(self, a, b)
		b = readi32(bnext, b * 4)
	end
	return a.front
end

--- Transfers tile `t` to `nw`. Attack queues are fed only by the attack that
--- conquers (_add_neighbors). `via` is kept for callers (boat landings pass nil).
local function conquer(self: any, t: number, nw: number, _via: any?)
	set_owner(self, t, nw)
end

SimAttacks._push = _push
SimAttacks._pop = _pop
SimAttacks._dequeue = _dequeue
SimAttacks._enqueue = _enqueue
SimAttacks._add_neighbors = _add_neighbors
SimAttacks._seed_from_border = _seed_from_border
SimAttacks.conquer = conquer

function SimAttacks.install(C: any)
	--- Initialises every SimAttacks member (GDScript declarations + _init_attacks).
	function C._init_attacks(self: any)
		self.attacks = {} :: { any }
		self.attack_by_id = {} :: { [number]: any }
		--- attacker * 1024 + target → aid (0 = none), i32 buffer
		self.pair_attack = buffer.create(MAXO * MAXO * 4)
		Coop.check()
		--- tile -> aid of the attack whose border holds it (0 = none; a dead attack's id is stale),
		--- i32 buffer
		self.fmark = buffer.create(self.N * 4)
		--- Attacks with troops of a new order waiting to be absorbed (1-based).
		self._merges = {} :: { any }
		self.next_aid = 1
		--- attacker*1024+target → tick of the last "is attacking you" alert (throttle).
		self._alert_tick = {} :: { [number]: number }
	end

	function C.attack_between(self: any, attacker: number, target: number): any?
		local aid = readi32(self.pair_attack, (attacker * 1024 + target) * 4)
		if aid ~= 0 then
			return self.attack_by_id[aid]
		end
		return nil
	end

	--- Troops committed in all of `id`'s attacks.
	function C.troops_in_attacks(self: any, id: number): number
		local s = 0.0
		for _, a in self.attacks do
			if not a.dead and a.attacker == id then
				s += a.troops + a.pend
			end
		end
		return s
	end

	function C.count_attacks_by(self: any, id: number, players_only: boolean): number
		local n = 0
		for _, a in self.attacks do
			if not a.dead and a.attacker == id and (not players_only or a.target ~= 0) then
				n += 1
			end
		end
		return n
	end

	-- =========================================================================================
	-- Frontier queue
	-- =========================================================================================

	C._push = _push
	C._pop = _pop
	C._add_neighbors = _add_neighbors
	C._seed_from_border = _seed_from_border

	-- =========================================================================================
	-- Starting / ending
	-- =========================================================================================

	--- Commits `troops` (already removed from the attacker's home troops) against `target`.
	--- `beachhead` >= 0 seeds from that tile only (boat landings). Returns the attack or nil; on
	--- nil the troops have been returned (or spent cancelling an opposing attack).
	function C.start_attack(self: any, attacker: number, target: number, troops: number, beachhead: number?): any?
		local bh = beachhead or -1
		local o_troops = self.o_troops
		if troops < 1.0 then
			o_troops[attacker] += troops
			return nil
		end
		local counter = target ~= 0 and self:attack_between(target, attacker) ~= nil
		-- A new order: an opposing attack between the same pair cancels troops first (the
		-- smaller side is deleted, its troops lost).
		if target ~= 0 then
			local opp = self:attack_between(target, attacker)
			if opp ~= nil then
				local cancel = math.min(troops, opp.troops)
				troops -= cancel
				opp.troops -= cancel
				if opp.troops < 1.0 then
					self:end_attack(opp, false)
				end
				if troops < 1.0 then
					return nil
				end
			end
		end
		local a = self:attack_between(attacker, target)
		if a ~= nil then
			if bh >= 0 then
				-- A boat landing joins the running attack with its beachhead's neighbours (one attack
				-- per attacker and target).
				a.troops += troops
				a.retreat_at = 0
				a.frozen_from = 0
				_add_neighbors(self, a, bh)
				self:_send_attack(a)
			elseif a.started_tick == self.tick then
				-- Two orders in one tick: both attacks start at the end of it, the second absorbs
				-- the first.
				a.troops += troops
				_seed_from_border(self, a)
				self:_send_attack(a)
			else
				-- The new attack absorbs the running one at the end of this tick (after it has
				-- advanced once more with its own troops): see _apply_merges.
				if a.pend == 0 then
					table.insert(self._merges, a)
				end
				a.pend += troops
			end
			return a
		end
		a = new_attack()
		a.aid = self.next_aid
		self.next_aid += 1
		a.attacker = attacker
		a.target = target
		a.troops = troops
		a.started_tick = self.tick
		a.counter = counter
		if bh >= 0 then
			_add_neighbors(self, a, bh)
			a.last_tile = bh
		else
			_seed_from_border(self, a)
		end
		if a.front <= 0 then
			-- Nothing to attack: the troops are refunded at once (rather than sent and retreated)
			-- so the caller can tell the player why.
			o_troops[attacker] += troops
			return nil
		end
		local attacks = self.attacks
		attacks[#attacks + 1] = a
		self.attack_by_id[a.aid] = a
		writei32(self.pair_attack, (attacker * 1024 + target) * 4, a.aid)
		if a.last_tile < 0 then
			a.last_tile = self:_any_queued(a)
		end
		self:_send_attack(a)
		if target ~= 0 then
			self:add_grudge(target, attacker, Rules.HOSTILE_TICKS)
			self.o_attacked_tick[target] = self.tick
			if self:is_human(target) then
				local mk = attacker * 1024 + target
				if self.tick - (self._alert_tick[mk] or -1000) > 150 then
					self._alert_tick[mk] = self.tick
					if counter then
						self:msg(target, Defs.MSG_ALERT, self.o_name[attacker] .. " is counter-attacking you!")
					else
						self:msg(target, Defs.MSG_ALERT, self.o_name[attacker] .. " is attacking you!")
					end
				end
			end
			self:_on_attack_started(a)
		end
		return a
	end

	--- Some queued tile of `a` (the anchor shown before the first conquest), or -1.
	function C._any_queued(_self: any, a: any): number
		for _, b in a.ring do
			if #b > 0 then
				return b[1]
			end
		end
		return -1
	end

	--- Hook for the AI / subclasses.
	function C._on_attack_started(_self: any, _a: any) end

	function C._send_attack(self: any, a: any)
		local tr = Defs.trunc(a.troops)
		a.sent_troops = tr
		self:ev({ Ev.ATTACK, a.aid, a.attacker, a.target, tr, a.last_tile, a.retreat_at > 0 })
	end

	--- Ends an attack. Surviving troops return home multiplied by `keep` (default 1) when `give_back`
	--- (floored to whole troops).
	function C.end_attack(self: any, a: any, give_back: boolean, keep: number?)
		if a.dead then
			return
		end
		a.dead = true
		local k = keep or 1.0
		if give_back and self.o_alive[a.attacker] == 1 then
			local back = math.floor(math.max(a.troops, 0.0) * k)
			self.o_troops[a.attacker] += back
			self.dbg_flow[a.attacker * 5 + 4] += back
		end
		a.troops = 0.0
		local pk = (a.attacker * 1024 + a.target) * 4
		if readi32(self.pair_attack, pk) == a.aid then
			writei32(self.pair_attack, pk, 0)
		end
		self.attack_by_id[a.aid] = nil
		self:ev({ Ev.ATTACK_END, a.aid })
	end

	--- Orders attack `aid` of `id` home. The attack advances on this tick and the
	--- next (the order takes effect when the retreat first ticks), is frozen after that,
	--- and RETREAT_DELAY_TICKS after the order its troops come home — 25 % fewer when the target is
	--- a player (malusForRetreat). A second order changes nothing.
	function C.retreat(self: any, id: number, aid: number): boolean
		local a = self.attack_by_id[aid]
		if a == nil or a.attacker ~= id then
			return false
		end
		if a.retreat_at == 0 then
			a.frozen_from = self.tick + 2
			a.retreat_at = self.tick + Rules.RETREAT_DELAY_TICKS + 1
			self:_send_attack(a)
		end
		return true
	end

	--- Ends every attack by or against `id` (elimination).
	function C.end_attacks_of(self: any, id: number)
		for _, a in self.attacks do
			if a.dead then
				continue
			end
			if a.attacker == id then
				self:end_attack(a, false)
			elseif a.target == id then
				self:end_attack(a, true)
			end
		end
	end

	function C._on_alliance_formed(self: any, a: number, b: number)
		local x = self:attack_between(a, b)
		if x ~= nil then
			self:end_attack(x, true)
		end
		x = self:attack_between(b, a)
		if x ~= nil then
			self:end_attack(x, true)
		end
	end

	-- =========================================================================================
	-- Per-tick processing
	-- =========================================================================================

	function C.attacks_tick(self: any)
		local attacks = self.attacks
		local count = #attacks
		local tick = self.tick
		for idx = 1, count do
			local a = attacks[idx]
			-- An attack ordered this tick starts next tick (new attacks are initialised at
			-- the end of the tick).
			if a.dead or a.started_tick == tick then
				continue
			end
			self:_process_attack(a)
			-- (a local match's step runs as a Coop job spread over frames: Session._local_process)
			Coop.check()
		end
		if #self._merges > 0 then
			self:_apply_merges()
		end
		-- Compact dead attacks.
		local w = 0
		local n = #attacks
		for idx = 1, n do
			local a2 = attacks[idx]
			if not a2.dead then
				w += 1
				attacks[w] = a2
			end
		end
		for idx = n, w + 1, -1 do
			attacks[idx] = nil
		end
	end

	--- A new order on a target already under attack, at the end of the tick:
	--- the running attack is absorbed (its troops join; a retreat order is dropped) and the queue is
	--- rebuilt from the whole border (_seed_from_border). If the running attack ended this tick the
	--- order starts a fresh attack (conquering from the next tick).
	function C._apply_merges(self: any)
		local list = self._merges
		self._merges = {}
		for _, a in list do
			local troops = a.pend
			a.pend = 0.0
			if troops <= 0.0 or self.o_alive[a.attacker] == 0 then
				continue
			end
			if a.target ~= 0 and (self.o_alive[a.target] == 0 or self:allied(a.attacker, a.target)) then
				-- The order's init finds no valid target: nothing leaves home.
				self.o_troops[a.attacker] += troops
				continue
			end
			if a.dead then
				self:start_attack(a.attacker, a.target, troops, -1)
				continue
			end
			a.troops += troops
			a.retreat_at = 0
			a.frozen_from = 0
			_seed_from_border(self, a)
			self:_send_attack(a)
		end
	end

	function C._process_attack(self: any, a: any)
		local at = a.attacker
		local tg = a.target
		local o_alive = self.o_alive
		if o_alive[at] == 0 or (tg ~= 0 and o_alive[tg] == 0) then
			self:end_attack(a, true)
			return
		end
		local tick = self.tick
		local neutral = tg == 0
		if a.retreat_at > 0 then
			if tick >= a.retreat_at then
				self:end_attack(a, true, if neutral then 1.0 else Rules.RETREAT_KEEP)
				return
			end
			if tick >= a.frozen_from then
				return
			end
		end
		if not neutral and self:allied(at, tg) then
			-- An alliance made after the attack started: retreat() without malus.
			self:end_attack(a, true)
			return
		end
		local o_tiles = self.o_tiles
		local o_troops = self.o_troops
		local o_kind = self.o_kind
		local R = self.R
		local K_AREA = R.K_AREA
		-- attackLogic inputs that only change between ticks. borderSize (+ random 0..4) is fixed
		-- for the tick.
		local border_of = a.front * R.K_LIN + self.rng:randi() % Rules.BORDER_JITTER
		local fo_mod = Rules.fallout_modifier(self.fallout_count / math.max(self.map.contestable_count, 1))
		local nl = Rules.neutral_loss_per_mag(o_kind[at])
		local bonus_l = 1.0
		local bonus_s = 1.0
		local trait_l = 1.0
		local trait_s = 1.0
		local mag_k = 1.0
		if not neutral then
			local att_of = o_tiles[at] * K_AREA
			local def_of = math.max(o_tiles[tg] * K_AREA, 1.0)
			local ldb = Rules.large_territory_bonus(def_of, Rules.LARGE_DEFENDER_DEPTH)
			bonus_l = Rules.ATTACKER_LOSS_BASE * Rules.large_territory_bonus(att_of, Rules.LARGE_ATTACKER_DEPTH) * ldb
			bonus_s = Rules.large_territory_bonus(att_of, Rules.LARGE_ATTACKER_SPEED_DEPTH)
				* ldb
				/ (Rules.SPEED_COST_DIVISOR * math.max(border_of, 1.0))
			if self.o_traitor_until[tg] > tick then
				trait_l = Rules.TRAITOR_DEFENSE_DEBUFF
				trait_s = Rules.TRAITOR_SPEED_DEBUFF
			end
			if o_kind[tg] == Defs.KIND_TRIBE and o_kind[at] ~= Defs.KIND_TRIBE then
				mag_k = Rules.BOT_DEFENDER_LOSS_MULT
			end
		end
		local owner = self.owner
		local land = self.land
		local flags = self.flags
		local terr = self.terr
		local def_cover = self.def_cover
		local ATTACK_MAG = Rules.ATTACK_MAG
		local ATTACK_TILE_COST = Rules.ATTACK_TILE_COST
		local border1 = math.max(border_of, 1.0)
		local dbg_flow = self.dbg_flow
		local cap = R.MAX_TILES_PER_TICK
		local budget = 1.0
		local taken = 0
		while budget > 0.0 do
			if a.troops < 1.0 then
				-- An attack that runs out of troops simply ends.
				a.troops = 0.0
				self:end_attack(a, false)
				return
			end
			local t = a.head
			if t >= 0 and (readi32(owner, t * 4) ~= tg or not touches(self, t, at)) then
				a.head = -1
				a.chew = 0.0
				t = -1
			end
			if t < 0 then
				if taken >= cap then
					break
				end
				t = _pop(self, a)
				if t < 0 then
					-- The queue is empty: the attack ends, troops home.
					self:end_attack(a, true)
					return
				end
				if readi32(owner, t * 4) ~= tg or readu8(land, t) == 0 or not touches(self, t, at) then
					continue
				end
				-- _add_neighbors(tile) runs before the tile changes hands.
				_add_neighbors(self, a, t)
				a.head = t
				a.chew = 0.0
			end
			-- Per full-size tile of this tile: attacker troop loss, tick fraction, defender troop loss.
			local tt = readu8(terr, t)
			local mag = ATTACK_MAG[tt]
			local tc = ATTACK_TILE_COST[tt]
			if not neutral and readu8(def_cover, t) > 0 and self:_defense_post_covers(t, tg) then
				mag *= Rules.DEFENSE_POST_MAG
				tc *= Rules.DEFENSE_POST_COST
			end
			if bit32.band(readu8(flags, t), F_FALLOUT) ~= 0 then
				mag *= fo_mod
				tc *= fo_mod
			end
			local loss: number
			local tf: number
			local dloss = 0.0
			if neutral then
				loss = mag * nl
				local v = Rules.TERRA_NULLIUS_COST_SCALE * tc / a.troops
				if v < Rules.TERRA_NULLIUS_MIN_COST then
					v = Rules.TERRA_NULLIUS_MIN_COST
				elseif v > Rules.TERRA_NULLIUS_MAX_COST then
					v = Rules.TERRA_NULLIUS_MAX_COST
				end
				tf = v / (border1 * 2.0)
			else
				local dtroops = o_troops[tg]
				dloss = dtroops / math.max(o_tiles[tg] * K_AREA, 1.0)
				local ratio = dtroops / a.troops
				local cl = if ratio < 0.6 then 0.6 elseif ratio > 2.0 then 2.0 else ratio
				loss = mag * mag_k * trait_l * cl * (bonus_l + Rules.ATTACKER_LOSS_PER_DENSITY * dloss)
				local c1 = if ratio < 0.82 then 0.82 elseif ratio > 7.5 then 7.5 else ratio
				local r20 = ratio / 20.0
				local c2 = if r20 < 1.0 then 1.0 elseif r20 > 50.0 then 50.0 else r20
				tf = c1 * c2 * tc * bonus_s * trait_s
			end
			if tf < 1e-6 then
				tf = 1e-6
			end
			-- The defender's per-tile loss is floored (whole troops).
			local dfloor = math.floor(dloss)
			local need = K_AREA - a.chew
			-- Full-size tiles this tick can still take: the loop runs while budget > 0 (at least one), and
			-- while troops last (the tile that drops them below 1 still falls).
			local can = math.ceil(budget / tf)
			if loss > 0.0 then
				can = math.min(can, math.ceil(a.troops / loss))
			end
			if can >= need then
				budget -= need * tf
				a.troops -= need * loss
				if not neutral then
					local dl = math.min(need * dfloor, math.max(o_troops[tg], 0.0))
					dbg_flow[tg * 5 + 2] += dl
					o_troops[tg] -= dl
				end
				a.chew = 0.0
				a.head = -1
				conquer(self, t, at, a)
				a.last_tile = t
				taken += 1
				if not neutral and o_tiles[tg] * K_AREA < Rules.ANNEX_BELOW_FULL_TILES then
					self:_annex(tg, at)
					self:end_attack(a, true)
					return
				end
			else
				budget -= can * tf
				a.troops -= can * loss
				if not neutral then
					local dl2 = math.min(can * dfloor, math.max(o_troops[tg], 0.0))
					dbg_flow[tg * 5 + 2] += dl2
					o_troops[tg] -= dl2
				end
				a.chew += can
			end
		end
		if (tick + a.aid) % Rules.ATTACK_UPDATE_TICKS == 0 and Defs.trunc(a.troops) ~= a.sent_troops then
			self:_send_attack(a)
			if not neutral then
				self:add_grudge(tg, at, Rules.HOSTILE_TICKS)
				self.o_attacked_tick[tg] = tick
			end
		end
	end

	--- A dead defender: a player under ANNEX_BELOW_FULL_TILES is conquered outright. Its
	--- tiles touching the attacker go to the attacker, others to a bordering non-allied player, in
	--- repeated passes; unreachable pockets stay (and are mopped up later). Gold goes to the attacker.
	function C._annex(self: any, victim: number, by: number)
		self:_conquest_gold(victim, by)
		self.o_killer[victim] = by
		local owner = self.owner
		local tiles = self:owned_tiles(victim)
		local seen = 0
		for _ = 1, 100 do
			local progressed = false
			local rest = {}
			for _, t in tiles do
				seen += 1
				if seen % 1024 == 0 then
					Coop.check() -- (a big nation's fall: tens of thousands of tiles)
				end
				if readi32(owner, t * 4) ~= victim then
					continue
				end
				if touches(self, t, by) then
					conquer(self, t, by, nil)
					progressed = true
					continue
				end
				local taker = self:_annex_neighbour(t, victim)
				if taker > 0 then
					conquer(self, t, taker, nil)
					progressed = true
				else
					rest[#rest + 1] = t
				end
			end
			tiles = rest
			if not progressed or #tiles == 0 then
				break
			end
		end
		if self.o_tiles[victim] > 0 and self:is_human(victim) then
			self:msg(victim, Defs.MSG_BAD, self.o_name[by] .. " has conquered your nation")
		end
	end

	function C._annex_neighbour(self: any, t: number, victim: number): number
		local owner = self.owner
		local W = self.W
		local N = self.N
		local x = t % W
		for k = 1, 4 do
			local n
			if k == 1 then
				if x == 0 then
					continue
				end
				n = t - 1
			elseif k == 2 then
				if x == W - 1 then
					continue
				end
				n = t + 1
			elseif k == 3 then
				if t < W then
					continue
				end
				n = t - W
			else
				if t >= N - W then
					continue
				end
				n = t + W
			end
			local o = readi32(owner, n * 4)
			if o > 0 and o ~= victim and not self:allied(o, victim) then
				return o
			end
		end
		return 0
	end

	--- Every tile of `id` (flood from its border list; tiny owners only — cost ~ tiles owned).
	function C.owned_tiles(self: any, id: number): { number }
		local owner = self.owner
		local bnext = self.bnext
		local out = {}
		local seen: { [number]: boolean } = {}
		local b = self.bhead[id]
		while b ~= -1 do
			if not seen[b] then
				seen[b] = true
				out[#out + 1] = b
			end
			b = readi32(bnext, b * 4)
		end
		local i = 1
		local W = self.W
		local N = self.N
		while i <= #out do
			local t = out[i]
			i += 1
			local x = t % W
			for k = 1, 4 do
				local n
				if k == 1 then
					n = if x > 0 then t - 1 else -1
				elseif k == 2 then
					n = if x < W - 1 then t + 1 else -1
				elseif k == 3 then
					n = if t >= W then t - W else -1
				else
					n = if t < N - W then t + W else -1
				end
				if n >= 0 and readi32(owner, n * 4) == id and not seen[n] then
					seen[n] = true
					out[#out + 1] = n
				end
			end
		end
		return out
	end

	C.conquer = conquer

	--- Overridden by SimStructures: true when a defense post of `id` covers tile `t`.
	function C._defense_post_covers(_self: any, _t: number, _id: number): boolean
		return false
	end

	-- =========================================================================================
	-- Snapshot helpers
	-- =========================================================================================

	--- {aid, attacker, target, troops, anchor tile, retreating} per live attack.
	function C.attack_rows(self: any): { { any } }
		local out = {}
		for _, a in self.attacks do
			if not a.dead then
				out[#out + 1] = { a.aid, a.attacker, a.target, Defs.trunc(a.troops), a.last_tile, a.retreat_at > 0 }
			end
		end
		return out
	end
end

return SimAttacks
