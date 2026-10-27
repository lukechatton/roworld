--!native
-- Range rings on the 2D map: SAM interception coverage and defense-post protection radius, the
-- prospective ring while placing one, and the selected warship's patrol / targeting rings. The
-- choice of rings is the globe RangeLayer's (View/RangeLayer.luau _rebuild), drawn as flat GUI
-- circles (UIStroke keeps widths pixel-constant) with a faint fill:
--   mode "auto" (default): own SAMs / posts faint, fading out as the view pulls back; while aiming
--   a nuke the hostile SAMs within NEAR_AIM x their range of the aim tile (red-tinted) and those
--   covering it (hot: thicker, pulsing; aim_sams() counts them); boat aim / "attack_aim": the
--   target owner's posts; hovered / focused sites; the build preview ring (+ own rings of that
--   kind at full strength). "nuke_aim", "all", "none" as in the globe layer.
-- (2026-10-26, phones' slow frames: a ring remembers what it was last given and is written only what
-- changed, where every ring on screen was written eight properties a frame; the rings are chosen
-- again only when what they show changes: not for a missile fired, and while a SAM's range grows
-- after an upgrade only that ring's radius follows it, a game tick at a time.)
local RS = game:GetService("ReplicatedStorage")
local Airfront = RS:WaitForChild("Airfront")
local Defs = require(Airfront:WaitForChild("Core"):WaitForChild("Defs")) :: any

local RangeLayer = {}
RangeLayer.__index = RangeLayer

RangeLayer.NEAR_AIM = 2.0
RangeLayer.MAX_RINGS = 300
RangeLayer.Z = 8

local C_OWN_SAM, C_OWN_DEF, C_OWN_HI, C_HOSTILE, C_HOT, C_FOCUS, C_BUILD, C_ALL, C_PENDING = 0, 1, 2, 3, 4, 5, 6, 7, 8
-- per class (index cls + 1): stroke alpha, stroke width (px), fill alpha, pulses
local RING_A = { 0.62, 0.55, 0.92, 0.62, 1.0, 0.95, 1.0, 0.6, 0.7 }
local WIDTH = { 1.5, 1.5, 2.0, 2.0, 3.0, 2.2, 2.6, 1.5, 1.6 }
local FILL_A = { 0.045, 0.04, 0.075, 0.03, 0.055, 0.085, 0.2, 0.03, 0.0 }
local PULSE = { false, false, false, false, true, false, true, false, false }
-- own idle rings fade out between these globe-equivalent camera distances
local OWN_SAM_FADE = { 1.9, 2.5 }
local OWN_DEF_FADE = { 1.42, 1.72 }

--- Structure kinds with a ring: SAMs, defense posts, and the Arsenal's Artillery (its range) and
--- Airfields (their reach, shown while an air strike is aimed or an airfield is placed).
local RINGED = {
	[Defs.S_SAM] = true,
	[Defs.S_DEFENSE] = true,
	[Defs.S_ARTILLERY] = true,
	[Defs.S_AIRFIELD] = true,
}

local HOSTILE_TINT = Color3.new(1.0, 0.2, 0.16)
local WHITE = Color3.new(1, 1, 1)
local HOT_COLOR = HOSTILE_TINT:Lerp(Color3.new(1.0, 0.45, 0.35), 0.25)
--- a site without levels yet (read only)
local NO_LVL = { 1, 0, -100000 }

--- A ring and what its frame and stroke were last given (Roblox's own values, kept here: a ring
--- shown for another site still shows them, so nothing needs resetting).
type Ring = {
	frame: Frame,
	stroke: UIStroke,
	vis: boolean,
	x: number,
	y: number,
	d: number,
	col: Color3?,
	fill_t: number,
	stroke_col: Color3?,
	width: number,
	stroke_t: number,
}
--- A ring to draw: map tile, radius (tiles), class, colour; `sid` a SAM's, `grows` while its range
--- grows after an upgrade (kept from one choice to the next: rewritten, not made again).
type Want = { tile: number, r: number, cls: number, col: Color3, sid: number, grows: boolean }

function RangeLayer.new(parent: Instance, view: any)
	local self = setmetatable({}, RangeLayer) :: any
	local root = Instance.new("Frame")
	root.Name = "Ranges"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.ZIndex = RangeLayer.Z
	root.Parent = parent
	self.root = root
	self.view = view
	self.VR = view.view_rules
	self.mode = "auto"
	self._state = nil :: any
	self._sites = {} :: { [number]: { number } } -- sid -> { kind, owner, tile }
	self._lvl = {} :: { [number]: { number } } -- sid -> { level, active_tick, upgrade_tick }
	self._hot = {} :: { [number]: boolean }
	self._hot_n = 0
	self._aim_kind = ""
	self._aim_tile = -1
	self._aim_detail = ""
	self._aim_level = 1
	self._range_owner = 0
	self._hover_owner = 0
	self._hover_focus = -1
	self._ui_focus = -1
	--- the rings to draw: the first _want_n of _want
	self._want = {} :: { Want }
	self._want_n = 0
	self._dirty = true
	self._next_change = math.huge
	--- the game tick the growing SAM rings' radii are for (nil: none grows)
	self._grow_tick = nil :: number?
	self._last_local = -1
	self._rings = {} :: { Ring }
	self._unit = nil :: any
	--- (the selected warship's rings, rewritten every frame it is selected)
	self._unit_rings = {} :: { [string]: any }
	self._now = 0.0
	return self
end

function RangeLayer.bind(self: any, state: any)
	self._state = state
	self:reload()
end

function RangeLayer.unbind(self: any)
	self._state = nil
	table.clear(self._sites)
	table.clear(self._lvl)
	table.clear(self._hot)
	self._hot_n = 0
	self._hover_focus = -1
	self._ui_focus = -1
	table.clear(self._want)
	self._want_n = 0
	self._grow_tick = nil
	self._unit = nil
	for _, r in self._rings do
		if r.vis then
			r.vis = false
			r.frame.Visible = false
		end
	end
end

function RangeLayer.destroy(self: any)
	self:unbind()
	self.root:Destroy()
end

function RangeLayer.reload(self: any)
	table.clear(self._sites)
	table.clear(self._lvl)
	if self._state ~= nil then
		for _, s in self._state.structures do
			if RINGED[s.kind] then
				self._sites[s.sid] = { s.kind, s.owner, s.tile }
				self._lvl[s.sid] = { s.level, s.active_tick, -100000 }
			end
		end
	end
	self._dirty = true
end

function RangeLayer.on_structure_added(self: any, sid: number)
	local s = if self._state ~= nil then self._state.structures[sid] else nil
	if s ~= nil and RINGED[s.kind] then
		self._sites[sid] = { s.kind, s.owner, s.tile }
		if self._lvl[sid] == nil then
			self._lvl[sid] = { s.level, s.active_tick, -100000 }
		end
		self._dirty = true
	end
end

function RangeLayer.on_structure_leveled(self: any, sid: number)
	local s = if self._state ~= nil then self._state.structures[sid] else nil
	if s == nil or self._sites[sid] == nil then
		return
	end
	local was = self._lvl[sid]
	if was ~= nil and was[1] == s.level and was[2] == s.active_tick then
		-- a missile fired or reloaded (Ev.STRUCT_SHOTS comes as structure_leveled too): the range is
		-- as it was, and choosing every ring again for each shot of a late game's SAM wall cost the most
		return
	end
	local old = was or { s.level, s.active_tick, -100000 }
	local up = old[3]
	if s.level > old[1] then
		up = self._state.tick
	end
	self._lvl[sid] = { s.level, s.active_tick, up }
	self._dirty = true
end

function RangeLayer.on_structure_changed(self: any, sid: number)
	self:on_structure_added(sid)
end

function RangeLayer.on_structure_removed(self: any, sid: number)
	self._lvl[sid] = nil
	if self._sites[sid] ~= nil then
		self._sites[sid] = nil
		self._dirty = true
	end
end

function RangeLayer.mark_dirty(self: any)
	self._dirty = true
end

function RangeLayer.set_mode(self: any, m: string)
	if m ~= self.mode then
		self.mode = m
		self._dirty = true
	end
end

function RangeLayer.set_aim(self: any, kind: string, tile: number, detail: string, level: number?): number
	local lv = math.max(level or 1, 1)
	if kind ~= self._aim_kind or tile ~= self._aim_tile or detail ~= self._aim_detail or lv ~= self._aim_level then
		self._aim_kind, self._aim_tile, self._aim_detail, self._aim_level = kind, tile, detail or "", lv
		self._dirty = true
		self:_update_hot()
	end
	return self._hot_n
end

function RangeLayer.aim_sams(self: any): number
	return self._hot_n
end

function RangeLayer.set_range_owner(self: any, id: number)
	if id ~= self._range_owner then
		self._range_owner = id
		self._dirty = true
	end
end

function RangeLayer.set_hover_owner(self: any, id: number)
	if id ~= self._hover_owner then
		self._hover_owner = id
		if self.mode == "attack_aim" and self._range_owner == 0 then
			self._dirty = true
		end
	end
end

function RangeLayer.set_hover_tile(self: any, tile: number, px_tiles: number)
	local f = self:_sites_near(tile, px_tiles)
	if f ~= self._hover_focus then
		self._hover_focus = f
		self._dirty = true
	end
end

function RangeLayer.set_focus_tile(self: any, tile: number, px_tiles: number)
	local f = self:_sites_near(tile, px_tiles)
	if f ~= self._ui_focus then
		self._ui_focus = f
		self._dirty = true
	end
end

--- Selected warship: patrol ring around map point (pu, pv) and targeting ring around (au, av), radii
--- in tiles, `col` its owner's colour. (Called every frame a warship is selected: plain numbers and
--- one table kept, the tints worked out when the colour changes.)
function RangeLayer.set_unit_rings(
	self: any,
	pu: number,
	pv: number,
	patrol_r: number,
	au: number,
	av: number,
	target_r: number,
	col: Color3
)
	local ur = self._unit_rings
	ur.pu, ur.pv, ur.patrol_r = pu, pv, patrol_r
	ur.au, ur.av, ur.target_r = au, av, target_r
	if ur.col ~= col then
		ur.col = col
		ur.patrol_col = col:Lerp(WHITE, 0.4)
		ur.target_col = col:Lerp(WHITE, 0.3)
	end
	self._unit = ur
end

function RangeLayer.clear_unit_rings(self: any)
	self._unit = nil
end

-- ---------------------------------------------------------------------------------------------
-- Rules
-- ---------------------------------------------------------------------------------------------

function RangeLayer._build_kind(self: any): number
	local ak, det = self._aim_kind, self._aim_detail
	if ak == "build" or string.sub(ak, 1, 6) == "build:" then
		local k = if det ~= "" then det else string.sub(ak, 7)
		if k == "sam" then
			return Defs.S_SAM
		elseif k == "defense" then
			return Defs.S_DEFENSE
		elseif k == "factory" then
			return Defs.S_FACTORY
		elseif k == "artillery" then
			return Defs.S_ARTILLERY
		elseif k == "airfield" then
			return Defs.S_AIRFIELD
		end
	elseif ak == "sam" then
		return Defs.S_SAM
	elseif ak == "defense" then
		return Defs.S_DEFENSE
	end
	return -1
end

function RangeLayer._nuke_kind(self: any): number
	for k = 0, Defs.NUKE_KIND_COUNT - 1 do
		if Defs.NUKE_NAMES[k] == self._aim_detail then
			return k
		end
	end
	return -1
end

function RangeLayer._hostile(self: any, owner_id: number, local_id: number): boolean
	return owner_id ~= local_id and not self._state:are_allies(owner_id, local_id)
end

function RangeLayer._range_of(self: any, sid: number, kind: number, cur: number): number
	local VR = self.VR
	if kind == Defs.S_ARTILLERY then
		return VR.artillery_range()
	elseif kind == Defs.S_AIRFIELD then
		return VR.airfield_range()
	elseif kind ~= Defs.S_SAM then
		return VR.defense_range()
	end
	local l = self._lvl[sid] or NO_LVL
	return VR.sam_range_at(l[1], cur - l[3])
end

function RangeLayer._update_hot(self: any)
	table.clear(self._hot)
	self._hot_n = 0
	local state = self._state
	local VR = self.VR
	if state == nil or VR == nil or self._aim_kind ~= "nuke" or self._aim_tile < 0 then
		return
	end
	local nk = self:_nuke_kind()
	local mirv = nk == Defs.N_MIRV
	if nk >= 0 and VR.intercept_p(if mirv then Defs.N_WARHEAD else nk) <= 0.0 then
		return
	end
	local local_id = state.local_owner
	local cur = math.floor(state.render_tick)
	local tg = if mirv then state:tile_owner(self._aim_tile) else 0
	local _, spread = VR.nuke_radii(Defs.N_MIRV)
	for sid, s in self._sites do
		local l = self._lvl[sid]
		if s[1] ~= Defs.S_SAM or not self:_hostile(s[2], local_id) or (l ~= nil and l[2] > cur) then
			continue
		end
		local r = self:_range_of(sid, s[1], cur)
		local d2 = VR.range_d2(s[3], self._aim_tile)
		if d2 <= r * r or (mirv and tg ~= 0 and s[2] == tg and d2 <= (spread + r) * (spread + r)) then
			self._hot[sid] = true
			self._hot_n += 1
		end
	end
end

function RangeLayer._sites_near(self: any, tile: number, px_tiles: number): number
	local st = self._state
	if tile < 0 or st == nil then
		return -1
	end
	local W = st.map.W or Defs.W
	local rr = math.max(px_tiles, 1.5)
	local best = rr * rr
	local best_sid = -1
	local tx, ty = tile % W, tile // W
	for sid, s in self._sites do
		local dx = s[3] % W - tx
		local dy = s[3] // W - ty
		local d = dx * dx + dy * dy
		if d <= best then
			best = d
			best_sid = sid
		end
	end
	return best_sid
end

--- The next ring to draw (the list's records are kept from one choice to the next).
local function push(self: any, tile: number, r: number, cls: number, col: Color3, sid: number, grows: boolean)
	local n = self._want_n + 1
	self._want_n = n
	local w = self._want[n]
	if w == nil then
		w = {} :: any
		self._want[n] = w
	end
	w.tile, w.r, w.cls, w.col, w.sid, w.grows = tile, r, cls, col, sid, grows
end

function RangeLayer._rebuild(self: any)
	local state = self._state
	local VR = self.VR
	self._want_n = 0
	self._grow_tick = nil
	if state == nil or VR == nil then
		return
	end
	local local_id = state.local_owner
	local cur = math.floor(state.render_tick)
	self._next_change = math.huge
	local grow_ticks = VR.sam_upgrade_ticks()
	local mode = self.mode
	local auto = mode ~= "none"
	local aiming_nuke = self._aim_kind == "nuke" and self._aim_tile >= 0
	local nuke_aim = (aiming_nuke and mode ~= "none") or mode == "nuke_aim"
	local atk = 0
	if self._aim_kind == "boat" and self._aim_tile >= 0 then
		atk = state:tile_owner(self._aim_tile)
	elseif mode == "attack_aim" then
		atk = if self._range_owner ~= 0 then self._range_owner else self._hover_owner
	end
	if atk == local_id then
		atk = 0
	end
	local bk = self:_build_kind()
	local upgrading = bk >= 0 and self._aim_tile >= 0 and self._aim_level > 1
	local NEAR2 = RangeLayer.NEAR_AIM * RangeLayer.NEAR_AIM
	for sid, s in self._sites do
		if self._want_n >= RangeLayer.MAX_RINGS - 1 then
			break
		end
		if upgrading and s[3] == self._aim_tile and s[1] == bk then
			continue
		end
		local l = self._lvl[sid] or NO_LVL
		local pending = l[2] > cur
		local grows = false
		if pending then
			self._next_change = math.min(self._next_change, l[2])
		elseif s[1] == Defs.S_SAM and cur - l[3] < grow_ticks then
			if aiming_nuke then
				-- (the hot SAMs and those near the aim follow the radius: all chosen again each tick)
				self._next_change = cur + 1
			else
				-- (only its radius changes: tick() follows it, _regrow)
				grows = true
			end
		end
		local r = self:_range_of(sid, s[1], cur)
		local own = local_id ~= 0 and s[2] == local_id
		local hostile = not own and self:_hostile(s[2], local_id)
		local cls = -1
		if s[1] == Defs.S_SAM then
			if nuke_aim and hostile then
				if self._hot[sid] then
					cls = C_HOT
				elseif not aiming_nuke or VR.range_d2(s[3], self._aim_tile) <= NEAR2 * r * r then
					cls = C_HOSTILE
				end
			elseif own and bk == Defs.S_SAM then
				cls = C_OWN_HI
			elseif own and auto then
				cls = C_OWN_SAM
			end
		elseif s[1] == Defs.S_ARTILLERY then
			-- a battery's range: yours faint (like a post's), bright while you place another
			if own and bk == Defs.S_ARTILLERY then
				cls = C_OWN_HI
			elseif own and auto then
				cls = C_OWN_DEF
			end
		elseif s[1] == Defs.S_AIRFIELD then
			-- an airfield's reach: only while you aim an air strike or place another airfield
			if own and (bk == Defs.S_AIRFIELD or (aiming_nuke and self._aim_detail == "airstrike")) then
				cls = C_OWN_HI
			end
		else
			if atk ~= 0 and s[2] == atk then
				cls = C_HOSTILE
			elseif own and bk == Defs.S_DEFENSE then
				cls = C_OWN_HI
			elseif own and auto then
				cls = C_OWN_DEF
			end
		end
		if (cls < C_HOSTILE or cls == C_ALL) and ((auto and self._hover_focus == sid) or self._ui_focus == sid) then
			cls = C_FOCUS
		end
		if cls < 0 and mode == "all" then
			cls = C_ALL
		end
		if cls < 0 then
			continue
		end
		if pending then
			cls = C_PENDING
		end
		local col = state:owner_color(s[2])
		if cls == C_OWN_SAM or cls == C_OWN_DEF or cls == C_OWN_HI then
			col = col:Lerp(WHITE, 0.4)
		elseif cls == C_HOSTILE then
			col = col:Lerp(HOSTILE_TINT, 0.62)
		elseif cls == C_HOT then
			col = HOT_COLOR
		elseif cls == C_FOCUS then
			col = if hostile then col:Lerp(HOSTILE_TINT, 0.55) else col:Lerp(WHITE, 0.3)
		else
			col = if hostile then col:Lerp(HOSTILE_TINT, 0.35) else col:Lerp(WHITE, 0.3)
		end
		push(self, s[3], r, cls, col, sid, grows)
		if grows then
			self._grow_tick = cur
		end
	end
	if bk >= 0 and self._aim_tile >= 0 then
		-- the ghost's range is a white disc (20 % fill) with a bright edge
		local bc = WHITE
		push(
			self,
			self._aim_tile,
			if bk == Defs.S_SAM
				then VR.sam_range(self._aim_level)
				elseif bk == Defs.S_FACTORY then VR.factory_range()
				elseif bk == Defs.S_ARTILLERY then VR.artillery_range()
				elseif bk == Defs.S_AIRFIELD then VR.airfield_range()
				else VR.defense_range(),
			C_BUILD,
			bc,
			-1,
			false
		)
	end
end

--- A game tick on while SAM rings grow after an upgrade (nothing else changed): their radii follow
--- it, as a full _rebuild would have made them.
function RangeLayer._regrow(self: any, cur: number)
	local grow_ticks = self.VR.sam_upgrade_ticks()
	local any = false
	local want = self._want
	for i = 1, self._want_n do
		local w = want[i]
		if not w.grows then
			continue
		end
		w.r = self:_range_of(w.sid, Defs.S_SAM, cur)
		local l = self._lvl[w.sid] or NO_LVL
		if cur - l[3] < grow_ticks then
			any = true
		else
			w.grows = false
		end
	end
	self._grow_tick = if any then cur else nil
end

-- ---------------------------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------------------------

function RangeLayer._ring(self: any, i: number): Ring
	local r = self._rings[i]
	if r then
		return r
	end
	local f = Instance.new("Frame")
	f.Name = "Ring"
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.BorderSizePixel = 0
	f.ZIndex = RangeLayer.Z
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0.5, 0)
	c.Parent = f
	local s = Instance.new("UIStroke")
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = f
	f.Parent = self.root
	-- (what a new Frame and UIStroke show: every value is written on the first draw)
	r = {
		frame = f,
		stroke = s,
		vis = true,
		x = math.huge,
		y = math.huge,
		d = -1,
		col = nil,
		fill_t = -1,
		stroke_col = nil,
		width = -1,
		stroke_t = -1,
	}
	self._rings[i] = r
	return r
end

local function smoothstep(a: number, b: number, x: number): number
	local t = math.clamp((x - a) / (b - a), 0, 1)
	return t * t * (3 - 2 * t)
end

function RangeLayer._draw(
	self: any,
	i: number,
	u: number,
	v: number,
	radius: number,
	cls: number,
	col: Color3,
	k: number
)
	local cam = self.view.rig
	local x, y = cam:map_to_screen(u, v)
	local d = radius * 2 * cam.scale
	if d < 4 or k <= 0.01 or not cam:on_screen(x, y, d * 0.5) then
		return i
	end
	i += 1
	local r = self:_ring(i)
	local pulse = if PULSE[cls + 1] then 0.5 + 0.5 * math.sin(self._now * 5.0) else 0.0
	-- (each written only when it changed: a still view of idle rings writes nothing, a pan only the
	-- positions, the pulsing ones their fill and stroke)
	local f, s = r.frame, r.stroke
	if not r.vis then
		r.vis = true
		f.Visible = true
	end
	if r.x ~= x or r.y ~= y then
		r.x, r.y = x, y
		f.Position = UDim2.fromOffset(x, y)
	end
	if r.d ~= d then
		r.d = d
		f.Size = UDim2.fromOffset(d, d)
	end
	if r.col ~= col then
		r.col = col
		f.BackgroundColor3 = col
	end
	local fill_t = 1 - FILL_A[cls + 1] * k * (1 + 0.3 * pulse)
	if r.fill_t ~= fill_t then
		r.fill_t = fill_t
		f.BackgroundTransparency = fill_t
	end
	if r.stroke_col ~= col then
		r.stroke_col = col
		s.Color = col
	end
	local width = WIDTH[cls + 1] * (1 + 0.25 * pulse)
	if r.width ~= width then
		r.width = width
		s.Thickness = width
	end
	local stroke_t = 1 - RING_A[cls + 1] * k
	if r.stroke_t ~= stroke_t then
		r.stroke_t = stroke_t
		s.Transparency = stroke_t
	end
	return i
end

function RangeLayer.tick(self: any, dt: number?)
	local state = self._state
	if state == nil or self.VR == nil then
		return
	end
	self._now += dt or (1 / 60)
	local cur = math.floor(state.render_tick)
	if cur >= self._next_change then
		self._dirty = true
	end
	if state.local_owner ~= self._last_local then
		self._last_local = state.local_owner
		self._dirty = true
	end
	if self._dirty then
		self._dirty = false
		self:_update_hot()
		self:_rebuild()
	elseif self._grow_tick ~= nil and cur > self._grow_tick then
		self:_regrow(cur)
	end
	local cam = self.view.rig
	local W = state.map.W or Defs.W
	local cam_d = cam:scale_to_distance(cam.scale)
	-- own idle rings fade with the zoom (the same for all of a class)
	local k_sam = 1 - smoothstep(OWN_SAM_FADE[1], OWN_SAM_FADE[2], cam_d)
	local k_def = 1 - smoothstep(OWN_DEF_FADE[1], OWN_DEF_FADE[2], cam_d)
	local i = 0
	local want = self._want
	for n = 1, self._want_n do
		local w = want[n]
		local k = 1.0
		if w.cls == C_OWN_SAM then
			k = k_sam
		elseif w.cls == C_OWN_DEF then
			k = k_def
		end
		i = self:_draw(i, w.tile % W + 0.5, w.tile // W + 0.5, w.r, w.cls, w.col, k)
	end
	local ur = self._unit
	if ur ~= nil then
		if ur.patrol_r > 0 then
			i = self:_draw(i, ur.pu, ur.pv, ur.patrol_r, C_OWN_HI, ur.patrol_col, 1)
		end
		i = self:_draw(i, ur.au, ur.av, ur.target_r, C_FOCUS, ur.target_col, 1)
	end
	for j = i + 1, #self._rings do
		local r = self._rings[j]
		if r.vis then
			r.vis = false
			r.frame.Visible = false
		end
	end
end

return RangeLayer
