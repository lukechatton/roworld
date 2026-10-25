--!native
-- Structure icons on the 2D map:
--   * a plate per structure in its type's shape (City circle, Port pentagon, Factory hexagon,
--     Defense Post octagon, SAM square, Silo triangle), fill = the owner's territory colour at HSV
--     value x0.65, rim = the border colour (the territory colour for the local player) at value
--     x0.1, a white glyph inside; under construction: grey fill 198 / rim 127;
--   * size: ICON_SIZE * iconScale px, iconScale = DOT_SCALE (0.3, no glyph)
--     when zoom <= DOTS_ZOOM, zoom / GROW_ZOOM above GROW_ZOOM, else
--     min(1, zoom / SCALE_FACTOR_OUT); per-type shape scale; zoom = the camera zoom
--     (device px per full-size tile; a tile is k_lin full-size tiles, a GUI px DEVICE_RATIO
--     device px);
--   * level >= 2: the level number above the plate (0.4 plate sizes up);
--   * a progress bar, 14 x 3 full-size tiles centred 6 tiles below the structure
--     (1-tile black border; fill red < 25 % < orange < 50 % < yellow < 75 % < green): construction
--     progress, and a SAM's / silo's missile readiness while missiles reload (Ev.STRUCT_SHOTS).
-- Roblox: pooled plates, positions rewritten only when the camera or the structure set changed. A
-- plate is one ImageLabel with the glyph inside it: the shape's rim and fill in one image
-- (Sprites.shapes_one, tinted with the fill colour: its rim pixels are the grey that makes the rim's
-- tenth of the value). It was a Frame holding a rim image, a fill image, the glyph and a level
-- label, five objects for each of a late game's 500 structures, all laid out again on every camera
-- move (2026-10-08, docs/performance.md). The level label is made when a structure has a level to
-- show. The Arsenal's plates, and every plate while shapes_one has not loaded, keep a second image
-- for the fill.
local RS = game:GetService("ReplicatedStorage")
local Airfront = RS:WaitForChild("Airfront")
local Rules = require(Airfront:WaitForChild("Core"):WaitForChild("Rules")) :: any
local Sprites = require(Airfront:WaitForChild("Assets"):WaitForChild("MapSprites")) :: any
--- The Arsenal's structures (kinds 6..8: Artillery, Airfield, Railgun) have plates and glyphs of
--- their own (Assets/ArsenalArt, the same layout in columns 0..2).
local AA: any = (function()
	local m = Airfront.Assets:FindFirstChild("ArsenalArt")
	local ok, a = pcall(function()
		return if m then require(m) :: any else nil
	end)
	return if ok and type(a) == "table" then a else nil
end)()
local ARSENAL_KIND0 = 6

--- Sprites.shapes_one is used once it is known to have loaded (an image still in moderation would leave
--- every plate invisible).
local ONE: any = Sprites.shapes_one
local one_ready = false
if ONE ~= nil then
	(require(script.Parent:WaitForChild("AtlasReady")) :: any).watch(ONE.id, function()
		one_ready = true
	end)
end

local StructureLayer = {}
StructureLayer.__index = StructureLayer

-- icon sizes and zooms
StructureLayer.ICON_SIZE = 30 -- 60 device px at device pixel ratio 2
StructureLayer.DEVICE_RATIO = 2.0
StructureLayer.DOTS_ZOOM = 1.2
StructureLayer.DOT_SCALE = 0.3
StructureLayer.SCALE_FACTOR_OUT = 3.0
StructureLayer.GROW_ZOOM = 7.0
--- per structure kind (Defs.S_*, 0-based) — index with kind + 1
StructureLayer.SHAPE_SCALE = { 1.0, 1.08, 1.08, 1.0, 1.4, 1.55 }
StructureLayer.ICON_FILL = { 0.85, 0.85, 0.85, 0.8, 1.0, 0.85 }
StructureLayer.FILL_V = 0.65
StructureLayer.BORDER_V = 0.1
StructureLayer.BORDER_DARKEN = 0.125
StructureLayer.CONSTRUCT_FILL = Color3.fromRGB(198, 198, 198)
StructureLayer.CONSTRUCT_BORDER = Color3.fromRGB(127, 127, 127)
StructureLayer.Z = 10
-- progress bar (full-size tiles)
StructureLayer.BAR_W = 14
StructureLayer.BAR_H = 3
StructureLayer.BAR_OFFSET_Y = 6
StructureLayer.BAR_BORDER = 1
StructureLayer.BAR_THRESHOLDS = { 0.25, 0.5, 0.75 }
StructureLayer.BAR_COLORS = {
	Color3.new(0.91, 0.098, 0.098),
	Color3.new(0.941, 0.478, 0.098),
	Color3.new(0.792, 0.906, 0.059),
	Color3.new(0.173, 0.937, 0.071),
}
--- Bars narrower than this (px) are not drawn (far zoomed out).
StructureLayer.BAR_MIN_PX = 10
local SHAPE_SCALE = StructureLayer.SHAPE_SCALE
local ICON_FILL = StructureLayer.ICON_FILL
for i = 1, 3 do
	SHAPE_SCALE[ARSENAL_KIND0 + i] = if AA then AA.shape_scale[i] else 1.3
	ICON_FILL[ARSENAL_KIND0 + i] = if AA then AA.icon_fill[i] else 0.8
end

type Plate = {
	--- the plate: the whole shape (rim and fill in one image, or the rim alone under `fill`)
	frame: ImageLabel,
	--- the inset shape over a two-image plate (made when one is needed)
	fill: ImageLabel?,
	glyph: ImageLabel,
	--- the level number (made when a structure has one)
	level: TextLabel?,
	x: number,
	y: number,
	bar: Frame?,
	bar_fill: Frame?,
	kind: number,
	owner: number,
	state_key: number,
	size: number,
}

local function value_scale(c: Color3, k: number): Color3
	local h, s, v = c:ToHSV()
	return Color3.fromHSV(h, s, v * k)
end

--- The owner's border colour (HSL lightness - 0.125, like MapSurface).
local function border_color(c: Color3): Color3
	local r, g, b = c.R, c.G, c.B
	local mx, mn = math.max(r, g, b), math.min(r, g, b)
	local l = (mx + mn) / 2
	local s, h = 0.0, 0.0
	if mx ~= mn then
		local d = mx - mn
		s = if l > 0.5 then d / (2 - mx - mn) else d / (mx + mn)
		if mx == r then
			h = (g - b) / d + (if g < b then 6 else 0)
		elseif mx == g then
			h = (b - r) / d + 2
		else
			h = (r - g) / d + 4
		end
		h /= 6
	end
	l = math.max(0, l - StructureLayer.BORDER_DARKEN)
	if s == 0 then
		return Color3.new(l, l, l)
	end
	local q = if l < 0.5 then l * (1 + s) else l + s - l * s
	local p = 2 * l - q
	local function hue(t: number): number
		if t < 0 then
			t += 1
		elseif t > 1 then
			t -= 1
		end
		if t < 1 / 6 then
			return p + (q - p) * 6 * t
		elseif t < 1 / 2 then
			return q
		elseif t < 2 / 3 then
			return p + (q - p) * (2 / 3 - t) * 6
		end
		return p
	end
	return Color3.new(hue(h + 1 / 3), hue(h), hue(h - 1 / 3))
end

function StructureLayer.new(parent: Instance, view: any)
	local self = setmetatable({}, StructureLayer) :: any
	local root = Instance.new("Frame")
	root.Name = "Structures"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.ZIndex = StructureLayer.Z
	root.Parent = parent
	self.root = root
	self.view = view
	self._state = nil :: any
	self._plates = {} :: { [number]: Plate }
	self._pool = {} :: { Plate }
	self._one_seen = false
	-- The progress bars change every frame while something is built or reloads, and late games
	-- always have some: they live in the map's moving ScreenGui (MapView.moving_overlay), so the
	-- plates' own, some 2,500 objects by then, is left alone between camera moves.
	local bars = Instance.new("Frame")
	bars.Name = "StructureBars"
	bars.BackgroundTransparency = 1
	bars.Size = UDim2.fromScale(1, 1)
	bars.ZIndex = StructureLayer.Z
	bars.Parent = if view ~= nil and view.moving_overlay ~= nil then view.moving_overlay else root
	self._bar_root = bars
	self._dirty = true
	self._cam_version = -1
	--- sids of on-screen plates being built or reloading (updated every frame between full passes)
	self._anim = {} :: { number }
	return self
end

function StructureLayer.bind(self: any, state: any)
	self:unbind()
	self._state = state
	self._dirty = true
end

function StructureLayer.unbind(self: any)
	self._state = nil
	for sid, p in self._plates do
		self:_release(p)
		self._plates[sid] = nil
	end
end

function StructureLayer.destroy(self: any)
	self:unbind()
	self._bar_root:Destroy()
	self.root:Destroy()
end

-- WorldView forwards GameState structure signals by these names.
function StructureLayer.on_structure_added(self: any)
	self._dirty = true
end
StructureLayer.on_structure_changed = StructureLayer.on_structure_added
StructureLayer.on_structure_removed = StructureLayer.on_structure_added
StructureLayer.on_structure_leveled = StructureLayer.on_structure_added
StructureLayer.mark_structures_dirty = StructureLayer.on_structure_added

local function image(parent: Instance, name: string, id: string, z: number): ImageLabel
	local l = Instance.new("ImageLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Image = id
	l.AnchorPoint = Vector2.new(0.5, 0.5)
	l.Position = UDim2.fromScale(0.5, 0.5)
	l.ZIndex = z
	l.Parent = parent
	return l
end

function StructureLayer._acquire(self: any): Plate
	local p = table.remove(self._pool)
	if p then
		p.frame.Visible = true
		return p
	end
	local f = Instance.new("ImageLabel")
	f.Name = "Structure"
	f.BackgroundTransparency = 1
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.ZIndex = StructureLayer.Z
	local glyph = image(f, "Glyph", Sprites.icons.id, StructureLayer.Z + 2)
	f.Parent = self.root
	return {
		frame = f,
		fill = nil,
		glyph = glyph,
		level = nil,
		kind = -1,
		owner = -1,
		state_key = -1,
		size = -1,
		x = -1e9,
		y = -1e9,
	}
end

--- The level label of a plate, made on first use.
local function level_label(p: Plate): TextLabel
	local level = p.level
	if level == nil then
		local l = Instance.new("TextLabel")
		l.Name = "Level"
		l.BackgroundTransparency = 1
		l.AnchorPoint = Vector2.new(0.5, 1)
		l.Position = UDim2.fromScale(0.5, 0.1)
		l.Size = UDim2.fromScale(1, 0.6)
		l.FontFace = Font.fromId(12187365977, Enum.FontWeight.Bold)
		l.TextScaled = true
		l.TextColor3 = Color3.new(1, 1, 1)
		l.ZIndex = StructureLayer.Z + 3
		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.new(0, 0, 0)
		stroke.Thickness = 1.5
		stroke.Parent = l
		l.Parent = p.frame
		p.level = l
		level = l
	end
	return level :: TextLabel
end

function StructureLayer._release(self: any, p: Plate)
	p.frame.Visible = false
	if p.bar ~= nil then
		p.bar.Visible = false
	end
	p.kind = -1
	p.owner = -1
	p.x, p.y = -1e9, -1e9
	p.state_key = -1
	table.insert(self._pool, p)
end

function StructureLayer._style(self: any, p: Plate, s: any, building: boolean)
	local st = self._state
	local k = s.kind
	local arsenal = k >= ARSENAL_KIND0 and AA ~= nil
	-- one image for the plate where there is one (see the header)
	local one = one_ready and not arsenal
	-- (a number, not a string: built for every plate on screen at every camera move, and a phone pays
	-- for the strings it made; 2026-10-12)
	local key = (((k * 1024 + s.owner) * 2 + (if building then 1 else 0)) * 4096 + math.min(s.level or 1, 4095)) * 2
		+ (if one then 1 else 0)
	if key == p.state_key then
		return
	end
	p.state_key = key
	local shapes, icons, col = Sprites.shapes, Sprites.icons, k
	if arsenal then
		shapes, icons, col = AA.shapes, AA.glyphs, k - ARSENAL_KIND0
	end
	local fill_col, rim_col
	if building then
		fill_col, rim_col = StructureLayer.CONSTRUCT_FILL, StructureLayer.CONSTRUCT_BORDER
	else
		local c = st:owner_color(s.owner)
		fill_col = value_scale(c, StructureLayer.FILL_V)
		local b = if s.owner == st.local_owner then c else border_color(c)
		rim_col = value_scale(b, StructureLayer.BORDER_V)
	end
	local plate = p.frame
	local cell = shapes.cell
	plate.ImageRectSize = Vector2.new(cell, cell)
	plate.ImageRectOffset = Vector2.new(col * cell, 0)
	if one then
		plate.Image = ONE.id
		plate.ImageColor3 = fill_col
		if p.fill ~= nil then
			p.fill.Visible = false
		end
	else
		plate.Image = shapes.id
		plate.ImageColor3 = rim_col
		local fill = p.fill
		if fill == nil then
			local f = image(plate, "Fill", shapes.id, StructureLayer.Z + 1)
			f.Size = UDim2.fromScale(1, 1)
			p.fill = f
			fill = f
		end
		local f = fill :: ImageLabel
		f.Visible = true
		f.Image = shapes.id
		f.ImageRectOffset = Vector2.new(col * cell, cell)
		f.ImageRectSize = Vector2.new(cell, cell)
		f.ImageColor3 = fill_col
	end
	p.glyph.Image = icons.id
	local ic = icons.cell
	p.glyph.ImageRectOffset = Vector2.new(col * ic, 0)
	p.glyph.ImageRectSize = Vector2.new(ic, ic)
	-- the glyph spans ICON_FILL / SHAPE_SCALE of the plate
	local g = ICON_FILL[k + 1] / SHAPE_SCALE[k + 1]
	p.glyph.Size = UDim2.fromScale(g, g)
	local lv = s.level or 1
	if lv >= 2 then
		local l = level_label(p)
		l.Visible = true
		l.Text = tostring(lv)
	elseif p.level ~= nil then
		p.level.Visible = false
	end
end

--- Construction progress, else (SAM / silo) missile
--- readiness while any missile reloads; nil = no bar.
function StructureLayer.progress(s: any, rt: number): number?
	local at = s.active_tick or 0
	if at > rt then
		local dur = Rules.BUILD_TICKS[s.kind] or 50
		return math.clamp(1 - (at - rt) / math.max(1, dur), 0, 1)
	end
	local shots = s.shots
	-- (a SAM's and a silo's missiles; an airfield rearming, a railgun reloading: Rules.RELOAD_TICKS)
	local reload = Rules.RELOAD_TICKS[s.kind] or 0
	if reload > 0 and shots ~= nil and #shots > 0 then
		local cd = reload
		local slots = math.max(1, s.level or 1)
		local reloading, done = 0, 0.0
		for _, t in shots do
			local e = rt - t
			if e < cd then
				reloading += 1
				done += math.max(0, e) / cd
			end
		end
		if reloading > 0 then
			local r = math.clamp((slots - reloading) / slots + done / slots, 0, 1)
			if r < 1 then
				return r
			end
		end
	end
	return nil
end

function StructureLayer._bar(self: any, p: Plate, progress: number?, x: number, y: number, ppt: number)
	local w = StructureLayer.BAR_W * ppt
	if progress == nil or w < StructureLayer.BAR_MIN_PX then
		if p.bar ~= nil and p.bar.Visible then
			p.bar.Visible = false
		end
		return
	end
	local bar, fill = p.bar, p.bar_fill
	if bar == nil or fill == nil then
		local b = Instance.new("Frame")
		b.Name = "Bar"
		b.BorderSizePixel = 0
		b.BackgroundColor3 = Color3.new(0, 0, 0)
		b.ZIndex = StructureLayer.Z + 4
		local f = Instance.new("Frame")
		f.Name = "Fill"
		f.BorderSizePixel = 0
		f.ZIndex = StructureLayer.Z + 5
		f.Parent = b
		b.Parent = self._bar_root
		p.bar, p.bar_fill = b, f
		bar, fill = b, f
	end
	local b = bar :: Frame
	local f = fill :: Frame
	local h = math.max(3, math.round(StructureLayer.BAR_H * ppt))
	local bw = math.max(1, math.round(StructureLayer.BAR_BORDER * ppt))
	local wr = math.round(w)
	b.Visible = true
	b.Size = UDim2.fromOffset(wr, h)
	b.Position = UDim2.fromOffset(math.round(x - wr / 2), math.round(y + StructureLayer.BAR_OFFSET_Y * ppt))
	local inner = math.max(0, wr - 2 * bw)
	f.Position = UDim2.fromOffset(bw, bw)
	f.Size = UDim2.fromOffset(math.round(progress * inner), math.max(1, h - 2 * bw))
	local th = StructureLayer.BAR_THRESHOLDS
	local c = StructureLayer.BAR_COLORS
	f.BackgroundColor3 = if progress < th[1] then c[1] elseif progress < th[2] then c[2] elseif progress < th[3] then c[3] else c[4]
end

--- One structure's plate at (x, y) (screen px), `size` px: style, size, position (written only when
--- they changed), its progress bar.
function StructureLayer._place(self: any, p: Plate, s: any, rt: number, x: number, y: number, size: number, dots: boolean, ppt: number)
	self:_style(p, s, (s.active_tick or 0) > rt)
	local px = math.round(size)
	if p.size ~= px then
		p.size = px
		p.frame.Size = UDim2.fromOffset(px, px)
	end
	if p.glyph.Visible == dots then
		p.glyph.Visible = not dots
	end
	local rx, ry = math.round(x), math.round(y)
	if rx ~= p.x or ry ~= p.y then
		p.x, p.y = rx, ry
		p.frame.Position = UDim2.fromOffset(rx, ry)
	end
	self:_bar(p, StructureLayer.progress(s, rt), x, y, ppt)
end

function StructureLayer.tick(self: any, _dt: number)
	local st = self._state
	if st == nil then
		return
	end
	-- (a structure added, captured, removed, upgraded or starting to reload marks the layer dirty:
	-- on_structure_* below, forwarded from GameState's signals)
	local cam = self.view.rig
	local rt = st.render_tick or st.tick or 0
	local k = tonumber(st.map and st.map.k_lin) or Rules.K_LIN
	-- the zoom: device px per full-size tile
	local zoom = cam.scale / k * StructureLayer.DEVICE_RATIO
	local icon_scale
	if zoom <= StructureLayer.DOTS_ZOOM then
		icon_scale = StructureLayer.DOT_SCALE
	elseif zoom >= StructureLayer.GROW_ZOOM then
		icon_scale = zoom / StructureLayer.GROW_ZOOM
	else
		icon_scale = math.min(1.0, zoom / StructureLayer.SCALE_FACTOR_OUT)
	end
	local dots = zoom <= StructureLayer.DOTS_ZOOM
	local base = StructureLayer.ICON_SIZE * icon_scale
	local ppt = cam.scale / k
	-- (the one-image atlas arrived: every plate is styled again)
	if one_ready ~= self._one_seen then
		self._one_seen = one_ready
		self._dirty = true
	end
	if not self._dirty and cam.version == self._cam_version then
		-- nothing moved: only the plates being built or reloading change (their bar, and their
		-- style once finished) — late games always have some, and redrawing every plate each frame
		-- cost the most there
		local anim = self._anim
		local keep = 0
		for i = 1, #anim do
			local sid = anim[i]
			local s = st.structures[sid]
			local p = self._plates[sid]
			if s ~= nil and p ~= nil then
				local x, y = cam:tile_to_screen(s.tile)
				self:_place(p, s, rt, x, y, base * (SHAPE_SCALE[s.kind + 1] or 1.0), dots, ppt)
				if StructureLayer.progress(s, rt) ~= nil or (s.active_tick or 0) > rt then
					keep += 1
					anim[keep] = sid
				end
			end
		end
		for i = #anim, keep + 1, -1 do
			anim[i] = nil
		end
		return
	end
	self._dirty = false
	self._cam_version = cam.version
	local seen = self._seen
	if seen == nil then
		seen = {}
		self._seen = seen
	else
		table.clear(seen)
	end
	local anim = self._anim
	table.clear(anim)
	for sid, s in st.structures do
		local x, y = cam:tile_to_screen(s.tile)
		local size = base * (SHAPE_SCALE[s.kind + 1] or 1.0)
		if not cam:on_screen(x, y, size) then
			continue
		end
		seen[sid] = true
		local p = self._plates[sid]
		if p == nil then
			p = self:_acquire()
			self._plates[sid] = p
		end
		self:_place(p, s, rt, x, y, size, dots, ppt)
		if StructureLayer.progress(s, rt) ~= nil or (s.active_tick or 0) > rt then
			table.insert(anim, sid)
		end
	end
	for sid, p in self._plates do
		if not seen[sid] then
			self:_release(p)
			self._plates[sid] = nil
		end
	end
end

return StructureLayer
