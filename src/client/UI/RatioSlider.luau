--!nonstrict
-- The Attack bar: the share of the army an order sends, bound to UICtx.ratio. Five stops in one row
-- (UICtx.RATIO_STOPS: 10% 25% 35% 50% 75%), each one a labelled target: tap a stop, or drag across
-- them, and the amber thumb moves to it. The mouse wheel steps one stop.
--
-- It was a slider (a port of scripts/ui/ratio_slider.gd): 1% to 100% in steps of 1%, on a phone a
-- knob on a 96 px track, replaced 2026-10-08: it was too small and hard to drag to the right spot,
-- and a few fixed stops are simpler, at better breakpoints (10%, 25%, 35%,
-- 50%, 75%). The tutorial's step on it lost 19.4% of the players who reached it (Tutorial funnel,
-- 2026-10-07): what it asked for, 27% to 45%, was 17 px of that track.
--
-- A stop above UICtx.ratio_max (the tutorial stops at 50%) is drawn faint, and a tap on it sets the
-- highest stop allowed.

local UserInputService = game:GetService("UserInputService")

local UICtx = require("./UICtx") :: any
local UITheme = require("./UITheme")
local W = require("./Widgets")

local RatioSlider = W.class(W.Control)

function RatioSlider.new(c: any)
	local self = setmetatable({}, RatioSlider.__mt)
	W.Control._init(self)
	self.ctx = c
	self.gui.Name = "RatioSlider"
	--- The row's height (it sits in the middle of the control, whose whole rect takes input).
	self.track_height = 26.0
	--- The stops' text.
	self.font_size = 12
	self._drag = false
	self._hover = -1
	local _, at = UICtx.ratio_stop(c.ratio, c.ratio_max)
	--- Where the thumb is drawn: a stop's index, or between two while it moves.
	self._shown = at
	self:set_min_size(Vector2.new(170, 26))
	self:set_mouse_filter(W.MOUSE_STOP)
	local g = self.gui
	local function frame(name: string, z: number): (Frame, UICorner)
		local f = Instance.new("Frame")
		f.Name = name
		f.BorderSizePixel = 0
		f.AnchorPoint = Vector2.zero
		f.ZIndex = z
		f.Active = false
		f.Parent = g
		local cr = Instance.new("UICorner")
		cr.Parent = f
		return f, cr
	end
	self._track, self._track_corner = frame("Track", 1)
	local ts = Instance.new("UIStroke")
	ts.Thickness = 1
	ts.Color = Color3.new(1, 1, 1)
	ts.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	ts.Parent = self._track
	self._track_stroke = ts
	self._glow, self._glow_corner = frame("Glow", 2)
	self._thumb, self._thumb_corner = frame("Thumb", 3)
	self._labels = {}
	for i, stop in UICtx.RATIO_STOPS do
		local t = Instance.new("TextLabel")
		t.Name = "Stop" .. i
		t.BackgroundTransparency = 1
		t.BorderSizePixel = 0
		t.AnchorPoint = Vector2.zero
		t.RichText = false
		t.Active = false
		t.ZIndex = 4
		t.Text = string.format("%d%%", math.floor(stop * 100 + 0.5))
		t.TextXAlignment = Enum.TextXAlignment.Center
		t.TextYAlignment = Enum.TextYAlignment.Center
		t.Parent = g
		self._labels[i] = t
	end
	self:_connect(c.ratio_changed:Connect(function(_r)
		self:set_process(true)
		self:_redraw()
	end))
	self:_connect(g.MouseLeave:Connect(function()
		self._hover = -1
		self:_redraw()
	end))
	self:_connect(g.InputBegan:Connect(function(io: InputObject)
		local t = io.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
			self._drag = true
			self._drag_input = io
			self:_set_from_global(W.screen_to_logical(W.input_pos(io), self))
			self.ctx:sfx("click", -10.0)
			self:_redraw()
		end
	end))
	self:_connect(g.InputChanged:Connect(function(io: InputObject)
		if io.UserInputType == Enum.UserInputType.MouseWheel and io.Position.Z ~= 0 then
			self.ctx:step_ratio(io.Position.Z)
		elseif io.UserInputType == Enum.UserInputType.MouseMovement then
			-- (the stop under the cursor reads brighter)
			local p = W.screen_to_logical(W.input_pos(io), self)
			local i = self:_stop_at(p.X - self:get_global_position().X)
			if i ~= self._hover then
				self._hover = i
				self:_redraw()
			end
		end
	end))
	self:_connect(UserInputService.InputChanged:Connect(function(io: InputObject)
		if not self._drag then
			return
		end
		local t = io.UserInputType
		if t == Enum.UserInputType.MouseMovement or (t == Enum.UserInputType.Touch and io == self._drag_input) then
			local before = self.ctx.ratio
			self:_set_from_global(W.screen_to_logical(W.input_pos(io), self))
			if self.ctx.ratio ~= before then
				self.ctx:sfx("click", -14.0) -- (a tick for every stop the finger crosses)
			end
		end
	end))
	self:_connect(UserInputService.InputEnded:Connect(function(io: InputObject)
		if not self._drag then
			return
		end
		local t = io.UserInputType
		if t == Enum.UserInputType.MouseButton1 or (t == Enum.UserInputType.Touch and io == self._drag_input) then
			self._drag = false
			self._drag_input = nil
			self:_redraw()
		end
	end))
	return self
end

function RatioSlider._process(self, delta: number)
	local _, target = UICtx.ratio_stop(self.ctx.ratio, self.ctx.ratio_max)
	self._shown = self._shown + (target - self._shown) * (1 - math.exp(-delta * 24.0))
	if math.abs(self._shown - target) < 0.004 then
		self._shown = target
		self:set_process(false)
	end
	self:_redraw()
end

--- Second-finger drags (UITouchRouter): position in logical screen coordinates.
function RatioSlider.drag_to_global(self, p: Vector2)
	self:_set_from_global(p)
end

--- The stop (index in RATIO_STOPS) under local x.
function RatioSlider._stop_at(self, x: number): number
	local n = #UICtx.RATIO_STOPS
	return math.clamp(math.floor(x / math.max(self.size.X, 1.0) * n) + 1, 1, n)
end

function RatioSlider._set_from_global(self, p: Vector2)
	self:_set_from_x(p.X - self:get_global_position().X)
end

function RatioSlider._set_from_x(self, x: number)
	self.ctx:set_ratio(UICtx.RATIO_STOPS[self:_stop_at(x)])
end

--- The rect of the stop for `ratio` in logical screen coordinates (the tutorial points at it), or
--- nil when the bar has no stop there.
function RatioSlider.stop_rect(self, ratio: number): any
	local stops = UICtx.RATIO_STOPS
	for i, stop in stops do
		if math.abs(stop - ratio) < 1e-6 then
			local r = self:get_global_rect()
			local cw = r.Width / #stops
			local h = math.min(self.track_height, r.Height)
			return Rect.new(r.Min.X + (i - 1) * cw, r.Min.Y + (r.Height - h) * 0.5, r.Min.X + i * cw, r.Min.Y + (r.Height + h) * 0.5)
		end
	end
	return nil
end

function RatioSlider._on_geometry(self)
	self:_redraw()
end

function RatioSlider._restyle(self)
	self:_redraw()
end

local function set_rect(f: GuiObject, x: number, y: number, w: number, h: number)
	local s = UITheme.scale
	local x0 = math.floor(x * s + 0.5)
	local y0 = math.floor(y * s + 0.5)
	local x1 = math.floor((x + w) * s + 0.5)
	local y1 = math.floor((y + h) * s + 0.5)
	f.Position = UDim2.fromOffset(x0, y0)
	f.Size = UDim2.fromOffset(math.max(0, x1 - x0), math.max(0, y1 - y0))
end

function RatioSlider._redraw(self)
	if self._geo == nil then
		return
	end
	local ctx = self.ctx
	local s = UITheme.scale
	local stops = UICtx.RATIO_STOPS
	local n = #stops
	local w = self.size.X
	local th = math.min(self.track_height, self.size.Y)
	local ty = (self.size.Y - th) * 0.5
	local cw = w / n
	local _, at = UICtx.ratio_stop(ctx.ratio, ctx.ratio_max)
	local radius = math.min(th * 0.5, 10.0)
	-- the row
	set_rect(self._track, 0, ty, w, th)
	self._track_corner.CornerRadius = UDim.new(0, math.floor(radius * s + 0.5))
	self._track.BackgroundColor3 = Color3.new(1, 1, 1)
	self:_part(self._track, "BackgroundTransparency", 0.07)
	self:_part(self._track_stroke, "Transparency", 0.12)
	-- the thumb, on the stop in use (and a soft edge around it while it is held)
	local inset = 2.0
	local x = (self._shown - 1) * cw + inset
	local hot = self._drag
	self._glow.Visible = hot
	if hot then
		set_rect(self._glow, x - 2.0, ty + inset - 2.0, cw - inset * 2.0 + 4.0, th - inset * 2.0 + 4.0)
		self._glow_corner.CornerRadius = UDim.new(0, math.floor((radius - inset + 2.0) * s + 0.5))
		self._glow.BackgroundColor3 = UITheme.AMBER
		self:_part(self._glow, "BackgroundTransparency", 0.3)
	end
	set_rect(self._thumb, x, ty + inset, cw - inset * 2.0, th - inset * 2.0)
	self._thumb_corner.CornerRadius = UDim.new(0, math.floor((radius - inset) * s + 0.5))
	self._thumb.BackgroundColor3 = if hot then UITheme.AMBER_HI else UITheme.AMBER
	self:_part(self._thumb, "BackgroundTransparency", 1.0)
	-- the stops
	local ts = UITheme.text_size(self.font_size)
	local top = (ctx.ratio_max or 1.0) + 1e-6
	for i, t in self._labels do
		set_rect(t, (i - 1) * cw, ty, cw, th)
		t.TextSize = ts
		local on = i == at
		local locked = stops[i] > top
		t.FontFace = UITheme.font(if on then 800 else 700)
		if on then
			t.TextColor3 = UITheme.INK
			self:_part(t, "TextTransparency", 1.0)
		elseif locked then
			t.TextColor3 = UITheme.TEXT_3
			self:_part(t, "TextTransparency", 0.4)
		else
			t.TextColor3 = if i == self._hover then UITheme.TEXT else UITheme.TEXT_2
			self:_part(t, "TextTransparency", 1.0)
		end
	end
end

return RatioSlider
