--!native
-- Troop counts on the local player's fronts (a label per attack front, floating over the map):
-- every 200 ms, for each attack by the local player on another owner (blue
-- #3fa9f5) and each attack on the local player by a player or nation, not a tribe (red #f87171),
-- the front is split into connected clusters (8-neighbours); the two largest (clusters under 30
-- full-size tiles dropped, the largest always kept) get a label with the attack's troops
-- (render_troops) at the front tile nearest the cluster's centroid. Labels glide to new positions
-- over 250 ms (snap beyond 200 full-size tiles) and keep a constant on-screen size.
--
-- The front: the label belongs on the attack's frontier, the whole shared border; the
-- client has no frontier, so it uses the local player's border tiles (UI BorderTracker, handed
-- over with set_borders) that touch the other owner.
local RS = game:GetService("ReplicatedStorage")
local Airfront = RS:WaitForChild("Airfront")
local Core = Airfront:WaitForChild("Core")
local Defs = require(Core:WaitForChild("Defs")) :: any
local Rules = require(Core:WaitForChild("Rules")) :: any
local NumberFormat = require(Core:WaitForChild("NumberFormat")) :: any
local FrameClock = require(script.Parent:WaitForChild("FrameClock")) :: any

local FrontLayer = {}
FrontLayer.__index = FrontLayer

FrontLayer.POLL_S = 0.2
FrontLayer.ANIM_S = 0.25
FrontLayer.SNAP_FULL = 200 -- full-size tiles
FrontLayer.MIN_CLUSTER_FULL = 30 -- full-size tiles
FrontLayer.MAX_CLUSTERS = 2
FrontLayer.OUTGOING = Color3.fromRGB(0x3f, 0xa9, 0xf5)
FrontLayer.INCOMING = Color3.fromRGB(0xf8, 0x71, 0x71)
FrontLayer.TEXT_PX = 17
FrontLayer.FONT = Font.fromId(12187365977, Enum.FontWeight.Bold)
FrontLayer.Z = 24

type Slot = { cx: number, cy: number, sx: number, sy: number, dx: number, dy: number, t0: number }
type Entry = { text: string, incoming: boolean, slots: { Slot }, seen: boolean }

function FrontLayer.new(parent: Instance, view: any)
	local self = setmetatable({}, FrontLayer) :: any
	local root = Instance.new("Frame")
	root.Name = "Fronts"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.ZIndex = FrontLayer.Z
	root.Parent = parent
	self.root = root
	self.view = view
	self._state = nil :: any
	self._borders = nil :: any
	--- aid -> label entry
	self._entries = {} :: { [number]: Entry }
	self._labels = {} :: { TextLabel }
	self._poll = 0.0
	return self
end

function FrontLayer.bind(self: any, state: any)
	self._state = state
	table.clear(self._entries)
	self._poll = 0.0
end

function FrontLayer.unbind(self: any)
	self._state = nil
	table.clear(self._entries)
	for _, l in self._labels do
		l.Visible = false
	end
end

function FrontLayer.destroy(self: any)
	self:unbind()
	self.root:Destroy()
end

--- The UI's BorderTracker (its `border` set holds the local player's border tiles).
function FrontLayer.set_borders(self: any, tracker: any)
	self._borders = tracker
end

--- Border tiles of the local player touching each owner in `wanted`: owner -> { tile }.
local function fronts_by_owner(st: any, border: { [number]: boolean }, wanted: { [number]: boolean }): { [number]: { number } }
	local out = {}
	local W = st.map.W or Defs.W
	local N = st.map.N or (W * (st.map.H or Defs.H))
	for t in border do
		local x = t % W
		local hit = 0
		local o = 0
		if x > 0 then
			o = st:tile_owner(t - 1)
			if wanted[o] then
				hit = o
			end
		end
		if hit == 0 and x < W - 1 then
			o = st:tile_owner(t + 1)
			if wanted[o] then
				hit = o
			end
		end
		if hit == 0 and t >= W then
			o = st:tile_owner(t - W)
			if wanted[o] then
				hit = o
			end
		end
		if hit == 0 and t + W < N then
			o = st:tile_owner(t + W)
			if wanted[o] then
				hit = o
			end
		end
		if hit ~= 0 then
			local list = out[hit]
			if list == nil then
				list = {}
				out[hit] = list
			end
			table.insert(list, t)
		end
	end
	return out
end

--- Representative tiles of the largest connected clusters of `tiles`.
local function clusters(tiles: { number }, W: number, min_size: number, max_n: number): { number }
	local set = {}
	for _, t in tiles do
		set[t] = true
	end
	local found = {}
	local seen = {}
	for _, start in tiles do
		if seen[start] then
			continue
		end
		seen[start] = true
		local queue = { start }
		local qi = 1
		local sx, sy = 0, 0
		while qi <= #queue do
			local t = queue[qi]
			qi += 1
			local x = t % W
			sx += x
			sy += t // W
			for dy = -1, 1 do
				for dx = -1, 1 do
					if dx == 0 and dy == 0 then
						continue
					end
					local nx = x + dx
					if nx < 0 or nx >= W then
						continue
					end
					local n = t + dy * W + dx
					if set[n] and not seen[n] then
						seen[n] = true
						table.insert(queue, n)
					end
				end
			end
		end
		local count = #queue
		local cx, cy = sx / count, sy / count
		local best, bd = queue[1], math.huge
		for _, t in queue do
			local ddx, ddy = t % W - cx, t // W - cy
			local d = ddx * ddx + ddy * ddy
			if d < bd then
				bd = d
				best = t
			end
		end
		table.insert(found, { tile = best, size = count })
	end
	table.sort(found, function(a, b)
		return a.size > b.size
	end)
	local out = {}
	for i, c in found do
		if #out >= max_n then
			break
		end
		if i == 1 or c.size >= min_size then
			table.insert(out, c.tile)
		end
	end
	return out
end

function FrontLayer._poll_fronts(self: any, now: number)
	local st = self._state
	local me = if st ~= nil then st.local_owner else 0
	local tracker = self._borders
	for _, e in self._entries do
		e.seen = false
	end
	if st == nil or me == 0 or tracker == nil or tracker.me ~= me then
		table.clear(self._entries)
		return
	end
	-- attacks worth a label (outgoing on players, incoming from non-tribe players)
	local wanted = {}
	local todo = {}
	for aid, a in st.attacks do
		local other = 0
		local incoming = false
		if a.attacker == me and a.target ~= 0 then
			other = a.target
		elseif a.target == me and a.attacker ~= 0 then
			local o = st:get_owner(a.attacker)
			if o ~= nil and o.kind ~= Defs.KIND_TRIBE then
				other = a.attacker
				incoming = true
			end
		end
		if other ~= 0 then
			wanted[other] = true
			table.insert(todo, { aid = aid, other = other, incoming = incoming, troops = a.troops })
		end
	end
	if #todo > 0 then
		local k = tonumber(st.map.k_lin) or Rules.K_LIN
		local W = st.map.W or Defs.W
		local fronts = fronts_by_owner(st, tracker.border, wanted)
		local snap = FrontLayer.SNAP_FULL / k
		for _, a in todo do
			local tiles = fronts[a.other]
			if tiles == nil then
				continue
			end
			local reps = clusters(tiles, W, FrontLayer.MIN_CLUSTER_FULL / k, FrontLayer.MAX_CLUSTERS)
			local e = self._entries[a.aid]
			if e == nil then
				e = { text = "", incoming = a.incoming, slots = {}, seen = true }
				self._entries[a.aid] = e
			end
			e.seen = true
			e.incoming = a.incoming
			e.text = NumberFormat.render_troops(a.troops)
			local slots = e.slots
			-- keep two labels on their own clusters (swapped when that is shorter)
			if #reps == 2 and #slots == 2 then
				local function d(s: Slot, t: number): number
					return math.abs(s.dx - (t % W + 0.5)) + math.abs(s.dy - (t // W + 0.5))
				end
				if d(slots[1], reps[2]) + d(slots[2], reps[1]) < d(slots[1], reps[1]) + d(slots[2], reps[2]) then
					reps[1], reps[2] = reps[2], reps[1]
				end
			end
			while #slots > #reps do
				table.remove(slots)
			end
			for i, t in reps do
				local nx, ny = t % W + 0.5, t // W + 0.5
				local s = slots[i]
				if s == nil then
					slots[i] = { cx = nx, cy = ny, sx = nx, sy = ny, dx = nx, dy = ny, t0 = now }
					continue
				end
				local f = math.min(1, (now - s.t0) / FrontLayer.ANIM_S)
				local cx, cy = s.sx + (s.dx - s.sx) * f, s.sy + (s.dy - s.sy) * f
				if math.sqrt((nx - cx) ^ 2 + (ny - cy) ^ 2) > snap then
					cx, cy = nx, ny
				end
				s.sx, s.sy, s.cx, s.cy = cx, cy, cx, cy
				s.dx, s.dy, s.t0 = nx, ny, now
			end
		end
	end
	for aid, e in self._entries do
		if not e.seen then
			self._entries[aid] = nil
		end
	end
end

local function label(self: any, n: number): TextLabel
	local l = self._labels[n]
	if l ~= nil then
		return l
	end
	l = Instance.new("TextLabel")
	l.Name = "FrontTroops"
	l.BackgroundTransparency = 1
	l.AnchorPoint = Vector2.new(0.5, 0.5)
	l.AutomaticSize = Enum.AutomaticSize.XY
	l.Size = UDim2.fromOffset(0, 0)
	l.FontFace = FrontLayer.FONT
	l.TextSize = FrontLayer.TEXT_PX
	l.ZIndex = FrontLayer.Z
	l.Parent = self.root
	local s = Instance.new("UIStroke")
	s.Color = Color3.new(0, 0, 0)
	s.Thickness = 1.5
	s.LineJoinMode = Enum.LineJoinMode.Round
	s.Parent = l
	self._labels[n] = l
	return l
end

function FrontLayer.tick(self: any, dt: number)
	local now = FrameClock.now()
	self._poll -= dt
	if self._poll <= 0 then
		self._poll = FrontLayer.POLL_S
		self:_poll_fronts(now)
	end
	local cam = self.view.rig
	local n = 0
	for _, e in self._entries do
		for _, s in e.slots do
			local f = math.min(1, (now - s.t0) / FrontLayer.ANIM_S)
			s.cx = s.sx + (s.dx - s.sx) * f
			s.cy = s.sy + (s.dy - s.sy) * f
			local x, y = cam:map_to_screen(s.cx, s.cy)
			if not cam:on_screen(x, y, 40) then
				continue
			end
			n += 1
			local l = label(self, n)
			l.Visible = true
			l.Text = e.text
			l.TextColor3 = if e.incoming then FrontLayer.INCOMING else FrontLayer.OUTGOING
			l.Position = UDim2.fromOffset(x, y)
		end
	end
	for j = n + 1, #self._labels do
		local l = self._labels[j]
		if l.Visible then
			l.Visible = false
		end
	end
end

return FrontLayer
