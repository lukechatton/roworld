-- Port of scripts/ui/ui_rules.gd
-- Client-side game knowledge for the interface: build/nuke catalogue, costs (via Rules), what a
-- click on a tile would do, radial-menu contents and placement checks. These are hints only; the
-- Sim validates every intent for real.
-- (The GDScript's unused private helpers _site_ok / _nearest_own / _neighbours4 are left out.)

local UICtx = require("./UICtx") :: any
local Defs = UICtx.core("Defs")

local _Rules: any = nil
local function Rules(): any
	if _Rules == nil then
		_Rules = UICtx.core("Rules")
	end
	return _Rules
end
local _Theme: any = nil
local function T(): any
	if _Theme == nil then
		_Theme = UICtx.mod("UITheme")
	end
	return _Theme
end

local _Arsenal: any = nil
local function Arsenal(): any
	if _Arsenal == nil then
		_Arsenal = UICtx.data("Arsenal")
	end
	return _Arsenal
end

local UIRules = {}
UIRules.__index = UIRules

UIRules.BUILD_KINDS = { "city", "port", "factory", "defense", "sam", "silo", "warship" }
UIRules.NUKE_KINDS = { "atom", "hydrogen", "mirv" }
--- Hotkeys 1..9, 0 in this order.
UIRules.ACTIONS = { "city", "port", "factory", "defense", "sam", "silo", "warship", "atom", "hydrogen", "mirv" }
UIRules.HOTKEYS = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" }
--- The Arsenal's kinds (Data/Arsenal: unlocked with Stars or Robux), in the order of its tray:
--- structures, munitions launched like a nuke (the last two from their own structure: strikes), and
--- the Reinforcements call. A locked one is offered in the Arsenal instead of doing anything.
UIRules.ARSENAL_BUILD = { "artillery", "airfield", "railgun" }
UIRules.ARSENAL_NUKES = { "mega", "scatter", "airstrike", "slug" }
UIRules.ARSENAL = { "artillery", "airfield", "railgun", "mega", "scatter", "airstrike", "slug", "reinforce" }

UIRules.TITLES = {
	city = "City",
	port = "Port",
	factory = "Factory",
	defense = "Defense Post",
	sam = "SAM Launcher",
	silo = "Missile Silo",
	warship = "Warship",
	atom = "Atom Bomb",
	hydrogen = "Hydrogen Bomb",
	mirv = "MIRV",
	artillery = "Artillery",
	airfield = "Airfield",
	railgun = "Railgun",
	mega = "Mega Nuke",
	scatter = "Scattershot",
	airstrike = "Air Strike",
	slug = "Railgun Shot",
	reinforce = "Reinforcements",
}
UIRules.SHORT = {
	city = "City",
	port = "Port",
	factory = "Factory",
	defense = "Defense",
	sam = "SAM",
	silo = "Silo",
	warship = "Warship",
	atom = "Atom",
	hydrogen = "H-Bomb",
	mirv = "MIRV",
	artillery = "Artillery",
	airfield = "Airfield",
	railgun = "Railgun",
	mega = "Mega",
	scatter = "Scatter",
	airstrike = "Strike",
	slug = "Slug",
	reinforce = "Troops",
}
UIRules.BLURBS = {
	city = "Raises your troop cap by {city}. Joins the road network.",
	port = "Coastal. Sends trade ships for gold and builds warships.",
	factory = "Road hub. Trucks pay gold at every stop they pass.",
	defense = "Land within {def_r} tiles costs attackers {def_mag}x the troops and {def_cost}x the time.",
	sam = "Shoots down bombs aimed within {sam_r} tiles. MIRV warheads can't be stopped.",
	silo = "Required to launch nuclear weapons.",
	warship = "Patrols where you send it: sinks transports, then warships, and captures trade ships. Heals at your ports.",
	atom = "Small blast that wipes troops and structures, leaving fallout.",
	hydrogen = "Massive blast. Anything inside is erased.",
	mirv = "Splits into up to {mirv_n} warheads that rain over one nation.",
	artillery = "Shells every enemy within {art_r} tiles on its own: their troops, and the structures it reaches.",
	airfield = "Flies Air Strikes on any spot within {air_r} tiles. Rearms in {air_s} s.",
	railgun = "Fires at any spot on the map. Reloads in {rail_s} s.",
	mega = "Twice an Atom Bomb's radius: four times the ground, gone.",
	scatter = "An Atom Bomb with {scat_lo} to {scat_hi} warheads that come down around it.",
	airstrike = "Bombs a {air_blast}-tile circle: kills troops and wrecks structures. No SAM can stop it.",
	slug = "A slug that takes a level off every structure it hits. Nothing intercepts it.",
	reinforce = "Brings a fifth of your troop cap at once. Ready again every {rein_s} s.",
}

--- Godot String.format({key: value}): replaces {key} placeholders.
function UIRules.format(text: string, values: { [string]: string }): string
	return (
		string.gsub(text, "{([%w_]+)}", function(k: string)
			local v = values[k]
			return if v ~= nil then v else "{" .. k .. "}"
		end)
	)
end

--- Blurb with its numbers filled in from Rules.
function UIRules.blurb(kind: string): string
	local R = Rules()
	return UIRules.format(UIRules.BLURBS[kind] or "", {
		city = T().fmt_troops(R.CITY_TROOPS),
		def_r = tostring(Defs.round(R.defense_range())),
		def_mag = tostring(Defs.round(R.DEFENSE_POST_MAG)),
		def_cost = tostring(Defs.round(R.DEFENSE_POST_COST)),
		sam_r = tostring(Defs.round(R.sam_range(1))),
		mirv_n = tostring(R.MIRV_WARHEADS),
		art_r = tostring(Defs.round(R.artillery_range())),
		air_r = tostring(Defs.round(R.launch_range(Defs.N_AIRSTRIKE))),
		air_s = tostring(R.RELOAD_TICKS[Defs.S_AIRFIELD] // Defs.TICK_RATE),
		rail_s = tostring(R.RELOAD_TICKS[Defs.S_RAILGUN] // Defs.TICK_RATE),
		air_blast = tostring(Defs.round(R.NUKE_RADIUS[Defs.N_AIRSTRIKE])),
		scat_lo = tostring(R.SCATTER_MIN),
		scat_hi = tostring(R.SCATTER_MAX),
		rein_s = tostring(R.REINFORCE_COOLDOWN_TICKS // Defs.TICK_RATE),
	})
end

function UIRules.new(c: any)
	local self = setmetatable({}, UIRules)
	self.ctx = c
	-- One-entry cache for primary(): hover card and the following click ask about the same tile.
	self._pc_tile = -1
	self._pc_msec = 0
	self._pc_tick = -1
	self._pc_ratio = -1.0
	self._pc = {} :: { [string]: any }
	-- Local owner's structure counts by kind (index = Defs.S_*) plus warships and transports, kept
	-- current from GameState signals so availability checks are O(1).
	self._scount = table.create(Defs.STRUCT_KIND_COUNT, 0)
	self._scount[0] = 0
	self._warships = 0
	self._transports = 0
	self._counted_owner = -1
	return self
end

--- The Arsenal item (Data/Arsenal) a build / launch kind belongs to; nil for the kinds everyone has.
function UIRules.arsenal_item(kind: string): any
	return Arsenal().item_for(kind)
end

--- True when `kind` is an Arsenal kind the player hasn't unlocked.
function UIRules.arsenal_locked(self: any, kind: string): boolean
	local it = Arsenal().item_for(kind)
	if it == nil then
		return false
	end
	local s = self.ctx.session
	return not (s ~= nil and type(s.has_unlock) == "function" and s:has_unlock(it.key))
end

--- A strike: a munition its own structure fires (an Air Strike, a Railgun shot), not a silo.
function UIRules.is_strike(kind: string): boolean
	return kind == "airstrike" or kind == "slug"
end

--- The structure kind (Defs.S_*) a nuke / strike kind leaves from.
function UIRules.launcher(kind: string): number
	local nk = Defs.nuke_kind_from_name(kind)
	local l = if nk >= 0 then Rules().NUKE_LAUNCHER[nk] else nil
	return if type(l) == "number" and l >= 0 then l else Defs.S_SILO
end

--- The troops/s label is green while the regrowth rate
--- (Rules.troop_growth) is >= its previous sample and orange once it drops — past the troop
--- count that regrows fastest (the (1 - troops / max) fall-off overtakes the troops^0.73 term), or
--- when losing land lowers the cap. `last` = nil (no previous sample) keeps it green.
function UIRules.troop_rate_rising(rate: number, last: number?): boolean
	return last == nil or rate >= last
end

--- The label text: "+" .. render_troops(rate per second) .. "/s"; render_number clamps at 0,
--- so a nation above its cap after losing land reads "+0/s".
function UIRules.troop_rate_text(per_second: number): string
	return "+" .. T().fmt_troops(math.max(per_second, 0.0)) .. "/s"
end

--- Aimed at a target tile and launched (the bombs, and the Arsenal's munitions).
function UIRules.is_nuke(kind: string): boolean
	return kind == "atom"
		or kind == "hydrogen"
		or kind == "mirv"
		or kind == "mega"
		or kind == "scatter"
		or kind == "airstrike"
		or kind == "slug"
end

-- ---------------------------------------------------------------------------------------------
-- Costs (single adapter over Core/Rules)
-- ---------------------------------------------------------------------------------------------

--- `owned`: structures of the kinds that share the cost count, warships for "warship", MIRVs
--- launched this match for "mirv".
function UIRules.rules_cost(kind: string, owned: number): number
	if UIRules.is_nuke(kind) then
		return Rules().nuke_cost(kind, owned)
	end
	return Rules().build_cost(kind, owned)
end

--- (inner, outer) blast radii in tiles (MIRV: 0, spread) — Rules.nuke_radii. Two numbers.
function UIRules.nuke_radii(kind: string): (number, number)
	local k = Defs.nuke_kind_from_name(kind)
	if k < 0 then
		return 0, 0
	end
	local a, b = Rules().nuke_radii(k)
	if typeof(a) == "Vector2" then
		return a.X, a.Y
	end
	return a or 0, b or 0
end

function UIRules.nuke_radius(kind: string): number
	local _, outer = UIRules.nuke_radii(kind)
	return Defs.round(outer)
end

--- "Blast radius" text for tooltips: "15 tiles (6 wiped out)" / MIRV spread.
function UIRules.blast_text(kind: string): string
	local inner, outer = UIRules.nuke_radii(kind)
	if kind == "mirv" then
		-- MIRV_WARHEADS is the cap: the real count follows the target's land (55-tile spacing)
		return string.format("Up to %d warheads across the target nation", Rules().MIRV_WARHEADS)
	end
	if inner > 0.0 then
		return string.format("%d tiles (%d wiped out)", Defs.round(outer), Defs.round(inner))
	end
	return string.format("%d tiles", Defs.round(outer))
end

--- The victory metric as result-screen copy (review R2-4): `win` = share of the land outside
--- fallout (what Sim._check_victory compares with Rules.WIN_SHARE), `land` = share of all land.
--- "80.1%" + `all_land` when nothing is irradiated (or it makes no visible difference), else
--- "80.1% of the land outside fallout" -- never a number that reads as short of the 80% goal.
function UIRules.win_phrase(win: number, land: number, fallout: number, all_land: string): string
	local pct = T().fmt_pct(win)
	if fallout > 0 and T().fmt_pct(land) ~= pct then
		return pct .. " of the land outside fallout"
	end
	return pct .. all_land
end

--- What the result screen's offers say for a payout and an inventory (UI/GameOver; tests/offers.luau):
--- the next unlock with the Stars towards it, and 2x Stars with what this match would have paid.
--- `stars`: the balance to count with (the payout's own, or the inventory's once it changed since).
--- Returns { goal = { key, text, ready }?, x2 = { text }? }.
function UIRules.result_offers(award: any, inv: any, catalog: any, stars: number?): { [string]: any }
	local out: { [string]: any } = {}
	if award == nil or (tonumber(award.total) or 0) <= 0 or type(inv) ~= "table" or inv.loaded == false then
		return out
	end
	local unlocks = if type(inv.unlocks) == "table" then inv.unlocks else {}
	local balance = math.max(0, math.floor(stars or tonumber(award.balance) or tonumber(inv.stars) or 0))
	local goal = catalog.next_goal(unlocks)
	if goal ~= nil then
		local ready = balance >= goal.stars
		out.goal = {
			key = goal.key,
			ready = ready,
			text = if ready
				then "UNLOCK " .. string.upper(goal.title)
				else string.format("%s  %s / %s", string.upper(goal.title), UICtx.commas(balance), UICtx.commas(goal.stars)),
		}
	end
	if not unlocks.stars2x and catalog.item("stars2x") ~= nil then
		-- (a payout already doubled never gets here: its owner has the booster)
		out.x2 = { text = string.format("WITH 2X STARS: +%s", UICtx.commas(math.floor(award.total) * 2)) }
	end
	return out
end

--- Seconds for the result screen's "Match duration" card: the whole match (stats.match_s, set at
--- game over) on a result, the moment the player fell (duration_s) on ELIMINATED (review R2-6).
function UIRules.result_seconds(kind: string, stats: { [string]: any }): number
	local secs = tonumber(stats.duration_s) or 0.0
	local m = tonumber(stats.match_s)
	if kind ~= "eliminated" and m ~= nil then
		secs = m
	end
	return secs
end

--- Full recount (on bind / when the local owner changes). Everything else is incremental.
function UIRules.recount(self: any)
	self._scount = table.create(Defs.STRUCT_KIND_COUNT, 0)
	self._scount[0] = 0
	self._warships = 0
	self._transports = 0
	local s = self.ctx.state
	local me = self.ctx:me()
	self._counted_owner = me
	if s == nil or me == 0 then
		return
	end
	for _, st in s.structures do
		if st.owner == me and st.kind >= 0 and st.kind < Defs.STRUCT_KIND_COUNT then
			self._scount[st.kind] += 1
		end
	end
	for _, u in s.units do
		if u.owner == me then
			if u.kind == Defs.U_WARSHIP then
				self._warships += 1
			elseif u.kind == Defs.U_TRANSPORT then
				self._transports += 1
			end
		end
	end
end

--- Structure moved between owners (old -> new); returns true when the local owner is involved.
function UIRules.on_structure(self: any, kind: number, old_owner: number, new_owner: number): boolean
	local me = self.ctx:me()
	if me == 0 or kind < 0 or kind >= Defs.STRUCT_KIND_COUNT then
		return false
	end
	if self._counted_owner ~= me then
		self:recount()
		return true
	end
	local hit = false
	if old_owner == me then
		self._scount[kind] = math.max(0, self._scount[kind] - 1)
		hit = true
	end
	if new_owner == me then
		self._scount[kind] += 1
		hit = true
	end
	return hit
end

--- Unit added (+1) or removed (-1); returns true when it is ours.
function UIRules.on_unit(self: any, kind: number, owner_id: number, delta: number): boolean
	local me = self.ctx:me()
	if me == 0 or owner_id ~= me then
		return false
	end
	if self._counted_owner ~= me then
		self:recount()
		return true
	end
	if kind == Defs.U_WARSHIP then
		self._warships = math.max(0, self._warships + delta)
	elseif kind == Defs.U_TRANSPORT then
		self._transports = math.max(0, self._transports + delta)
	end
	return true
end

function UIRules.struct_count(self: any, kind: number): number
	if self._counted_owner ~= self.ctx:me() then
		self:recount()
	end
	return if kind >= 0 and kind < Defs.STRUCT_KIND_COUNT then self._scount[kind] else 0
end

function UIRules.transports(self: any): number
	if self._counted_owner ~= self.ctx:me() then
		self:recount()
	end
	return self._transports
end

function UIRules.owned(self: any, kind: string): number
	local ctx = self.ctx
	if ctx.state == nil or ctx:me() == 0 then
		return 0
	end
	if self._counted_owner ~= ctx:me() then
		self:recount()
	end
	if kind == "warship" then
		return self._warships
	end
	if kind == "mirv" then
		return ctx.state.mirvs_launched or 0
	end
	if UIRules.is_nuke(kind) or kind == "reinforce" then
		return 0
	end
	-- Ports and factories share one count (Rules.cost_count_kinds).
	local n = 0
	for _, sk in Rules().cost_count_kinds(kind) do
		n += self:struct_count(sk)
	end
	return n
end

--- Gold for the next `kind` (structures, upgrades, warships, nukes) — Rules.cost_of, the Sim's
--- own pricing (shared port/factory count, levels, worldwide MIRV launches).
function UIRules.cost(self: any, kind: string): number
	local ctx = self.ctx
	if kind == "reinforce" then
		return Rules().REINFORCE_COST
	end
	if ctx.state == nil then
		return UIRules.rules_cost(kind, 0)
	end
	return Rules().cost_of(ctx.state, ctx:me(), kind)
end

--- The local player's finished structures of `kind` that can fire now (a silo's loaded missiles, an
--- airfield / railgun that isn't reloading), and the seconds until the next one can when none does.
function UIRules.ready_launchers(self: any, kind: number): (number, number)
	local s = self.ctx.state
	if s == nil then
		return 0, 0.0
	end
	local me = self.ctx:me()
	local cd = Rules().RELOAD_TICKS[kind] or 0
	local n = 0
	local soonest = math.huge
	for _, st in s.structures do
		if st.owner == me and st.kind == kind and st.active_tick <= s.tick then
			local busy = 0
			local first = math.huge
			for _, t in st.shots or {} do
				if t + cd > s.tick then
					busy += 1
					first = math.min(first, t + cd - s.tick)
				end
			end
			local free = math.max(0, (st.level or 1) - busy)
			n += free
			if free == 0 then
				soonest = math.min(soonest, first)
			end
		end
	end
	return n, if n == 0 and soonest < math.huge then soonest / Defs.TICK_RATE else 0.0
end

--- Finished (active) structures of `kind` the local player owns — silos must be built before a
--- nuke can fly. Returns active, under_construction, seconds until the first one finishes.
function UIRules.active_structs(self: any, kind: number): (number, number, number)
	local ctx = self.ctx
	local s = ctx.state
	local act = 0
	local building = 0
	local soonest = math.huge
	if s == nil then
		return 0, 0, 0.0
	end
	local me = ctx:me()
	for _, st in s.structures do
		if st.owner ~= me or st.kind ~= kind then
			continue
		end
		if st.active_tick > s.tick then
			building += 1
			soonest = math.min(soonest, (st.active_tick - s.tick) / Defs.TICK_RATE)
		else
			act += 1
		end
	end
	return act, building, if building > 0 then soonest else 0.0
end

--- {ok, locked, reason, cost} — whether the action can be used right now (ignores the target).
function UIRules.availability(self: any, kind: string): { [string]: any }
	local ctx = self.ctx
	local c = self:cost(kind)
	local out = { ok = false, locked = false, reason = "", cost = c } :: { [string]: any }
	local s = ctx.state
	local o = ctx:my()
	-- an Arsenal kind the player hasn't unlocked: `arsenal` names the item to offer
	if self:arsenal_locked(kind) then
		local it = UIRules.arsenal_item(kind)
		out.reason = "Unlock " .. it.title .. " in the Arsenal"
		out.locked = true
		out.arsenal = it.key
		return out
	end
	if s == nil or o == nil or not ctx:in_match() then
		out.reason = "Join a match first"
		out.locked = true
		return out
	end
	if not o.spawned then
		out.reason = "Place your capital first"
		out.locked = true
		return out
	end
	if not o.alive then
		out.reason = "You have been eliminated"
		out.locked = true
		return out
	end
	if s.phase ~= Defs.PHASE_PLAYING then
		out.reason = "Available once the match begins"
		out.locked = true
		return out
	end
	if UIRules.is_nuke(kind) then
		-- the structure it leaves from: a silo, or (strikes) an airfield / a railgun
		local lk = UIRules.launcher(kind)
		local title = Defs.STRUCT_TITLES[lk]
		if self:struct_count(lk) == 0 then
			out.reason = "Requires " .. (if lk == Defs.S_AIRFIELD then "an " else "a ") .. title
			out.locked = true
			return out
		end
		local act, _, soon = self:active_structs(lk)
		if act == 0 then
			local what = if lk == Defs.S_SILO then "Silo" else title
			out.reason = what .. " under construction · ready in " .. T().fmt_time(math.ceil(soon))
			out.locked = true
			return out
		end
		if UIRules.is_strike(kind) then
			local ready, wait = self:ready_launchers(lk)
			if ready == 0 then
				out.reason = string.format(
					"%s · ready in %s",
					if lk == Defs.S_AIRFIELD then "Airfield rearming" else "Railgun reloading",
					T().fmt_time(math.ceil(wait))
				)
				return out
			end
		end
	end
	if kind == "reinforce" then
		local wait = ((s.reinforce_ready and s.reinforce_ready[o.id]) or 0) - s.tick
		if wait > 0 then
			out.reason = "Ready in " .. T().fmt_time(math.ceil(wait / Defs.TICK_RATE))
			return out
		end
		if Rules().reinforce_troops(o.troops or 0, o.max_troops or 0) <= 0 then
			out.reason = "Your army is at its cap"
			return out
		end
	end
	if kind == "port" and not ctx.borders:has_coast() then
		out.reason = "Requires a coastline"
		out.locked = true
		return out
	end
	if kind == "warship" and self:struct_count(Defs.S_PORT) == 0 then
		out.reason = "Requires a Port"
		out.locked = true
		return out
	end
	if kind == "warship" then
		local act, _, soon = self:active_structs(Defs.S_PORT)
		if act == 0 then
			out.reason = "Port under construction · ready in " .. T().fmt_time(math.ceil(soon))
			out.locked = true
			return out
		end
	end
	if c < 0 then
		out.reason = "Unavailable"
		out.locked = true
		return out
	end
	if (o.gold or 0) < c then
		out.reason = "Need " .. T().fmt_num(c - o.gold) .. " more gold"
		return out
	end
	out.ok = true
	return out
end

--- Structure kinds an own structure of the same kind upgrades instead of a new build (defense posts
--- are not upgradable).
UIRules.UPGRADABLE = { "city", "port", "factory", "sam", "silo" }

--- Bulk menus (four fixed slots: x1, two steps, then the most the
--- player can do right now): structure upgrades x1 / x5 / x10 / xMax, atom bombs x1 / x2 / x5 / xMax
--- (xMax capped by gold, and for bombs by loaded silo missiles; Protocol.MAX_INTENT_AMOUNT 50). User
--- 2026-09-29: the build menu should offer to build several cities, factories or SAMs at once, stacked
--- on top of each other, when the player can afford them.
UIRules.STRUCTURE_BULK_STEPS = { 5, 10 }
UIRules.NUKE_BULK_STEPS = { 2, 5 }
UIRules.MAX_BULK = 50

--- Missiles loaded right now in the local player's finished silos (a silo holds one per level;
--- each launch reloads for SILO_COOLDOWN_TICKS).
function UIRules.ready_missiles(self: any): number
	local s = self.ctx.state
	if s == nil then
		return 0
	end
	local me = self.ctx:me()
	local cd = Rules().SILO_COOLDOWN_TICKS
	local n = 0
	for _, st in s.structures do
		if st.owner == me and st.kind == Defs.S_SILO and st.active_tick <= s.tick then
			local busy = 0
			for _, t in st.shots or {} do
				if t + cd > s.tick then
					busy += 1
				end
			end
			n += math.max(0, (st.level or 1) - busy)
		end
	end
	return n
end

--- Total gold for `amount` more of `kind` in a row (upgrades: each level at the next price).
function UIRules.bulk_cost(self: any, kind: string, amount: number): number
	local R = Rules()
	if UIRules.is_nuke(kind) then
		return R.nuke_cost(kind, if self.ctx.state then self.ctx.state.mirvs_launched else 0) * amount
	end
	local count = if self.ctx.state then R.cost_count_of(self.ctx.state, self.ctx:me(), kind) else 0
	local total = 0
	for i = 0, amount - 1 do
		total += R.build_cost(kind, count + i)
	end
	return total
end

--- The most of `kind` the local player can buy in a row now (gold; bombs: loaded missiles too).
function UIRules.bulk_max(self: any, kind: string): number
	local o = self.ctx:my()
	local gold = if o ~= nil then (tonumber(o.gold) or 0) else 0
	local cap = UIRules.MAX_BULK
	if UIRules.is_nuke(kind) then
		cap = math.min(cap, self:ready_missiles())
	end
	local max = 0
	for n = 1, cap do
		if self:bulk_cost(kind, n) > gold then
			break
		end
		max = n
	end
	return max
end

--- The amount ring for `kind` (id prefix "build" / "nuke") when more than one is possible, else nil.
function UIRules.bulk_ring(self: any, prefix: string, kind: string): { any }?
	local max = self:bulk_max(kind)
	if max <= 1 then
		return nil
	end
	local steps = if UIRules.is_nuke(kind) then UIRules.NUKE_BULK_STEPS else UIRules.STRUCTURE_BULK_STEPS
	local slots = { 1, steps[1], steps[2], max }
	local ring = {}
	local nuke = UIRules.is_nuke(kind)
	local loaded = if nuke then self:ready_missiles() else math.huge
	for i, n in slots do
		local cost = self:bulk_cost(kind, n)
		local ok = n <= max
		local reason = ""
		if not ok then
			reason = if nuke and n > loaded
				then string.format("Only %d missile%s loaded", loaded, if loaded == 1 then "" else "s")
				else "Not enough gold"
		end
		table.insert(ring, {
			id = string.format("%s:%s:%d", prefix, kind, n),
			-- (the fourth slot is the most affordable: its amount says how many)
			label = string.format("×%d · %s", n, T().fmt_cost(cost)),
			icon = kind,
			ok = ok,
			reason = reason,
			danger = nuke,
			cost = cost,
		})
	end
	return ring
end

--- A Rules constant by name (so the UI works before and after the Sim exposes it).
function UIRules.rules_const(cname: string, fallback: any): any
	local v = Rules()[cname]
	if v == nil then
		return fallback
	end
	return v
end

--- Radius (our tiles) a build tap searches the player's own land for a valid site
--- (15 full-size tiles).
function UIRules.snap_radius(): number
	return tonumber(UIRules.rules_const("BUILD_SNAP_RADIUS", 15.0 / Rules().K_LIN)) :: number
end

--- Friendly copy for Rules.placement reasons.
UIRules.PLACE_REASONS = {
	not_own = "Build on your own land",
	no_room = "No room here: structures need space",
	no_coast = "Ports must be on your coast",
	no_port = "Warships need a finished port on this water",
	gold = "Not enough gold",
	invalid = "Can't build here",
}

--- Where a build tap at `tile` really lands:
---   * near an own structure of the same upgradable kind -> upgrade it (tile = that structure);
---   * else the nearest valid site on the player's own land connected to the tap, within
---     snap_radius(), at least STRUCT_MIN_DIST from every structure of any owner (ports: coast).
--- Nukes and warships aim exactly. Returns {ok, tile, reason, warn, upgrade, sid, level}.
function UIRules.resolve_placement(self: any, kind: string, tile: number): { [string]: any }
	local ctx = self.ctx
	local out =
		{ ok = false, tile = tile, reason = "", warn = "", upgrade = false, sid = 0, level = 1 } :: { [string]: any }
	local s = ctx.state
	if s == nil or tile < 0 then
		out.reason = "Point at the globe"
		return out
	end
	if UIRules.is_nuke(kind) then
		local pl = self:_placement_exact(kind, tile)
		out.ok = pl.ok
		out.reason = pl.reason
		out.warn = pl.warn
		return out
	end
	-- The Sim's own algorithm (Rules.place_site via Rules.placement): snapped site or upgrade.
	local r = Rules().placement(s, ctx:me(), kind, tile)
	local code = tostring(r.reason or "")
	local rtile = tonumber(r.tile) or -1
	if kind == "warship" then
		-- the tap picks the patrol target on the sea; Rules returns the launching port.
		out.port = rtile
		out.ok = code == "" and s.map:is_water(tile)
		out.tile = tile
		out.code = code
		if code == "" and not s.map:is_water(tile) then
			out.reason = "Tap the sea where the warship should patrol"
		elseif code ~= "" then
			out.reason = UIRules.PLACE_REASONS[code] or "Can't build here"
		end
		return out
	end
	-- Gold is shown on the slot itself; the preview still shows where it would go.
	out.ok = code == "" or code == "gold"
	out.tile = if rtile >= 0 then rtile else tile
	out.reason = if code ~= "" then (UIRules.PLACE_REASONS[code] or "Can't build here") else ""
	out.code = code
	local sid = tonumber(r.upgrade_sid) or 0
	if sid > 0 and s.structures[sid] ~= nil then
		out.upgrade = true
		out.sid = sid
		out.level = s.structures[sid].level + 1
	end
	if code == "gold" then
		out.ok = false
	end
	return out
end

--- {ok, reason, warn, tile, upgrade, level} for placing `kind` at `tile` (availability is checked
--- separately). Structures snap / upgrade like the Sim (resolve_placement).
function UIRules.placement(self: any, kind: string, tile: number): { [string]: any }
	if UIRules.is_nuke(kind) then
		return self:_placement_exact(kind, tile)
	end
	return self:resolve_placement(kind, tile)
end

--- True when a finished structure of `skind` of the local player's that can fire now is within the
--- reach of munition `nkind` from `tile` (no reach limit: any such structure).
function UIRules.in_reach(self: any, skind: number, nkind: number, tile: number): boolean
	local s = self.ctx.state
	if s == nil then
		return false
	end
	local R = s.rules or Rules()
	local me = self.ctx:me()
	local reach = R.launch_range(nkind)
	local cd = R.RELOAD_TICKS[skind] or 0
	local range_d2 = s.map.range_d2
	for _, st in s.structures do
		if st.owner == me and st.kind == skind and st.active_tick <= s.tick then
			local busy = 0
			for _, t in st.shots or {} do
				if t + cd > s.tick then
					busy += 1
				end
			end
			if busy < (st.level or 1) and (reach <= 0 or range_d2(st.tile, tile) <= reach * reach) then
				return true
			end
		end
	end
	return false
end

function UIRules._placement_exact(self: any, kind: string, tile: number): { [string]: any }
	local ctx = self.ctx
	local out = { ok = false, reason = "", warn = "" } :: { [string]: any }
	local s = ctx.state
	if s == nil or tile < 0 then
		out.reason = "Point at the globe"
		return out
	end
	local map = s.map
	local own = s:tile_owner(tile)
	local me = ctx:me()
	if UIRules.is_nuke(kind) then
		if own == me and own ~= 0 then
			out.reason = "That is your own land"
			return out
		end
		if not map:is_land(tile) and kind ~= "mirv" then
			out.warn = "Open water: little to hit"
		end
		if own ~= 0 and s:are_allies(me, own) then
			out.warn = "Breaks your alliance with " .. s:owner_name(own)
		end
		if kind == "mirv" and own == 0 then
			out.reason = "Target a nation"
			return out
		end
		if UIRules.is_strike(kind) then
			-- a strike never hits an ally, and an air strike needs a ready airfield within reach
			out.warn = ""
			if own ~= 0 and s:are_allies(me, own) then
				out.reason = "That is your ally's land"
				return out
			end
			if kind == "airstrike" and not self:in_reach(Defs.S_AIRFIELD, Defs.N_AIRSTRIKE, tile) then
				out.reason = "Out of your Airfields' reach"
				return out
			end
			if own == 0 then
				out.warn = "Nobody's land: nothing to hit"
			end
		end
		out.ok = true
		return out
	end
	if kind == "warship" then
		if map:is_water(tile) or own == me then
			out.ok = true
		else
			out.reason = "Target water near your ports"
		end
		return out
	end
	if own ~= me then
		out.reason = "Build on your own land"
		return out
	end
	if kind == "port" and not map:is_coastal(tile) then
		out.reason = "Ports must be on the coast"
		return out
	end
	-- Same test as the Sim: no structure closer than STRUCT_MIN_DIST (latitude-corrected circle).
	local md = Rules().STRUCT_MIN_DIST
	local min_d2 = md * md
	local range_d2 = Defs.range_d2
	for _, st in s.structures do
		if range_d2(tile, st.tile) < min_d2 then
			out.reason = "Too close to another structure"
			return out
		end
	end
	out.ok = true
	return out
end

-- ---------------------------------------------------------------------------------------------
-- Primary click
-- ---------------------------------------------------------------------------------------------

--- What a primary click on `tile` does:
--- Where a boat aimed at `tile` lands — the
--- nearest coastal tile of the same owner (unclaimed land for owner 0) that one of our coasts
--- reaches by sea, so clicking anywhere on a territory across the water works, not only its shore
--- pixel. Searches rings out to BOAT_SNAP_FULL full-size tiles; -1 when none.
UIRules.BOAT_SNAP_FULL = 120.0
function UIRules.boat_landing(self: any, tile: number): number
	local ctx = self.ctx
	local s = ctx.state
	if s == nil or tile < 0 then
		return -1
	end
	local map = s.map
	local borders = ctx.borders
	if map:is_coastal(tile) and borders:can_reach_by_sea(tile) then
		return tile
	end
	local own = s:tile_owner(tile)
	local W, H = map.W, map.H
	local k = tonumber(map.k_lin) or 1.0
	local rmax = math.ceil(UIRules.BOAT_SNAP_FULL / k)
	local cx, cy = tile % W, tile // W
	local best, best_d = -1, math.huge
	for r = 1, rmax do
		-- the ring at Chebyshev distance r
		for dy = -r, r do
			local y = cy + dy
			if y < 0 or y >= H then
				continue
			end
			local edge = dy == -r or dy == r
			local dx = -r
			while dx <= r do
				local x = cx + dx
				if x >= 0 and x < W then
					local t = y * W + x
					if map:is_coastal(t) and s:tile_owner(t) == own and borders:can_reach_by_sea(t) then
						local d = dx * dx + dy * dy
						if d < best_d then
							best, best_d = t, d
						end
					end
				end
				dx += if edge then 1 else 2 * r
			end
		end
		-- a hit on ring r: nothing farther than r * sqrt(2) can be closer
		if best >= 0 and r * r >= best_d / 2 then
			break
		end
	end
	return best
end

--- {type: spawn|expand|attack|boat|inspect|none, ok, reason, target, troops, verb, icon}
function UIRules.primary(self: any, tile: number): { [string]: any }
	local ctx = self.ctx
	local now = UICtx.msec()
	local t = if ctx.state ~= nil then ctx.state.tick else -1
	if
		tile == self._pc_tile
		and now - self._pc_msec < 400
		and t == self._pc_tick
		and math.abs(ctx.ratio - self._pc_ratio) < 1e-6
	then
		return table.clone(self._pc)
	end
	local res = self:_primary(tile)
	self._pc_tile = tile
	self._pc_msec = now
	self._pc_tick = t
	self._pc_ratio = ctx.ratio
	self._pc = res
	return table.clone(res)
end

--- Drops the primary() cache (tests / after the world changed under the same tick).
function UIRules.invalidate(self: any)
	self._pc_tile = -1
end

function UIRules._primary(self: any, tile: number): { [string]: any }
	local ctx = self.ctx
	local out =
		{ type = "none", ok = false, reason = "", target = 0, troops = 0.0, verb = "", icon = "info" } :: { [string]: any }
	local s = ctx.state
	if s == nil or tile < 0 or tile >= Defs.TILE_COUNT then
		return out
	end
	local map = s.map
	local me = ctx:me()
	local own = s:tile_owner(tile)
	out.target = own
	if me == 0 or not ctx:in_match() then
		out.type = "inspect"
		out.ok = own ~= 0
		return out
	end
	local o = ctx:my()
	if s.phase == Defs.PHASE_SPAWN or ctx:needs_spawn() then
		if o ~= nil and o.spawned and own == me then
			out.type = "inspect"
			out.ok = true
			return out
		end
		if map:is_contestable(tile) and own == 0 and not s:has_fallout(tile) then
			out.type = "spawn"
			out.ok = true
			out.verb = "Start here"
			out.icon = "target"
		else
			out.reason = if map:is_land(tile) then "Pick unclaimed land" else "Pick land, not water"
		end
		return out
	end
	if s.phase ~= Defs.PHASE_PLAYING or o == nil or not o.alive then
		out.type = "inspect"
		out.ok = own ~= 0
		return out
	end
	if own == me or (own ~= 0 and s:are_allies(me, own)) then
		out.type = "inspect"
		out.ok = true
		return out
	end
	if not map:is_contestable(tile) then
		out.reason = if ctx:terrain_at(tile) == Defs.T_ICECAP then "Antarctica cannot be claimed" else ""
		return out
	end
	-- Fallout stays until the land is conquered again; taking it is slow and costly.
	local fallout = own == 0 and s:has_fallout(tile)
	local share = ctx:order_ratio()
	local troops = (o.troops or 0) * share
	out.troops = troops
	if troops < 1.0 then
		-- (the tutorial's floor under the army: UICtx.troop_floor)
		out.reason = if share < ctx.ratio then UICtx.data("Tutorial").FLOOR_REASON else "No troops available"
		return out
	end
	local land = false
	if s:borders_tile(me, tile) then
		land = true
	elseif own == 0 then
		local touch = ctx.borders:region_touches_me(tile)
		land = touch == 1 or (touch == -1 and ctx.borders:borders_owner(0))
	else
		land = ctx.borders:borders_owner(own)
	end
	if land then
		out.type = if own == 0 then "expand" else "attack"
		out.ok = true
		out.verb = if own == 0 then (if fallout then "Expand into fallout" else "Expand") else "Attack"
		out.icon = "attack"
		return out
	end
	local landing = self:boat_landing(tile)
	if landing >= 0 then
		out.boat_tile = landing
		local max_boats = Rules().MAX_BOATS_PLAYER
		if self:transports() >= max_boats then
			out.type = "boat"
			out.reason = string.format("All %d transports at sea", max_boats)
			out.icon = "boat"
			return out
		end
		out.type = "boat"
		out.ok = true
		out.verb = "Boat invasion"
		out.icon = "boat"
		return out
	end
	out.reason = if own == 0 then "Out of reach: expand toward it" else "No border or sea route"
	return out
end

function UIRules.primary_intent(self: any, tile: number, action: { [string]: any }): { [string]: any }
	local ty = tostring(action.type or "")
	if ty == "spawn" then
		return { type = "spawn", tile = tile }
	elseif ty == "expand" or ty == "attack" then
		return { type = "attack", tile = tile, ratio = self.ctx:order_ratio() }
	elseif ty == "boat" then
		return { type = "boat", tile = tonumber(action.boat_tile) or tile, ratio = self.ctx:order_ratio() }
	end
	return {}
end

--- Short sentence for the floating confirmation ("Attacking Brazil with 24.5K").
function UIRules.confirm_text(self: any, action: { [string]: any }): string
	local s = self.ctx.state
	local troops = T().fmt_troops(tonumber(action.troops) or 0.0)
	local target = tonumber(action.target) or 0
	local ty = tostring(action.type or "")
	if ty == "spawn" then
		return "Starting position set"
	elseif ty == "expand" then
		return "Expanding with " .. troops
	elseif ty == "attack" then
		return string.format("Attacking %s with %s", s:owner_name(target), troops)
	elseif ty == "boat" then
		if target == 0 then
			return "Boat launched with " .. troops
		end
		return string.format("Invading %s by sea with %s", s:owner_name(target), troops)
	end
	return ""
end

-- ---------------------------------------------------------------------------------------------
-- Radial menu
-- ---------------------------------------------------------------------------------------------

--- Items: {id, label, icon, ok, reason, danger, sub: {items}}
--- A donation to ally `own` at the current attack ratio, limited to the ally's troop headroom.
--- The Sim accepts any amount (rule unchanged), but troops above the cap evaporate on the next tick
--- (Rules.troop_growth snaps to the cap), so the UI never sends more than fits (review P1-5).
--- Returns { amount, want, room, cap, capped (amount < want), full (no useful room: < 1 % of cap) }.
function UIRules.donate_plan(self: any, own: number): { [string]: any }
	local ctx = self.ctx
	local want = Defs.trunc(ctx:troops_for_ratio())
	local s = ctx.state
	local o = if s ~= nil and own ~= 0 then s:get_owner(own) else nil
	local cap = if o ~= nil then (tonumber(o.max_troops) or 0) else 0
	local room = want
	if cap > 0 then
		room = math.max(0, math.floor(cap - (tonumber(o.troops) or 0)))
	end
	local amount = math.max(0, math.min(want, room))
	return {
		amount = amount,
		want = want,
		room = room,
		cap = cap,
		capped = amount < want,
		full = cap > 0 and room < math.max(1.0, cap * 0.01),
	}
end

function UIRules.radial_items(self: any, tile: number): { { [string]: any } }
	local ctx = self.ctx
	local items = {}
	local s = ctx.state
	if s == nil or tile < 0 then
		return items
	end
	local me = ctx:me()
	local own = s:tile_owner(tile)
	local playing = s.phase == Defs.PHASE_PLAYING and ctx:alive_player() and not ctx:needs_spawn()
	local land = s.map:is_contestable(tile)

	if playing and land and own ~= me and not s:are_allies(me, own) then
		local p = self:primary(tile)
		local is_boat = tostring(p.type) == "boat"
		local verb = if own == 0 then "Expand" else "Attack"
		local atk =
			{ id = "attack", label = verb, icon = "attack", ok = p.ok and not is_boat, reason = "", danger = false }
		if is_boat then
			atk.reason = "No land border: send a boat"
		elseif not p.ok then
			atk.reason = tostring(p.reason)
		end
		table.insert(items, atk)
		local boat = { id = "boat", label = "Boat", icon = "boat", ok = false, reason = "", danger = false }
		if self:boat_landing(tile) < 0 then
			boat.reason = if s.map:is_coastal(tile)
				then "None of your coasts reach it"
				else "No coast of theirs within reach"
		elseif self:transports() >= Rules().MAX_BOATS_PLAYER then
			boat.reason = "All transports are at sea"
		elseif ctx:troops_for_ratio() < 1.0 then
			boat.reason = "No troops available"
		else
			boat.ok = true
		end
		table.insert(items, boat)
	end

	if playing and own ~= me and me ~= 0 then
		for _, a in s.attacks do
			if a.attacker == me and a.target == own then
				table.insert(
					items,
					{ id = "retreat", label = "Retreat", icon = "retreat", ok = true, reason = "", danger = false }
				)
				break
			end
		end
	end

	if playing and own == me then
		local sub = {}
		-- (the Arsenal's structures the player has unlocked come after the others)
		local build_kinds = table.clone(UIRules.BUILD_KINDS)
		for _, k in UIRules.ARSENAL_BUILD do
			if not self:arsenal_locked(k) then
				table.insert(build_kinds, k)
			end
		end
		for _, k in build_kinds do
			local av = self:availability(k)
			local pl = self:placement(k, tile)
			local ok = av.ok and pl.ok
			local reason = if not av.ok then tostring(av.reason) else tostring(pl.reason)
			table.insert(sub, {
				id = "build:" .. k,
				label = UIRules.SHORT[k],
				icon = k,
				ok = ok,
				reason = reason,
				danger = false,
				cost = av.cost,
				-- an existing structure here: level it up several times at once (bulk upgrade)
				sub = if ok and pl.upgrade then self:bulk_ring("build", k) else nil,
			})
		end
		table.insert(
			items,
			{ id = "build", label = "Build", icon = "city", ok = true, reason = "", danger = false, sub = sub }
		)
	end

	-- what can be launched at the tile: the bombs with a silo, and the Arsenal's munitions the player
	-- has unlocked (a strike with its own structure)
	local launch_kinds = {}
	if playing and own ~= me and me ~= 0 then
		local kinds = table.clone(UIRules.NUKE_KINDS)
		for _, k in UIRules.ARSENAL_NUKES do
			if not self:arsenal_locked(k) then
				table.insert(kinds, k)
			end
		end
		for _, k in kinds do
			if self:struct_count(UIRules.launcher(k)) > 0 then
				table.insert(launch_kinds, k)
			end
		end
	end
	if #launch_kinds > 0 then
		local nsub = {}
		for _, k2 in launch_kinds do
			local av2 = self:availability(k2)
			local pl2 = self:placement(k2, tile)
			local ok2 = av2.ok and pl2.ok
			table.insert(nsub, {
				id = "nuke:" .. k2,
				label = UIRules.SHORT[k2],
				icon = k2,
				ok = ok2,
				reason = if not av2.ok then tostring(av2.reason) else tostring(pl2.reason),
				danger = true,
				cost = av2.cost,
				-- atom bombs stack (x2 against a SAM): a bulk launch
				sub = if ok2 and k2 == "atom" then self:bulk_ring("nuke", k2) else nil,
			})
		end
		local only_strikes = self:struct_count(Defs.S_SILO) == 0
		table.insert(items, {
			id = "nuke",
			label = if only_strikes then "Strike" else "Nuke",
			icon = if only_strikes then launch_kinds[1] else "atom",
			ok = true,
			reason = "",
			danger = true,
			sub = nsub,
		})
	end

	if playing and own ~= 0 and own ~= me then
		local target_info = s:get_owner(own)
		if s:are_allies(me, own) then
			local plan = self:donate_plan(own)
			table.insert(items, {
				id = "donate",
				label = "Donate",
				icon = "donate",
				ok = plan.want >= 1 and not plan.full,
				reason = if plan.want < 1 then "No troops to spare" elseif plan.full then "At their troop cap" else "",
				danger = false,
				troops = plan.amount,
				capped = plan.capped,
			})
			-- the last ALLIANCE_EXTEND_WINDOW_TICKS: ask to renew (renewed once both asked)
			local ai = s:alliance_info(me, own)
			if ai ~= nil and ai.in_window then
				table.insert(items, {
					id = "ally_extend",
					label = "Renew",
					icon = "alliance",
					ok = ai.can_extend,
					reason = if ai.me_asked then "Renewal asked" else "",
					danger = false,
				})
			end
			-- (a teammate is no alliance: nothing to betray)
			if s:has_alliance(me, own) then
				table.insert(
					items,
					{ id = "ally_break", label = "Betray", icon = "betray", ok = true, reason = "", danger = true }
				)
			end
		elseif s:has_request(own, me) then
			table.insert(
				items,
				{ id = "ally_accept", label = "Accept", icon = "alliance", ok = true, reason = "", danger = false }
			)
		elseif s:has_request(me, own) then
			table.insert(items, {
				id = "ally_request",
				label = "Ally",
				icon = "alliance",
				ok = false,
				reason = "Request pending",
				danger = false,
			})
		elseif target_info ~= nil and target_info.alive then
			-- a new request waits 30 s after the previous one (Rules.ALLY_REQUEST_COOLDOWN_TICKS)
			local wait = s:request_cooldown_left(me, own)
			table.insert(items, {
				id = "ally_request",
				label = "Ally",
				icon = "alliance",
				ok = wait <= 0,
				reason = if wait > 0 then string.format("Wait %ds", math.ceil(wait / Defs.TICK_RATE)) else "",
				danger = false,
			})
		end
	end

	table.insert(items, { id = "focus", label = "Focus", icon = "eye", ok = true, reason = "", danger = false })
	if own ~= 0 then
		table.insert(items, { id = "info", label = "Info", icon = "info", ok = true, reason = "", danger = false })
	end
	return items
end

return UIRules
