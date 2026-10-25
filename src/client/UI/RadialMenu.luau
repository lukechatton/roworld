-- Port of scripts/ui/radial_menu.gd
-- Circular context menu (right-click / long-press). Segments carry an icon and a short label;
-- unavailable actions are greyed and explain themselves in the caption under the ring. Items with
-- a `sub` list open a second ring (Build ▸, Nuke ▸); the centre button goes back / closes.
--
-- Roblox: drawn with plain instances in a logical-px canvas. Ring segments are static annular
-- sector masks (Assets/UiShapes, tools/ui/make_shapes.py) rotated into place and tinted; circles
-- are Frames with UICorner / UIStroke. While open, a full-screen button swallows pointer input
-- (Godot MOUSE_FILTER_STOP) and the opening finger of a long-press is followed through
-- UserInputService (press-slide-release picks).

local UICtx = require("./UICtx") :: any
local Signal = UICtx.core("Signal")

local _T: any = nil
local function T(): any
	if _T == nil then
		_T = UICtx.mod("UITheme")
	end
	return _T
end

local _Shapes: any = nil
local function Shapes(): any
	if _Shapes == nil then
		local ok, m = pcall(function()
			if UICtx.IS_ROBLOX then
				local rs = game:GetService("ReplicatedStorage")
				return require((rs:WaitForChild("Airfront") :: any):WaitForChild("Assets"):WaitForChild("UiShapes"))
			end
			return (require :: any)("../../shared/Assets/UiShapes")
		end)
		_Shapes = if ok then m else {}
	end
	return _Shapes
end

local TAU = 2 * math.pi

local RadialMenu = {}
RadialMenu.__index = RadialMenu

--- How far (logical px) the opening finger must slide before its release picks an item (was 16: a
--- lift's wobble picked whatever the finger rested on, so press and hold felt glitchy; 2026-09-29).
RadialMenu.SLIDE_PICK_PX = 30.0

local function rgb(r: number, g: number, b: number): Color3
	return Color3.new(r, g, b)
end

--- easeOutBack (GDScript _ease)
local function ease(t: number): number
	local c1 = 1.70158
	local c3 = c1 + 1.0
	return 1.0 + c3 * (t - 1.0) ^ 3 + c1 * (t - 1.0) ^ 2
end

function RadialMenu.new(c: any)
	local self = setmetatable({}, RadialMenu)
	self.ctx = c
	self.picked = Signal.new() -- (id, tile)
	self.closed = Signal.new()
	self.tile = -1
	self.center = Vector2.zero
	self.items = {} :: { any }
	self.title = ""
	self.title_color = T().TEXT
	self.is_open = false
	self._root_items = {} :: { any }
	self._in_sub = false
	--- the rings above the current sub-ring (nested sub-rings)
	self._stack = {} :: { any }
	self._sub_title = ""
	self._hover = -1
	self._center_hover = false
	self._anim = 0.0
	self._closing = false
	--- False until a press lands on the open menu: a release before that ends a long-press-and-slide.
	self._saw_press = false
	self._press_pos = Vector2.zero
	--- The opening finger has moved off its press point (press-slide-release may pick).
	self._slid = false
	self.r_in = 44.0
	self.r_out = 116.0
	self._conns = {} :: { any }
	self._segs = {} :: { any }
	self._built_for = nil :: any
	self:_build()
	return self
end

-- ---------------------------------------------------------------------------------------------
-- Instances
-- ---------------------------------------------------------------------------------------------

function RadialMenu._build(self: any)
	local canvas = UICtx.canvas(nil, "Radial")
	canvas.Visible = false
	self.gui = canvas
	-- Input sink (Godot mouse_filter STOP while open).
	local blocker = UICtx.make("TextButton", {
		Name = "Blocker",
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromScale(1, 1),
		Active = true,
		Selectable = false,
		ZIndex = 1,
	}, canvas)
	self._blocker = blocker
	-- Ring: everything positioned relative to the centre, scaled by the open animation.
	local ring = UICtx.frame(canvas)
	ring.Name = "Ring"
	ring.ZIndex = 2
	self._ring = ring
	self._ring_scale = UICtx.make("UIScale", { Scale = 1 }, ring)
	self._backdrop = UICtx.circle(ring, Vector2.zero, 10, rgb(0.0, 0.01, 0.04), 1)
	self._backdrop.ZIndex = 1
	self._seg_holder = UICtx.frame(ring)
	self._seg_holder.ZIndex = 2
	self._gap_disc = UICtx.circle(ring, Vector2.zero, 10, rgb(0.02, 0.03, 0.07), 1)
	self._gap_disc.ZIndex = 5
	self._center_btn = UICtx.circle(ring, Vector2.zero, 10, rgb(0.09, 0.12, 0.22), 0)
	self._center_btn.ZIndex = 6
	self._center_stroke =
		UICtx.make("UIStroke", { Thickness = 1, Color = Color3.new(1, 1, 1), Transparency = 0.84 }, self._center_btn)
	self._center_icon = UICtx.make("ImageLabel", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(16, 16),
		ScaleType = Enum.ScaleType.Fit,
		ZIndex = 7,
	}, self._center_btn)
	-- Title / caption pills (outside the scaled group: fixed text size like the original).
	self._title_pill = self:_make_pill(canvas, 13, 800, 1)
	self._cap_pill = self:_make_pill(canvas, 12, 600, 0)
end

function RadialMenu._make_pill(self: any, parent: Instance, fs: number, weight: number, spacing: number): any
	local Th = T()
	local f = UICtx.make("Frame", {
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = rgb(0.04, 0.055, 0.11),
		ZIndex = 10,
		Visible = false,
	}, parent)
	UICtx.make("UICorner", { CornerRadius = UDim.new(0.5, 0) }, f)
	local st = UICtx.make("UIStroke", { Thickness = 1, Color = Color3.new(1, 1, 1), Transparency = 0.88 }, f)
	local l = UICtx.make("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		FontFace = Th.font(weight),
		TextSize = UICtx.ts(fs),
		TextColor3 = Th.TEXT,
		Text = "",
		ZIndex = 11,
	}, f)
	return { frame = f, stroke = st, label = l, fs = fs, weight = weight, spacing = spacing, text = "" }
end

function RadialMenu._set_pill(self: any, pill: any, c: Vector2, text: string, col: Color3, alpha: number)
	local Th = T()
	if text == "" or alpha <= 0.0 then
		pill.frame.Visible = false
		return
	end
	if text ~= pill.text then
		pill.text = text
		pill.label.Text = text
		pill.w = Th.text_width(text, pill.fs, pill.weight, 0) + 22.0
	end
	local h = pill.fs + 12.0
	pill.frame.Visible = true
	pill.frame.Position = UDim2.fromOffset(c.X, c.Y)
	pill.frame.Size = UDim2.fromOffset(pill.w, h)
	pill.frame.BackgroundTransparency = 1 - alpha
	pill.stroke.Transparency = 1 - 0.12 * alpha
	pill.label.TextColor3 = col
	pill.label.TextTransparency = 1 - alpha
end

--- One pooled segment: fill + outline masks, icon, label.
function RadialMenu._seg(self: any, i: number): any
	local s = self._segs[i]
	if s ~= nil then
		return s
	end
	local Th = T()
	local holder = self._seg_holder
	local function mask(z: number): ImageLabel
		return UICtx.make("ImageLabel", {
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			ScaleType = Enum.ScaleType.Stretch,
			ZIndex = z,
		}, holder)
	end
	s = {
		fill = mask(2),
		line = mask(3),
		icon = UICtx.make("ImageLabel", {
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			ScaleType = Enum.ScaleType.Fit,
			Size = UDim2.fromOffset(24, 24),
			ZIndex = 4,
		}, holder),
		label = UICtx.make("TextLabel", {
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0),
			Size = UDim2.fromOffset(90, UICtx.ts(11)),
			FontFace = Th.font(600),
			TextSize = UICtx.ts(11),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextYAlignment = Enum.TextYAlignment.Top,
			ZIndex = 4,
		}, holder),
		key = "",
	}
	self._segs[i] = s
	return s
end

-- ---------------------------------------------------------------------------------------------
-- Open / close
-- ---------------------------------------------------------------------------------------------

function RadialMenu.open_at(self: any, t: number, pos: Vector2, its: { any }, title_text: string, title_col: Color3)
	local ctx = self.ctx
	self.tile = t
	self._root_items = its
	self.items = its
	self._in_sub = false
	self._stack = {}
	self.title = title_text
	self.title_color = title_col
	self.r_in = if ctx.touch then 50.0 else 44.0
	self.r_out = if ctx.touch then 128.0 else 116.0
	if ctx.compact then
		self.r_in = 44.0
		self.r_out = 112.0
	end
	local area: Rect = ctx:clear_rect()
	-- (above the command bar: on phones the ring ran over it and its caption hid under the bar)
	if self.bottom_limit ~= nil then
		local b = self.bottom_limit()
		if type(b) == "number" and b > area.Min.Y + 200.0 and b < area.Max.Y then
			area = Rect.new(area.Min.X, area.Min.Y, area.Max.X, b - 4.0)
		end
	end
	-- Room for the ring plus its title pill above (≈34 px) and caption pill below (≈40 px).
	local fit = (area.Height - 34.0 - 40.0) * 0.5
	if self.r_out > fit then
		self.r_in = math.max(34.0, self.r_in * fit / self.r_out)
		self.r_out = math.max(80.0, fit)
	end
	local m = self.r_out + 12.0
	local lo_y = area.Min.Y + self.r_out + 34.0
	self.center = Vector2.new(
		math.clamp(pos.X, area.Min.X + m, math.max(area.Min.X + m, area.Max.X - m)),
		math.clamp(pos.Y, lo_y, math.max(lo_y, area.Max.Y - self.r_out - 40.0))
	)
	self.is_open = true
	self._closing = false
	self._saw_press = false
	-- Where the finger rests: the ring may be shifted to fit, so a release there is not a pick.
	self._press_pos = pos
	self._slid = false
	self._hover = -1
	self._anim = 0.0
	ctx:fit_canvas(self.gui)
	self.gui.Visible = true
	self._blocker.Active = true
	self._blocker.Visible = true
	self._built_for = nil
	self:_connect_input()
	ctx:sfx("open", -6.0)
	self:_redraw()
end

function RadialMenu.close(self: any, emit: boolean?)
	if not self.is_open then
		return
	end
	self.is_open = false
	self._closing = true
	-- Stay input-opaque until the close animation ends (the press that closed us must not fall
	-- through to the globe).
	if emit ~= false then
		self.closed:Fire()
	end
end

function RadialMenu._enter_sub(self: any, item: any)
	local sub = {}
	for _, d in item.sub or {} do
		table.insert(sub, d)
	end
	-- (rings nest: Build ▸ City ▸ ×1 ×5 ×10 ×Max; the centre button goes back one ring)
	if self._in_sub then
		table.insert(self._stack, { items = self.items, title = self._sub_title })
	end
	self.items = sub
	self._in_sub = true
	self._sub_title = tostring(item.label or "")
	self._hover = -1
	self._anim = 0.35
	self._built_for = nil
	self.ctx:sfx("click", -4.0)
	self:_redraw()
end

function RadialMenu._back(self: any)
	local prev = table.remove(self._stack)
	if prev ~= nil then
		self.items = prev.items
		self._sub_title = prev.title
		self._hover = -1
		self._anim = 0.35
		self._built_for = nil
		self.ctx:sfx("click", -6.0)
		self:_redraw()
		return
	end
	self.items = self._root_items
	self._in_sub = false
	self._hover = -1
	self._anim = 0.35
	self._built_for = nil
	self.ctx:sfx("click", -6.0)
	self:_redraw()
end

--- Per frame (UIRoot's loop).
function RadialMenu.update(self: any, delta: number)
	if self._closing then
		self._anim = math.max(0.0, self._anim - delta * 7.0)
		if self._anim <= 0.0 then
			self._closing = false
			self.gui.Visible = false
			self._blocker.Active = false
			self._blocker.Visible = false
			self:_disconnect_input()
		end
		self:_redraw()
	elseif self.is_open and self._anim < 1.0 then
		self._anim = math.min(1.0, self._anim + delta * 6.0)
		self:_redraw()
	end
end

-- ---------------------------------------------------------------------------------------------
-- Hit testing & input
-- ---------------------------------------------------------------------------------------------

function RadialMenu._index_at(self: any, p: Vector2): number
	local d = p - self.center
	local r = d.Magnitude
	self._center_hover = r < self.r_in - 4.0
	local n = #self.items
	if r < self.r_in - 4.0 or r > self.r_out + 18.0 or n == 0 then
		return -1
	end
	local span = TAU / n
	local a = (math.atan2(d.Y, d.X) + math.pi * 0.5 + span * 0.5) % TAU
	return math.clamp(math.floor(a / span), 0, n - 1)
end

function RadialMenu._set_hover(self: any, h: number)
	local prev_center = self._center_hover_drawn
	if h ~= self._hover or prev_center ~= self._center_hover then
		if h ~= self._hover and h >= 0 then
			self.ctx:sfx("hover", -12.0)
		end
		self._hover = h
		self:_redraw()
	end
end

--- Long-press, slide onto an item, release: pick it. A release on the centre / outside just
--- leaves the menu open for a normal tap.
function RadialMenu._release_at(self: any, pos: Vector2)
	self._saw_press = true
	if not self._slid then
		return -- a plain long-press: the menu stays open for a tap
	end
	local ri = self:_index_at(pos)
	if ri >= 0 then
		local it = self.items[ri + 1]
		if it.ok and it.sub == nil then
			local rid = tostring(it.id or "")
			local rt = self.tile
			self:close(false)
			self.picked:Fire(rid, rt)
		elseif it.sub ~= nil and it.ok then
			self:_enter_sub(it)
		end
	end
end

function RadialMenu._press(self: any, pos: Vector2, right: boolean)
	if not self.is_open then
		return
	end
	self._saw_press = true
	if right then
		if self._in_sub then
			self:_back()
		else
			self:close()
		end
		return
	end
	local i = self:_index_at(pos)
	self._hover = i
	if i < 0 then
		if self._center_hover and self._in_sub then
			self:_back()
		else
			self:close()
		end
		return
	end
	local it = self.items[i + 1]
	if not it.ok then
		self.ctx:sfx("deny", -4.0)
		self:_redraw()
		return
	end
	if it.sub ~= nil then
		self:_enter_sub(it)
		return
	end
	local id = tostring(it.id or "")
	local t = self.tile
	self:close(false)
	self.picked:Fire(id, t)
end

function RadialMenu._connect_input(self: any)
	if not UICtx.IS_ROBLOX or #self._conns > 0 then
		return
	end
	local ctx = self.ctx
	local UIS = game:GetService("UserInputService")
	local GuiService = game:GetService("GuiService")
	local function lpos(io: InputObject): Vector2
		local p = Vector2.new(io.Position.X, io.Position.Y)
		if io.UserInputType == Enum.UserInputType.Touch then
			p += GuiService:GetGuiInset()
		else
			p = UIS:GetMouseLocation()
		end
		return ctx:to_logical(p)
	end
	local b = self._blocker
	table.insert(
		self._conns,
		b.InputBegan:Connect(function(io: InputObject)
			local ty = io.UserInputType
			if ty == Enum.UserInputType.Touch and io.UserInputState ~= Enum.UserInputState.Begin then
				-- not a new touch: a finger already down "begins" on the blocker when it next moves or
				-- lifts over it, and the blocker has just appeared under the finger that opened the menu.
				-- Taken for a press at the ring's centre, the wobble of that finger lifting closed the
				-- menu as soon as the finger let go, which made press and hold useless on phones
				-- (2026-10-04). Its slide and release are followed below.
				return
			end
			if ty == Enum.UserInputType.MouseButton1 or ty == Enum.UserInputType.Touch then
				self:_press(lpos(io), false)
			elseif ty == Enum.UserInputType.MouseButton2 then
				self:_press(lpos(io), true)
			end
		end)
	)
	-- Hover (mouse) and the opening finger's slide / release (touch or mouse long-press).
	table.insert(
		self._conns,
		UIS.InputChanged:Connect(function(io: InputObject)
			if not self.is_open then
				return
			end
			local ty = io.UserInputType
			if ty == Enum.UserInputType.MouseMovement or (ty == Enum.UserInputType.Touch and not self._saw_press) then
				local p = lpos(io)
				-- a deliberate slide (not a finger's wobble on lifting: the ring may have shifted to fit, so
				-- the finger can rest on a segment) before a release there picks it
				if not self._saw_press and (p - self._press_pos).Magnitude > RadialMenu.SLIDE_PICK_PX then
					self._slid = true
				end
				self:_set_hover(self:_index_at(p))
			end
		end)
	)
	table.insert(
		self._conns,
		UIS.InputEnded:Connect(function(io: InputObject)
			if not self.is_open or self._saw_press then
				return
			end
			local ty = io.UserInputType
			if ty == Enum.UserInputType.Touch or ty == Enum.UserInputType.MouseButton1 then
				self:_release_at(lpos(io))
			end
		end)
	)
end

function RadialMenu._disconnect_input(self: any)
	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)
end

-- ---------------------------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------------------------

--- Variant of the segment masks closest to the ring's r_in / r_out ratio.
local function variant_for(ri: number, ro: number): (string?, number)
	local S = Shapes()
	local best, bq = nil, math.huge
	if S.variants == nil then
		return nil, 1
	end
	local q = ri / ro
	for name, v in S.variants do
		local d = math.abs(v.ri / v.ro - q)
		if d < bq then
			bq = d
			best = name
		end
	end
	return best, if best then ro / S.variants[best].ro else 1
end

function RadialMenu._redraw(self: any)
	local Th = T()
	local S = Shapes()
	local anim = self._anim
	if anim <= 0.0 then
		self._ring.Visible = false
		self._title_pill.frame.Visible = false
		self._cap_pill.frame.Visible = false
		return
	end
	self._ring.Visible = true
	local e = ease(anim)
	local s = 0.72 + (1.0 - 0.72) * e
	local alpha = math.clamp(anim * 1.6, 0.0, 1.0)
	local c = self.center
	local ri = self.r_in
	local ro = self.r_out
	self._ring.Position = UDim2.fromOffset(c.X, c.Y)
	self._ring_scale.Scale = s
	-- Soft backdrop disc.
	UICtx.set_circle(self._backdrop, Vector2.zero, ro + 36.0)
	self._backdrop.BackgroundTransparency = 1 - 0.36 * alpha
	local n = #self.items
	local span = TAU / math.max(n, 1)
	local S_px = S.px or 2
	for i = 1, math.max(n, #self._segs) do
		local sg = self._segs[i]
		if i > n then
			if sg then
				sg.fill.Visible = false
				sg.line.Visible = false
				sg.icon.Visible = false
				sg.label.Visible = false
			end
			continue
		end
		sg = self:_seg(i)
		local it = self.items[i]
		local ok = it.ok == true
		local danger = it.danger == true
		local hov = (i - 1) == self._hover
		local fill = rgb(0.06, 0.085, 0.17)
		local edge_a = 0.12
		local icol = Th.TEXT
		local icol_a = 1.0
		if danger and ok then
			icol = rgb(1.0, 0.8, 0.8)
		end
		if not ok then
			fill = rgb(0.05, 0.065, 0.12)
			icol = Th.TEXT
			icol_a = 0.28
		end
		if hov and ok then
			fill = if danger then Th.RED else Th.AMBER
			edge_a = 0.5
			icol = if danger then Color3.new(1, 1, 1) else Th.INK
		elseif hov then
			fill = rgb(0.12, 0.13, 0.2)
		end
		local ro2 = ro + (if hov and ok then 6.0 else 0.0)
		local rad = (i - 1) * span -- clockwise from 12 o'clock (segment centre)
		local ang = math.deg(rad)
		local vname, k = variant_for(ri, ro2)
		local fkey = if vname and n >= 2 then string.format("%s_%d_fill", vname, math.min(n, 8)) else nil
		local lkey = if vname and n >= 2 then string.format("%s_%d_line", vname, math.min(n, 8)) else nil
		local fd = if fkey and S.segments then S.segments[fkey] else nil
		local ld = if lkey and S.segments then S.segments[lkey] else nil
		local cs, sn = math.cos(rad), math.sin(rad)
		local function place(img: ImageLabel, d: any)
			if d == nil then
				img.Visible = false
				return
			end
			local sc = k / S_px -- logical px per mask px
			img.Visible = true
			img.Image = S.pages[d.page] or ""
			img.ImageRectOffset = Vector2.new(d.x, d.y)
			img.ImageRectSize = Vector2.new(d.w, d.h)
			img.Size = UDim2.fromOffset(d.w * sc, d.h * sc)
			local vx, vy = (d.w * 0.5 - d.cx) * sc, (d.h * 0.5 - d.cy) * sc
			img.Position = UDim2.fromOffset(vx * cs - vy * sn, vx * sn + vy * cs)
			img.Rotation = ang
		end
		if n == 1 then
			-- A single item: the whole annulus (no gap) as a thick stroked circle.
			sg.fill.Visible = false
			sg.line.Visible = false
			self:_single_ring(true, ri, ro2, fill, alpha, edge_a)
		else
			self:_single_ring(false)
			place(sg.fill, fd)
			place(sg.line, ld)
		end
		sg.fill.ImageColor3 = fill
		sg.fill.ImageTransparency = 1 - alpha
		sg.line.ImageColor3 = Color3.new(1, 1, 1)
		sg.line.ImageTransparency = 1 - edge_a * alpha
		-- Icon and label
		local mid = rad - math.pi * 0.5
		local rm = (ri + ro2) * 0.5
		local ip = Vector2.new(math.cos(mid), math.sin(mid)) * (rm - 5.0)
		sg.icon.Visible = true
		local id = Th.icon(tostring(it.icon or "info"))
		sg.icon.Image = id or ""
		sg.icon.Position = UDim2.fromOffset(ip.X, ip.Y - 5)
		sg.icon.ImageColor3 = icol
		sg.icon.ImageTransparency = 1 - icol_a * alpha
		sg.label.Visible = true
		sg.label.Text = tostring(it.label or "")
		sg.label.TextSize = UICtx.ts(math.max(11, Th.min_font_size or 0))
		-- Godot draws the label with its baseline at ip.y + 12 + 9; Rubik ascent 0.935 em.
		sg.label.Position = UDim2.fromOffset(ip.X, ip.Y + 21 - 0.935 * math.max(11, Th.min_font_size or 0))
		sg.label.TextColor3 = icol
		sg.label.TextTransparency = 1 - icol_a * alpha * (if ok then 0.95 else 1.0)
	end
	-- Centre button (the ring's inner gap is tinted so the map does not bleed through).
	UICtx.set_circle(self._gap_disc, Vector2.zero, ri - 1.0)
	self._gap_disc.BackgroundTransparency = 1 - 0.55 * alpha
	local cr = ri - 8.0
	UICtx.set_circle(self._center_btn, Vector2.zero, cr)
	self._center_btn.BackgroundColor3 = if self._center_hover then rgb(0.14, 0.18, 0.3) else rgb(0.09, 0.12, 0.22)
	self._center_btn.BackgroundTransparency = 1 - alpha
	self._center_stroke.Transparency = 1 - 0.16 * alpha
	self._center_hover_drawn = self._center_hover
	self._center_icon.Image = Th.icon(if self._in_sub then "retreat" else "close") or ""
	self._center_icon.ImageColor3 = Th.TEXT_2
	self._center_icon.ImageTransparency = 1 - alpha
	-- Title above, caption below.
	local head = if self._in_sub then string.upper(self._sub_title) else self.title
	local hcol = if self._in_sub then Th.TEXT else self.title_color
	self:_set_pill(self._title_pill, Vector2.new(c.X, c.Y - ro * s - 16.0), head, hcol, alpha)
	local cap_text = ""
	local cap_col = Th.TEXT
	if self._hover >= 0 and self._hover < n then
		local it2 = self.items[self._hover + 1]
		local cap = tostring(it2.label or "")
		local sub = ""
		local sub_col = Th.TEXT_2
		if not it2.ok then
			sub = tostring(it2.reason or "")
			sub_col = rgb(1.0, 0.6, 0.62)
		elseif it2.cost ~= nil then
			sub = Th.fmt_cost(it2.cost) .. " gold"
			sub_col = Th.GOLD
		elseif it2.id == "donate" and it2.troops ~= nil then
			-- capped at the ally's troop headroom (UIRules.donate_plan)
			sub = if it2.capped
				then string.format("%s troops (fills their cap)", Th.fmt_troops(it2.troops))
				else string.format(
					"%s troops (%d%%)",
					Th.fmt_troops(it2.troops),
					math.floor(self.ctx.ratio * 100 + 0.5)
				)
		elseif it2.id == "attack" or it2.id == "boat" or it2.id == "donate" then
			sub = string.format(
				"%s troops (%d%%)",
				Th.fmt_troops(self.ctx:troops_for_ratio()),
				math.floor(self.ctx.ratio * 100 + 0.5)
			)
		end
		cap_text = if sub == "" then cap else cap .. "  ·  " .. sub
		cap_col = if sub ~= "" then sub_col else Th.TEXT
	end
	self:_set_pill(self._cap_pill, Vector2.new(c.X, c.Y + ro * s + 26.0), cap_text, cap_col, alpha)
end

--- n == 1: the full annulus (Frame circle with a thick stroke) + its two outlines.
function RadialMenu._single_ring(
	self: any,
	on: boolean,
	ri: number?,
	ro: number?,
	fill: Color3?,
	alpha: number?,
	edge_a: number?
)
	if not on then
		if self._solo then
			self._solo.fill.Visible = false
			self._solo.outer.Visible = false
			self._solo.inner.Visible = false
		end
		return
	end
	if self._solo == nil then
		self._solo = {
			fill = UICtx.ring(self._seg_holder, Vector2.zero, 10, 10, Color3.new(), 0),
			outer = UICtx.ring(self._seg_holder, Vector2.zero, 10, 1, Color3.new(1, 1, 1), 0),
			inner = UICtx.ring(self._seg_holder, Vector2.zero, 10, 1, Color3.new(1, 1, 1), 0),
		}
		self._solo.fill.ZIndex = 2
		self._solo.outer.ZIndex = 3
		self._solo.inner.ZIndex = 3
	end
	local a = alpha :: number
	local r_i = ri :: number
	local r_o = ro :: number
	local mid = (r_i + r_o) * 0.5
	local w = r_o - r_i
	UICtx.set_circle(self._solo.fill, Vector2.zero, mid)
	local st = self._solo.fill:FindFirstChild("Stroke") :: UIStroke
	st.Thickness = w
	st.Color = fill :: Color3
	st.Transparency = 1 - a
	for _, pair in { { self._solo.outer, r_o }, { self._solo.inner, r_i } } do
		local f = pair[1]
		f.Visible = true
		UICtx.set_circle(f, Vector2.zero, pair[2])
		local s2 = f:FindFirstChild("Stroke") :: UIStroke
		s2.Transparency = 1 - (edge_a :: number) * a
	end
	self._solo.fill.Visible = true
end

return RadialMenu
