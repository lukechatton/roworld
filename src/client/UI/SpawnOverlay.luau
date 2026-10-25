--!nonstrict
-- Port of scripts/ui/spawn_overlay.gd (UISpawnOverlay)
-- Spawn-phase banner: "Choose your starting location", a countdown ring, the solo "Deploying in 5…"
-- count and, in multiplayer, how many commanders have placed their capitals.
--
-- One slim row: two lines of text, the count (on a wide screen with a few of the commanders' head
-- shots before it) and the ring. It was a tall panel once: an icon disc, a line of advice and a
-- chip per commander, up to twelve of them over five rows: too big, so it was redesigned smaller
-- (2026-10-05).

local UITheme = require("./UITheme")
local W = require("./Widgets")
local GlassPanel = require("./GlassPanel")
local UICtx = require("./UICtx")
local Defs = UICtx.core("Defs")

local _Rules = nil
local function Rules()
	if _Rules == nil then
		_Rules = UICtx.core("Rules")
	end
	return _Rules
end

local SpawnOverlay = W.class(W.Control)

--- The title's size on a wide screen (phones: 13).
SpawnOverlay.TITLE_PX = 14
--- The ring's side on a wide screen (phones: 36).
SpawnOverlay.RING_PX = 40
--- A wide screen shows up to HEADS commanders' head shots, HEAD_PX wide, each over the last by
--- HEAD_OVERLAP: the ones who have placed first, the rest dimmed.
SpawnOverlay.HEADS = 5
SpawnOverlay.HEAD_PX = 20
SpawnOverlay.HEAD_OVERLAP = 6

--- Countdown ring (GDScript inner class Ring): track circle, amber / red arc, seconds.
local function make_ring()
	local ring = UICtx.draw_node(function(n)
		n:_draw_ring()
	end)
	ring.frac = 1.0
	ring.secs = 0
	ring.urgent = false
	ring:set_min_size(Vector2.new(54, 54))
	ring.track = UICtx.ring(ring.canvas, Vector2.zero, 10, 4, Color3.new(1, 1, 1), 0.9)
	ring.arc = UICtx.arc(ring.canvas)
	ring.num = UICtx.make("TextLabel", {
		BackgroundTransparency = 1,
		FontFace = UITheme.font(800),
		TextSize = UICtx.ts(20),
		TextColor3 = UITheme.TEXT,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = "",
		ZIndex = 3,
	}, ring.canvas)
	function ring._draw_ring(self)
		local sz = self.size
		local c = sz * 0.5
		local r = math.min(sz.X, sz.Y) * 0.5 - 3.0
		UICtx.set_circle(self.track, c, r)
		self.arc:place(c, r, 4)
		local col = if self.urgent then UITheme.RED else UITheme.AMBER
		self.arc:set(if self.frac > 0 then self.frac else 0, col, 0)
		self.arc.frame.Visible = self.frac > 0
		-- draw_string(font 800, size 20) with its baseline at c.y + 20 * 0.36
		self.num.Text = tostring(self.secs)
		self.num.Size = UDim2.fromOffset(sz.X, UICtx.ts(20))
		self.num.Position = UDim2.fromOffset(0, UICtx.top_for_baseline(c.Y + 20 * 0.36, 20))
	end
	function ring.queue_redraw(self)
		if self._geo ~= nil then
			self:_draw_ring()
		end
	end
	return ring
end

function SpawnOverlay.new(c: any)
	local self = setmetatable({}, SpawnOverlay.__mt)
	W.Control._init(self)
	self.ctx = c
	self._end_tick = -1.0
	self._total = 1.0
	self._last_sec = -1
	self._accum = 0.0
	self:set_mouse_filter(W.MOUSE_IGNORE)
	self:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	local panel = GlassPanel.new(22.0, 14.0, UITheme.R_LG, true, 24)
	panel:set_mouse_filter(W.MOUSE_IGNORE)
	self.panel = panel
	self:add_child(panel)
	local row = UITheme.hbox(14)
	self._row = row
	panel:add_child(row)
	local v = UITheme.vbox(1)
	v.size_flags_vertical = W.SHRINK_CENTER
	self._title = UITheme.label("CHOOSE YOUR STARTING LOCATION", SpawnOverlay.TITLE_PX, 800, UITheme.TEXT, 1.5)
	v:add_child(self._title)
	self._sub = UITheme.label("Click any unclaimed land to place your capital.", 12, 500, UITheme.TEXT_2)
	v:add_child(self._sub)
	-- phones: the count is a third line under the text
	self._placed = UITheme.label("", 12, 600, UITheme.TEXT_3)
	self._placed:set_visible(false)
	v:add_child(self._placed)
	row:add_child(v)
	-- a wide screen: the count beside the text, behind a few head shots
	self._side = UITheme.hbox(8)
	self._side.size_flags_vertical = W.SHRINK_CENTER
	self._side:add_child(UITheme.vdivider(26.0))
	self._heads = UITheme.hbox(-SpawnOverlay.HEAD_OVERLAP)
	self._heads.size_flags_vertical = W.SHRINK_CENTER
	self._side:add_child(self._heads)
	self._count = UITheme.label("", 12, 700, UITheme.TEXT_2)
	self._count.size_flags_vertical = W.SHRINK_CENTER
	self._side:add_child(self._count)
	self._side:set_visible(false)
	row:add_child(self._side)
	self._ring = make_ring()
	self._ring.size_flags_vertical = W.SHRINK_CENTER
	row:add_child(self._ring)
	self:set_process(true)
	return self
end

function SpawnOverlay.apply_layout(self)
	local ctx = self.ctx
	local panel = self.panel
	panel:set_mouse_filter(if ctx.touch then W.MOUSE_STOP else W.MOUSE_IGNORE)
	local top = 12.0 + ctx.insets.y
	if ctx.compact then
		-- Phones: slimmer still, leaving the globe to the player.
		top = 8.0 + ctx.insets.y
		self._title:set_font_size(13)
		panel:set_padding(12.0, 4.0, 8.0, 4.0)
		self._ring:set_min_size(Vector2.new(36, 36))
		self._row:set_separation(10)
	else
		self._title:set_font_size(SpawnOverlay.TITLE_PX)
		panel:set_padding(16.0, 8.0, 12.0, 8.0)
		self._ring:set_min_size(Vector2.new(SpawnOverlay.RING_PX, SpawnOverlay.RING_PX))
		self._row:set_separation(14)
	end
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 0.0
	panel.anchor_bottom = 0.0
	panel.grow_horizontal = W.GROW_BOTH
	panel.grow_vertical = W.GROW_END
	local dx, y = ctx:place_top(panel:get_combined_minimum_size().X, top)
	panel.offset_left = dx
	panel.offset_right = dx
	panel.offset_top = y
	panel.offset_bottom = y
	panel:reset_size()
end

function SpawnOverlay.bottom_edge(self): number
	local r = self.panel:get_global_rect()
	return r.Max.Y
end

function SpawnOverlay.on_show(self)
	self._last_sec = -1
	self:refresh()
	UICtx.pop_in(self.panel, 0.05, 0.94, 0.45)
end

function SpawnOverlay.on_phase(self, ticks_left: number)
	local ctx = self.ctx
	local s = ctx.state
	if s == nil then
		return
	end
	self._end_tick = if ticks_left > 0 then s.tick + ticks_left else -1.0
	if ticks_left > 0 then
		local R = Rules()
		local solo_total = if ctx:mode() == UICtx.MODE_SOLO then R.SOLO_COUNTDOWN_TICKS else R.DEFAULT_SPAWN_TICKS
		self._total = math.max(ticks_left, solo_total) / Defs.TICK_RATE
	end
	self:refresh()
end

function SpawnOverlay.refresh(self)
	local ctx = self.ctx
	local s = ctx.state
	if s == nil then
		return
	end
	local o = ctx:my()
	local placed = o ~= nil and o.spawned
	local solo = ctx:mode() == UICtx.MODE_SOLO
	local left = -1.0
	if self._end_tick > 0.0 then
		left = math.max(0.0, (self._end_tick - ctx:render_tick()) / Defs.TICK_RATE)
	end
	local ring = self._ring
	ring:set_visible(left >= 0.0 and s.phase == Defs.PHASE_SPAWN)
	if left >= 0.0 then
		ring.frac = math.clamp(left / math.max(self._total, 0.1), 0.0, 1.0)
		ring.secs = math.ceil(left)
		ring.urgent = left <= 5.0
		ring:queue_redraw()
		local sec = math.ceil(left)
		if sec ~= self._last_sec and sec <= 5 and sec > 0 and self._last_sec >= 0 then
			ctx:sfx("tick", if sec > 1 then -4.0 else 0.0, 0.0)
		end
		self._last_sec = sec
	end
	local late = s.phase == Defs.PHASE_PLAYING
	local verb = if ctx.touch then "Tap" else "Click"
	if ctx:me() == 0 then
		self._title:set_text("COMMANDERS ARE DEPLOYING")
		self._sub:set_text("You are spectating this match.")
	elseif late and not placed then
		self._title:set_text("DROP INTO THE WAR")
		self._sub:set_text(verb .. " any unclaimed land to deploy your capital.")
	elseif placed and solo and left >= 0.0 then
		self._title:set_text(string.format("DEPLOYING IN %d", math.ceil(left)))
		self._sub:set_text(verb .. " elsewhere to relocate your capital.")
	elseif placed then
		self._title:set_text("CAPITAL PLACED")
		self._sub:set_text(verb .. " elsewhere to relocate until the countdown ends.")
	else
		self._title:set_text("CHOOSE YOUR STARTING LOCATION")
		self._sub:set_text(
			if not ctx.touch
				then "Click any unclaimed land to place your capital."
				else "Tap any unclaimed land to place your capital."
		)
	end
	self:_refresh_players()
	self.panel:reset_size()
end

function SpawnOverlay._refresh_players(self)
	local ctx = self.ctx
	local s = ctx.state
	local mp = ctx:mode() == UICtx.MODE_MULTI
	self._side:set_visible(mp and not ctx.compact)
	self._placed:set_visible(mp and ctx.compact)
	if not mp or s == nil then
		return
	end
	local humans = {}
	local placed = 0
	for _, o in pairs(s.owners) do
		if o.kind == Defs.KIND_HUMAN and o.alive then
			table.insert(humans, o)
			if o.spawned then
				placed += 1
			end
		end
	end
	if ctx.compact then
		self._placed:set_text(string.format("%d / %d commanders placed", placed, #humans))
		return
	end
	self._count:set_text(string.format("%d / %d placed", placed, #humans))
	-- the head shots (the cosmetics map's `face`, as in the leaderboard and on the map): those who
	-- have placed first
	table.sort(humans, function(a, b)
		if a.spawned ~= b.spawned then
			return a.spawned == true
		end
		return a.id < b.id
	end)
	local cosmetics = s.cosmetics or {}
	local shown = {}
	local key = ""
	for _, h in ipairs(humans) do
		local cz = cosmetics[h.id]
		if cz ~= nil and cz.face ~= nil then
			table.insert(shown, h)
			key ..= string.format("%d:%d:%d;", h.id, if h.spawned then 1 else 0, cz.face)
			if #shown >= SpawnOverlay.HEADS then
				break
			end
		end
	end
	if self._heads:get_meta("key", "") == key then
		return
	end
	self._heads:set_meta("key", key)
	for _, ch in ipairs(self._heads:get_children()) do
		ch:queue_free()
	end
	self._heads:set_visible(#shown > 0)
	for _, h in ipairs(shown) do
		local img = Instance.new("ImageLabel")
		img.BackgroundColor3 = Color3.fromRGB(40, 52, 82)
		img.BorderSizePixel = 0
		img.Image = UICtx.data("Cosmetics").face_image(cosmetics[h.id].face)
		img.ImageTransparency = if h.spawned then 0 else 0.55
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = img
		-- (a rim of the panel's colour parts it from the head under it; green once they have placed)
		local rim = Instance.new("UIStroke")
		rim.Thickness = 1.5
		rim.Color = UITheme.color3(if h.spawned then UITheme.GREEN else Color3.fromRGB(16, 22, 40))
		rim.Parent = img
		local head = W.wrap(img)
		head:set_min_size(Vector2.new(SpawnOverlay.HEAD_PX, SpawnOverlay.HEAD_PX))
		head.size_flags_vertical = W.SHRINK_CENTER
		head:set_mouse_filter(W.MOUSE_IGNORE)
		self._heads:add_child(head)
	end
end

function SpawnOverlay._process(self, delta: number)
	self._accum += delta
	if self._accum >= 0.1 and self:is_visible_in_tree() then
		self._accum = 0.0
		self:refresh()
	end
end

return SpawnOverlay
