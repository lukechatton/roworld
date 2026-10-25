--!native
-- Port of scripts/ui/border_tracker.gd (class UIBorders)
-- Incrementally tracks the local player's border tiles so the UI can answer "do I border this
-- owner?" and "can a boat reach that coast?" instantly (the Sim still validates everything).

-- Flat maps: the grid size comes from the bound state's map; tiles on an edge simply have
-- fewer neighbours (nothing wraps).
local F_FALLOUT = 1

local BorderTracker = {}
BorderTracker.__index = BorderTracker

function BorderTracker.new()
	local self = setmetatable({}, BorderTracker)
	self.state = nil :: any
	self.me = 0
	--- Local player's tiles that touch at least one tile they do not own (incl. water): set.
	self.border = {} :: { [number]: boolean }
	self._neighbours = {} :: { [number]: boolean }
	self._bodies = {} :: { [number]: boolean }
	self._touches_neutral = false
	self._dirty = true
	self._computed_msec = -100000
	self.W = 1
	self.H = 1
	--- scratch: the 4-neighbours of a tile (count in _nn)
	self._nb = table.create(4, 0)
	self._nn = 0
	return self
end

--- Fills self._nb[1.._nn] with the in-map 4-neighbours of tile i.
function BorderTracker._neighbours4(self: any, i: number)
	local W = self.W
	local x = i % W
	local nb = self._nb
	local n = 0
	if x > 0 then
		n += 1
		nb[n] = i - 1
	end
	if x < W - 1 then
		n += 1
		nb[n] = i + 1
	end
	if i >= W then
		n += 1
		nb[n] = i - W
	end
	if i < W * (self.H - 1) then
		n += 1
		nb[n] = i + W
	end
	self._nn = n
end

local function msec(): number
	return os.clock() * 1000.0
end

-- Owner grid accessor: Core keeps per-tile grids as i32 buffers.
local function owner_at(own: any, i: number): number
	if typeof(own) == "buffer" then
		return buffer.readi32(own, i * 4)
	end
	return own[i] or 0
end

local function u8(grid: any, i: number): number
	if typeof(grid) == "buffer" then
		return buffer.readu8(grid, i)
	end
	return grid[i] or 0
end

--- Water body of a coastal tile (maps store 16-bit bodies; older mirrors a u8 grid).
local function coast_body_of(map: any, i: number): number
	if type(map.coast_body_of) == "function" then
		return map:coast_body_of(i)
	end
	return u8(map.coast_body, i)
end

function BorderTracker.bind(self: any, s: any, owner_id: number)
	self.state = s
	self.me = owner_id
	table.clear(self.border)
	self._dirty = true
	if s ~= nil and s.map ~= nil then
		self.W = s.map.W or s.map.width or 1
		self.H = s.map.H or s.map.height or 1
	end
	local TILE_COUNT = self.W * self.H
	if s == nil or owner_id <= 0 then
		return
	end
	local o = s:get_owner(owner_id)
	if o == nil or (o.tiles or 0) <= 0 then
		return
	end
	local own = s.owner
	local border = self.border
	if typeof(own) == "buffer" then
		for i = 0, TILE_COUNT - 1 do
			if buffer.readi32(own, i * 4) == owner_id and self:_is_border(i) then
				border[i] = true
			end
		end
	else
		for i = 0, TILE_COUNT - 1 do
			if (own[i] or 0) == owner_id and self:_is_border(i) then
				border[i] = true
			end
		end
	end
end

--- `changed` holds packed (tile << 10) | owner values (buffer of i32 or a Luau array).
function BorderTracker.on_tiles_changed(self: any, changed: any)
	if self.state == nil or self.me <= 0 then
		return
	end
	if typeof(changed) == "buffer" then
		local n = buffer.len(changed) // 4
		for k = 0, n - 1 do
			self:_on_change(buffer.readi32(changed, k * 4))
		end
	else
		for _, v in changed do
			self:_on_change(v)
		end
	end
end

function BorderTracker._on_change(self: any, v: number)
	local own = self.state.owner
	local me = self.me
	local border = self.border
	local i = v // 1024
	local nw = v % 1024
	local mine_now = nw == me
	self:_neighbours4(i)
	local nb, nn = self._nb, self._nn
	if not mine_now and not border[i] then
		-- Fast reject: a change between other owners that does not touch our land.
		local touches = false
		for k = 1, nn do
			if owner_at(own, nb[k]) == me then
				touches = true
				break
			end
		end
		if not touches then
			return
		end
	end
	if mine_now then
		if self:_is_border(i) then
			border[i] = true
		else
			border[i] = nil
		end
	else
		border[i] = nil
	end
	-- Neighbours that belong to us may have gained or lost border status.
	self:_neighbours4(i)
	local ns = table.clone(self._nb)
	for k = 1, self._nn do
		self:_recheck(ns[k], own, mine_now)
	end
	self._dirty = true
end

function BorderTracker._recheck(self: any, n: number, own: any, changed_is_mine: boolean)
	if owner_at(own, n) ~= self.me then
		return
	end
	if not changed_is_mine then
		self.border[n] = true
	elseif self.border[n] and not self:_is_border(n) then
		self.border[n] = nil
	end
end

function BorderTracker._is_border(self: any, i: number): boolean
	local own = self.state.owner
	local me = self.me
	self:_neighbours4(i)
	local nb = self._nb
	for k = 1, self._nn do
		if owner_at(own, nb[k]) ~= me then
			return true
		end
	end
	return false
end

function BorderTracker._refresh(self: any)
	if not self._dirty then
		return
	end
	local now = msec()
	if now - self._computed_msec < 400 and next(self._neighbours) ~= nil then
		return
	end
	self._computed_msec = now
	self._dirty = false
	table.clear(self._neighbours)
	table.clear(self._bodies)
	self._touches_neutral = false
	local s = self.state
	if s == nil then
		return
	end
	local own = s.owner
	local map = s.map
	local coastal = map.coastal
	for i in self.border do
		self:_neighbours4(i)
		local nb = self._nb
		for k = 1, self._nn do
			local t = nb[k]
			self:_note(owner_at(own, t), t, map)
		end
		if u8(coastal, i) == 1 then
			self._bodies[coast_body_of(map, i)] = true
		end
	end
end

function BorderTracker._note(self: any, o: number, t: number, map: any)
	if o == self.me then
		return
	end
	if o == 0 then
		if
			not self._touches_neutral
			and map:is_contestable(t)
			and bit32.band(u8(self.state.flags, t), F_FALLOUT) == 0
		then
			self._touches_neutral = true
		end
		return
	end
	self._neighbours[o] = true
end

--- True when we share a land border with `id` (0 = any claimable neutral land).
function BorderTracker.borders_owner(self: any, id: number): boolean
	self:_refresh()
	if id == 0 then
		return self._touches_neutral
	end
	return self._neighbours[id] == true
end

--- Neighbour owner ids, ascending (deterministic order).
function BorderTracker.neighbour_ids(self: any): { number }
	self:_refresh()
	local out = {}
	for k in self._neighbours do
		table.insert(out, k)
	end
	table.sort(out)
	return out
end

function BorderTracker.has_coast(self: any): boolean
	self:_refresh()
	return next(self._bodies) ~= nil
end

--- A transport can sail from our coast to `tile` (coastal land on a water body we touch).
function BorderTracker.can_reach_by_sea(self: any, tile: number): boolean
	local s = self.state
	if s == nil or tile < 0 then
		return false
	end
	self:_refresh()
	local map = s.map
	return u8(map.coastal, tile) == 1 and self._bodies[coast_body_of(map, tile)] == true
end

--- Flood-fills the clicked owner's region from `tile` (bounded) to see whether it touches us
--- by land. Returns 1 = touches, 0 = region fully explored without contact, -1 = budget exhausted.
function BorderTracker.region_touches_me(self: any, tile: number, budget: number?): number
	local s = self.state
	if s == nil or self.me <= 0 or tile < 0 then
		return 0
	end
	local lim = budget or 3000
	local own = s.owner
	local me = self.me
	local target = owner_at(own, tile)
	local map = s.map
	local seen = { [tile] = true }
	local queue = { tile }
	local head = 1
	local ns = table.create(4, 0)
	while head <= #queue do
		if head - 1 >= lim then
			return -1
		end
		local i = queue[head]
		head += 1
		self:_neighbours4(i)
		local cnt = self._nn
		for k = 1, cnt do
			ns[k] = self._nb[k]
		end
		for k = 1, cnt do
			local n = ns[k]
			local o = owner_at(own, n)
			if o == me then
				return 1
			end
			if o == target and not seen[n] and map:is_contestable(n) then
				seen[n] = true
				table.insert(queue, n)
			end
		end
	end
	return 0
end

return BorderTracker
