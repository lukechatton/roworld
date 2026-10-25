--!nonstrict
-- Port of scripts/ui/coach.gd (UICoach)
-- First-match coach marks: one short tip at a time with a pulsing arrow to what it talks about
-- (a spot on the globe or a HUD control). Each tip shows once per player; "seen" ids persist in
-- the [ui] settings (tips_seen) and can be reset from the game menu.

local UITheme = require("./UITheme")
local W = require("./Widgets")
local GlassPanel = require("./GlassPanel")
local UICtx = require("./UICtx")

local Coach = W.class(W.Control)

Coach.TIPS = {
	expand = {
		icon = "attack",
		desktop = "Click neutral land next to you to expand. Space does the same under the cursor.",
		touch = "Tap neutral land next to you to expand.",
	},
	ratio = {
		icon = "troops",
		desktop = "The Attack bar sets how many of your troops each click sends. Q / E change it.",
		touch = "Tap a % on the Attack bar to choose how many troops each tap sends.",
	},
	city = {
		icon = "city",
		desktop = "You can afford a City (1). Cities raise your troop cap: place one on your land.",
		touch = "You can afford a City. Open BUILD and place one on your land to raise your troop cap.",
	},
	contact = {
		icon = "alliance",
		desktop = "You now border %s. Click their land to attack, or right-click it to propose an alliance.",
		touch = "You now border %s. Tap their land to size them up, tap again to attack. Long-press for more.",
	},
	boat = {
		icon = "boat",
		desktop = "You reached the sea. Click a distant coast to send a boat invasion.",
		touch = "You reached the sea. Tap a distant coast to send a boat invasion.",
	},
	select = {
		icon = "target",
		desktop = "Target selected. Click it again, or press the big button, to send the order.",
		touch = "Target selected: check their troops, then tap it again or press the big button to attack.",
	},
	tray = {
		icon = "city",
		desktop = "Hover a slot to see what it does.",
		touch = "Hold any slot to see what it does and why it may be locked.",
	},
	attacked = {
		icon = "defense",
		desktop = "You are under attack! Track every front in the Attacks panel. Defense Posts (4) make borders much harder to take.",
		touch = "You are under attack! Track every front in the Attacks panel. Defense Posts make borders much harder to take.",
	},
}
Coach.PRIORITY = { "attacked", "select", "expand", "contact", "tray", "ratio", "city", "boat" }
Coach.LIFETIME = 16.0
--- Keep-out rects (the YOU label) cost this many times their overlap area, with this margin (px).
Coach.KEEPOUT_WEIGHT = 12.0
Coach.KEEPOUT_MARGIN = 6.0

local function prio(id: string): number
	return table.find(Coach.PRIORITY, id) or 0
end

function Coach.new(c: any)
	local self = setmetatable({}, Coach.__mt)
	W.Control._init(self)
	self.ctx = c
	self.current = ""
	self._target = nil
	self._queue = {}
	self._age = 0.0
	self._t = 0.0
	self._point = Vector2.new(-1, -1)
	self._point_hidden = false
	--- function() -> {Rect}: HUD panels the card should not cover.
	self.blockers = nil
	--- function() -> {Rect}: map content the card must keep clear of (the player's own YOU label):
	--- weighed much higher than panels, never treated as docked panels or hiding the target.
	self.keepout = nil
	self:set_mouse_filter(W.MOUSE_IGNORE)
	self:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	-- Arrow layer (dashed line, head, pulsing ring) under the card.
	self._arrow = UICtx.canvas(self.gui, "CoachArrow")
	self._arrow.ZIndex = 1
	self._dashes = {}
	self._head = UICtx.make("ImageLabel", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(14, 14),
		ImageColor3 = UITheme.AMBER,
		ScaleType = Enum.ScaleType.Stretch,
	}, self._arrow)
	pcall(function()
		local Shapes = require((game:GetService("ReplicatedStorage"):WaitForChild("Airfront") :: any).Assets.UiShapes)
		self._head.Image = Shapes.arrow_head or ""
	end)
	self._pulse = UICtx.ring(self._arrow, Vector2.zero, 8, 2, UITheme.AMBER, 1)
	self._dot = UICtx.circle(self._arrow, Vector2.zero, 4, UITheme.AMBER, 1)
	self._arrow.Visible = false

	local card = GlassPanel.new(14.0, 11.0, UITheme.R_MD, true, 20)
	card:set_accent(UITheme.AMBER)
	card:set_border(UITheme.c(UITheme.AMBER, 0.45))
	card:set_min_size(Vector2.new(320, 0))
	self._card = card
	local h = UITheme.hbox(12)
	card:add_child(h)
	local disc = W.Panel.new()
	self._disc = disc
	disc:set_mouse_filter(W.MOUSE_IGNORE)
	disc:set_min_size(Vector2.new(34, 34))
	disc.size_flags_vertical = W.SHRINK_BEGIN
	disc:add_theme_stylebox_override(
		"panel",
		UITheme.flat(UITheme.c(UITheme.AMBER, 0.16), 17, UITheme.c(UITheme.AMBER, 0.5), 1)
	)
	self._icon = UITheme.icon_rect("info", 17.0, UITheme.AMBER)
	self._icon.size_flags_horizontal = W.SHRINK_CENTER
	self._icon.size_flags_vertical = W.SHRINK_CENTER
	disc:add_child(self._icon)
	h:add_child(disc)
	local v = UITheme.vbox(6)
	v.size_flags_horizontal = W.EXPAND_FILL
	self._v = v
	self._cap = UITheme.caption("Tip", 10, UITheme.AMBER)
	v:add_child(self._cap)
	self._text = UITheme.label("", 13, 500, UITheme.TEXT)
	self._text:set_autowrap(true)
	self._text:set_min_size(Vector2.new(230, 0))
	v:add_child(self._text)
	self._ok = UITheme.button("Got it", "GhostButton", "", 30.0)
	self._ok:set_font_size(12)
	self._ok.size_flags_horizontal = W.SHRINK_END
	self._ok.pressed:Connect(function()
		self:dismiss()
	end)
	v:add_child(self._ok)
	h:add_child(v)
	local x = UITheme.button("", "GhostButton", "close", 44.0)
	x.expand_icon = true
	x.icon_alignment = W.ALIGN_CENTER
	x:add_theme_constant_override("icon_max_width", 12)
	x:set_min_size(Vector2.new(44, 44))
	x.size_flags_vertical = W.SHRINK_CENTER
	x.pressed:Connect(function()
		self:dismiss()
	end)
	x:set_visible(false)
	self._x = x
	h:add_child(x)
	self:add_child(card)
	card:set_visible(false)
	self:set_process(true)
	return self
end

function Coach.apply_layout(self)
	local ctx = self.ctx
	self._ok:set_min_size(Vector2.new(if ctx.touch then 88 else 0, if ctx.touch then 44 else 30))
	if self.current ~= "" then
		self:_place()
	end
end

function Coach.seen(self, id: string): boolean
	local d = self.ctx:setting("tips_seen", {})
	return type(d) == "table" and d[id] == true
end

function Coach._mark_seen(self, id: string)
	local d = self.ctx:setting("tips_seen", {})
	local dict = if type(d) == "table" then table.clone(d) else {}
	dict[id] = true
	self.ctx:set_setting("tips_seen", dict)
end

function Coach.reset(self)
	self.ctx:set_setting("tips_seen", {})
	table.clear(self._queue)
	self:dismiss()
end

--- Queue a tip. `target` returns the screen point to point at (Vector2(-1, -1) = no arrow).
function Coach.offer(self, id: string, target: (() -> Vector2)?, arg: string?)
	-- (the tutorial's steps are the tips while it runs: UI/Tutorial)
	if self.muted or self:seen(id) or id == self.current or Coach.TIPS[id] == nil then
		return
	end
	for _, q in ipairs(self._queue) do
		if q.id == id then
			return
		end
	end
	table.insert(self._queue, { id = id, target = target, arg = arg or "" })
	table.sort(self._queue, function(a, b)
		return prio(a.id) < prio(b.id)
	end)
	if self.current == "" then
		self:_next()
	end
end

--- The player did what the tip asked: close it (and never offer it again).
function Coach.complete(self, id: string)
	if not self:seen(id) then
		self:_mark_seen(id)
	end
	for i = #self._queue, 1, -1 do
		if self._queue[i].id == id then
			table.remove(self._queue, i)
		end
	end
	if self.current == id then
		self:dismiss()
	end
end

function Coach.dismiss(self)
	if self.current == "" then
		return
	end
	self.current = ""
	self._target = nil
	local t = self._card:create_tween()
	t:tween_property(self._card, "modulate:a", 0.0, 0.2)
	t:tween_callback(function()
		if self.current == "" then
			self._card:set_visible(false)
			self:_draw_arrow()
			self:_next()
		end
	end)
	self:_draw_arrow()
end

function Coach.clear(self)
	table.clear(self._queue)
	self.current = ""
	self._card:set_visible(false)
	self:_draw_arrow()
end

function Coach._next(self)
	if #self._queue == 0 or self.current ~= "" then
		return
	end
	local ctx = self.ctx
	local q = table.remove(self._queue, 1)
	local id = q.id
	if self:seen(id) then
		self:_next()
		return
	end
	self.current = id
	self._target = q.target
	local tip = Coach.TIPS[id]
	local txt = if ctx.touch then tip.touch else tip.desktop
	if string.find(txt, "%s", 1, true) then
		txt = string.format(txt, q.arg)
	end
	self._text:set_text(txt)
	self._icon:set_icon(tip.icon)
	self:_mark_seen(id)
	self._age = 0.0
	local c = ctx.compact
	self._card:set_min_size(Vector2.new(if c then 0 else 320, 0))
	self._text:set_min_size(Vector2.new(if c then 210 else 230, 0))
	self._text:set_font_size(if c then 12 else 13)
	self._cap:set_visible(not c)
	self._ok:set_visible(not c)
	self._x:set_visible(c)
	self._disc:set_min_size(if c then Vector2.new(26, 26) else Vector2.new(34, 34))
	self._disc.size_flags_vertical = if c then W.SHRINK_CENTER else W.SHRINK_BEGIN
	self._icon:set_min_size(if c then Vector2.new(14, 14) else Vector2.new(17, 17))
	self._v.size_flags_vertical = W.SHRINK_CENTER
	self._card:set_padding(
		if c then 10.0 else 14.0,
		if c then 2.0 else 11.0,
		if c then 2.0 else 14.0,
		if c then 2.0 else 11.0
	)
	self._card:set_visible(true)
	self._card:reset_size()
	self:_place()
	UICtx.pop_in(self._card, 0.0, 0.94, 0.35, true)
	ctx:sfx("open", -8.0)
end

function Coach._place(self)
	local ctx = self.ctx
	local vp = ctx.vp
	local ins = ctx.insets
	local sz = self._card:get_combined_minimum_size()
	local blocked = if self.blockers then self.blockers() else {}
	local m = 12.0
	-- Free band for the card: below the top bar, above the panels docked to the bottom edge (the
	-- command bar). On a 361 px phone every spot around a low target overlaps the bar otherwise
	-- (review P1-3; polish over the original, which only weighed overlap).
	local top_lim = 70.0 + ins.y
	local bot_lim = vp.Y - m - ins.w
	for _, b in ipairs(blocked) do
		local docked = b.Max.Y >= vp.Y - ins.w - 40.0 and b.Width >= vp.X * 0.25
		if docked and b.Min.Y - 8.0 - top_lim >= sz.Y then
			bot_lim = math.min(bot_lim, b.Min.Y - 8.0)
		end
	end
	-- A target under a panel (or off the free band) gets no arrow: the card parks in the band.
	local pt = self._point
	local hidden = false
	if pt.X >= 0.0 then
		if pt.Y > bot_lim + m or pt.X < ins.x or pt.X > vp.X - ins.z then
			hidden = true
		else
			for _, b in ipairs(blocked) do
				if UICtx.rect_has_point(b, pt) then
					hidden = true
					break
				end
			end
		end
	end
	self._point_hidden = hidden
	local cands = {}
	if pt.X >= 0.0 and not hidden then
		local gap = 70.0
		table.insert(cands, Vector2.new(pt.X - sz.X * 0.5, pt.Y - sz.Y - gap)) -- above
		table.insert(cands, Vector2.new(pt.X - sz.X - gap, pt.Y - sz.Y * 0.5)) -- left
		table.insert(cands, Vector2.new(pt.X - sz.X * 0.5, pt.Y + gap)) -- below
		table.insert(cands, Vector2.new(pt.X + gap, pt.Y - sz.Y * 0.5)) -- right
	else
		table.insert(cands, Vector2.new((vp.X - sz.X) * 0.5, vp.Y * 0.24))
	end
	-- The player's own label: a card on top of it pushes the YOU label off its land (labels step
	-- around HUD panels), so the card goes beside it (visual review R2-P2-3; polish over the
	-- original, which only weighed the panels).
	local keep = if self.keepout then self.keepout() else nil
	local best = cands[1]
	local best_cost = math.huge
	for i, p in ipairs(cands) do
		local x = math.clamp(p.X, m + ins.x, math.max(m + ins.x, vp.X - sz.X - m - ins.z))
		local y = math.clamp(p.Y, top_lim, math.max(top_lim, bot_lim - sz.Y))
		local r = UICtx.rect_ps(Vector2.new(x, y), sz)
		local cost = (i - 1) * 400.0
		for _, b in ipairs(blocked) do
			cost += UICtx.rect_intersection_area(r, b)
		end
		if keep ~= nil then
			for _, b in ipairs(keep) do
				cost += UICtx.rect_intersection_area(UICtx.rect_grow(r, Coach.KEEPOUT_MARGIN), b) * Coach.KEEPOUT_WEIGHT
			end
		end
		if pt.X >= 0.0 and not hidden and UICtx.rect_has_point(UICtx.rect_grow(r, 8.0), pt) then
			cost += 1e6
		end
		if cost < best_cost then
			best_cost = cost
			best = Vector2.new(x, y)
		end
	end
	local cur = Vector2.new(self._card.offset_left, self._card.offset_top)
	local p = if self._card.modulate_a > 0.5 then cur:Lerp(best, 0.25) else best
	if (p - best).Magnitude < 0.25 then
		p = best
	end
	UICtx.move_node(self._card, p)
end

function Coach._process(self, delta: number)
	if self.current == "" then
		return
	end
	self._t += delta
	self._age += delta
	if self._age > (if self.ctx.compact then Coach.LIFETIME * 0.65 else Coach.LIFETIME) then
		self:dismiss()
		return
	end
	local p = Vector2.new(-1, -1)
	if self._target ~= nil then
		local ok, v = pcall(self._target)
		if ok and typeof(v) == "Vector2" then
			p = v
		end
	end
	self._point = p
	self:_place()
	self:_draw_arrow()
end

--- Dashed line from the card to the target, an arrow head and a pulsing ring (GDScript _draw).
function Coach._draw_arrow(self)
	local arrow = self._arrow
	local card = self._card
	if self.current == "" or self._point.X < 0.0 or self._point_hidden or not card.visible then
		arrow.Visible = false
		return
	end
	-- The whole coach fades while the player aims / uses the radial menu (UIRoot sets its alpha).
	local a = card.modulate_a * (self._eff_a or 1.0)
	if a <= 0.001 then
		arrow.Visible = false
		return
	end
	local r = card:get_global_rect()
	local to = self._point
	local from = Vector2.new(
		math.clamp(to.X, r.Min.X + 18.0, math.max(r.Min.X + 18.0, r.Max.X - 18.0)),
		if to.Y > r.Max.Y then r.Max.Y else r.Min.Y
	)
	local dirv = to - from
	local dist = dirv.Magnitude
	if dist < 24.0 then
		arrow.Visible = false
		return
	end
	self.ctx:fit_canvas(arrow)
	arrow.Visible = true
	local dir = dirv / dist
	local ang = math.deg(math.atan2(dir.Y, dir.X))
	-- Dashed line: 8 px dashes every 14.4 px, 2 px wide.
	local dash = 8.0
	local d = 0.0
	local n = 0
	while d < dist - 16.0 do
		n += 1
		local s0 = from + dir * d
		local s1 = from + dir * math.min(d + dash, dist - 16.0)
		local seg = self._dashes[n]
		if seg == nil then
			seg = UICtx.make("Frame", {
				BorderSizePixel = 0,
				AnchorPoint = Vector2.new(0.5, 0.5),
				BackgroundColor3 = UITheme.AMBER,
			}, arrow)
			UICtx.make("UICorner", { CornerRadius = UDim.new(0.5, 0) }, seg)
			self._dashes[n] = seg
		end
		local len = (s1 - s0).Magnitude
		local mid = (s0 + s1) * 0.5
		seg.Visible = true
		seg.Position = UDim2.fromOffset(mid.X, mid.Y)
		seg.Size = UDim2.fromOffset(len, 2)
		seg.Rotation = ang
		seg.BackgroundTransparency = 1 - 0.9 * a
		d += dash * 1.8
	end
	for i = n + 1, #self._dashes do
		self._dashes[i].Visible = false
	end
	-- Arrow head: the 14x14 triangle mask spans tip +10 .. base -4 along the direction.
	local tip_base = to - dir * 16.0
	local centre = tip_base + dir * 3.0
	self._head.Position = UDim2.fromOffset(centre.X, centre.Y)
	self._head.Rotation = ang
	self._head.ImageTransparency = 1 - 0.9 * a
	-- Pulsing ring on the target
	local k = (self._t % 1.2) / 1.2
	UICtx.set_circle(self._pulse, to, 8.0 + 18.0 * k);
	(self._pulse:FindFirstChild("Stroke") :: UIStroke).Transparency = 1 - (1.0 - k) * 0.9 * a
	UICtx.set_circle(self._dot, to, 4.0)
	self._dot.BackgroundTransparency = 1 - a
end

return Coach
