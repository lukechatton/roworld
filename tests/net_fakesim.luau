-- A tiny stand-in for Core/Sim with the same public surface MatchServer / Session use (add_human,
-- remove_human, submit, step, snapshot, tick, phase). Its deltas/snapshots have the real shapes so
-- the client's real GameState loads and applies them.
-- Plays on a small real map (onion, 512 x 512) so the clients' GameState switches to it.
local MAP_ID = "onion"
local W = 512
local H = 512
local N = W * H
-- Load the map's data module now: Lune's require may yield, which must not happen inside the
-- Sessions' Coop jobs (the clients' GameState switches to this map from the snapshot).
require("./fixtures/fixture_maps") -- the test-only maps (Pangaea, Onion)
require("../src/shared/Core/WorldMap").load_data(MAP_ID)
local EV = { OWNER_ADD = 0, OWNER_OUT = 1, PHASE = 2, SPAWNED = 3, MSG = 19, GAME_OVER = 20 }

local FakeSim = {}
FakeSim.__index = FakeSim

function FakeSim.new(config)
	local self = setmetatable({}, FakeSim)
	self.config = config
	self.map_id = MAP_ID
	self.W = W
	self.tick = 0
	self.max_humans = config.max_humans or 0
	self.phase = if self.max_humans == 0 then 1 else 0
	self.spawn_left = config.spawn_ticks or 200
	self.over_at = config.over_at -- tick at which the fake match ends (tests)
	self.owner = buffer.create(N * 4)
	self.flags = buffer.create(N)
	self.names = {}
	self.kinds = {}
	self.alive = {}
	self.left = {}
	self.spawned = {}
	self.keys = {}
	self.humans = {}
	self.intents = {}
	self.ev = {}
	self.tiles = {}
	self.winner = 0
	self.over_reason = -1
	self.playing_since = if self.phase == 1 then 0 else -1
	for id = 1, 8 do
		self.names[id] = "Nation " .. id
		self.kinds[id] = 0
		self.alive[id] = true
		self.spawned[id] = true
		for k = 0, 99 do
			local t = (100 + id * 20) * W + 100 + k
			buffer.writei32(self.owner, t * 4, id)
		end
	end
	self.total = 8
	return self
end

function FakeSim:add_human(key, name)
	local old = self.keys[key]
	if old then
		if self.alive[old] then
			self.left[old] = false
			return old
		end
		if not self.spawned[old] then
			self.alive[old] = true
			self.left[old] = false
			table.insert(self.ev, { EV.OWNER_ADD, old, self.names[old], 0x11223344, 2, 0 })
			return old
		end
	end
	if #self.humans >= self.max_humans then
		return 0
	end
	self.total += 1
	local id = self.total
	self.names[id] = name
	self.kinds[id] = 2
	self.alive[id] = true
	self.spawned[id] = false
	self.keys[key] = id
	table.insert(self.humans, id)
	table.insert(self.ev, { EV.OWNER_ADD, id, name, 0x11223344, 2, 0 })
	return id
end

function FakeSim:remove_human(id)
	self.left[id] = true
	if not self.spawned[id] and self.alive[id] then
		self.alive[id] = false
		table.insert(self.ev, { EV.OWNER_OUT, id, 0 })
	end
end

function FakeSim:submit(id, intent)
	table.insert(self.intents, { id, intent })
end

function FakeSim:step()
	self.tick += 1
	if self.phase ~= 2 then
		for _, e in self.intents do
			local id, it = e[1], e[2]
			if it.type == "spawn" and not self.spawned[id] then
				self.spawned[id] = true
				local t = it.tile
				buffer.writei32(self.owner, t * 4, id)
				table.insert(self.tiles, t * 1024 + id)
				table.insert(self.ev, { EV.SPAWNED, id, t })
				table.insert(self.ev, { EV.MSG, id, 1, "You have landed. Expand into free land!" })
			elseif it.type == "attack" then
				local t = it.tile
				buffer.writei32(self.owner, t * 4, id)
				table.insert(self.tiles, t * 1024 + id)
			end
		end
		table.clear(self.intents)
		if self.phase == 0 then
			self.spawn_left -= 1
			if self.spawn_left <= 0 then
				self.phase = 1
				self.playing_since = self.tick
				table.insert(self.ev, { EV.PHASE, 1, 0 })
			end
		else
			-- a nation grows by one tile per tick
			local id = 1 + self.tick % 8
			local t = 400 * W + self.tick % W
			buffer.writei32(self.owner, t * 4, id)
			table.insert(self.tiles, t * 1024 + id)
			if self.tick % 20 == 0 then
				table.insert(self.ev, { EV.MSG, -1, 0, "Everyone hears this" })
				for _, h in self.humans do
					if not self.left[h] then
						table.insert(self.ev, { EV.MSG, h, 3, "Private note for " .. self.names[h] })
					end
				end
			end
			if self.over_at and self.tick >= self.over_at then
				self.winner = 1
				self.over_reason = 0
				table.insert(self.ev, { EV.GAME_OVER, 1, 0 })
				table.insert(self.ev, { EV.PHASE, 2, 0 })
				self.phase = 2
			end
		end
	else
		table.clear(self.intents)
	end
	local d = { t = self.tick, tiles = self.tiles, flags = {}, ev = self.ev }
	if self.tick % 5 == 0 then
		local stats = {}
		for id = 1, self.total do
			if self.alive[id] then
				for _, v in { id, 100, 5000, 1000, 90000, 40 } do
					table.insert(stats, v)
				end
			end
		end
		d.stats = stats
	end
	self.tiles = {}
	self.ev = {}
	return d
end

function FakeSim:snapshot()
	local owners = {}
	for id = 1, self.total do
		table.insert(owners, {
			id,
			self.names[id],
			0x55667788,
			self.kinds[id],
			0,
			self.alive[id],
			0,
			5000,
			1000,
			90000,
			40,
			0,
			if self.spawned[id] then 0 else -1,
		})
	end
	local owner = buffer.create(N * 4)
	buffer.copy(owner, 0, self.owner)
	local flags = buffer.create(N)
	buffer.copy(flags, 0, self.flags)
	return {
		map_id = MAP_ID,
		map_w = W,
		map_h = H,
		t = self.tick,
		phase = self.phase,
		phase_left = if self.phase == 0 then self.spawn_left else 0,
		time_limit_ticks = 0,
		playing_since = self.playing_since,
		mirvs_launched = 0,
		winner = self.winner,
		over_reason = self.over_reason,
		owner = owner,
		flags = flags,
		owners = owners,
		structs = {},
		built = {},
		roads = {},
		units = {},
		shells = {},
		sam_missiles = {},
		nukes = {},
		attacks = {},
		allies = {},
		requests = {},
	}
end

return FakeSim
