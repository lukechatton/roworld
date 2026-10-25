--!nonstrict
-- Port of scripts/ui/fill_bar.gd (UIBar)
-- Rounded progress track with an animated fill, optional goal line and value markers.

local UITheme = require("./UITheme")
local W = require("./Widgets")

local FillBar = W.class(W.Control)

--- UIBar.new(h = 4, c = CYAN)
function FillBar.new(h: number?, c: any?)
	local self = setmetatable({}, FillBar.__mt)
	W.Control._init(self)
	self.value = 0.0 -- 0..1 (animated towards target)
	self.target = 0.0
	self.fill_color = c or UITheme.CYAN
	self.fill_color_2 = UITheme.CLEAR -- optional right-end colour (gradient)
	self.track_color = UITheme.rgba(1, 1, 1, 0.08)
	self.goal = -1.0 -- 0..1 goal line (e.g. 0.8 to win)
	self.goal_color = UITheme.GOLD
	--- {{v: number, color: Color3}} thin vertical ticks (e.g. the leader's share).
	self.markers = {}
	self.glow = true
	self.bar_height = h or 4.0
	self:set_min_size(Vector2.new(40, self.bar_height))
	self:set_mouse_filter(W.MOUSE_IGNORE)
	local g = self.gui
	local function frame(name: string, z: number): Frame
		local f = Instance.new("Frame")
		f.Name = name
		f.BorderSizePixel = 0
		f.AnchorPoint = Vector2.zero
		f.ZIndex = z
		f.Active = false
		f.Parent = g
		return f
	end
	self._track = frame("Track", 1)
	self._track_c = Instance.new("UICorner")
	self._track_c.Parent = self._track
	self._glow = frame("Glow", 2)
	self._glow_c = Instance.new("UICorner")
	self._glow_c.Parent = self._glow
	self._fill = frame("Fill", 3)
	self._fill_c = Instance.new("UICorner")
	self._fill_c.Parent = self._fill
	self._grad = nil
	self._goal = frame("Goal", 5)
	self._marks = {}
	return self
end

function FillBar.set_target(self, v: number, instant: boolean?)
	self.target = math.clamp(v, 0, 1)
	if instant then
		self.value = self.target
	end
	if math.abs(self.value - self.target) > 1e-6 then
		self:set_process(true)
	end
	self:queue_redraw()
end

function FillBar._process(self, delta: number)
	if math.abs(self.value - self.target) > 1e-6 then
		self.value = self.value + (self.target - self.value) * (1 - math.exp(-delta * 6.0))
		if math.abs(self.value - self.target) < 0.0005 then
			self.value = self.target
		end
		self:_redraw()
	else
		self:set_process(false)
	end
end

function FillBar._on_geometry(self)
	self:_redraw()
end

function FillBar._restyle(self)
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

function FillBar._redraw(self)
	if self._geo == nil then
		return
	end
	local s = UITheme.scale
	local h = self.bar_height
	local y = (self.size.Y - h) * 0.5
	local w = self.size.X
	local r = h * 0.5
	set_rect(self._track, 0, y, w, h)
	self._track_c.CornerRadius = UDim.new(0, math.floor(math.min(r, h * 0.5) * s + 0.5))
	self._track.BackgroundColor3 = UITheme.color3(self.track_color)
	self:_part(self._track, "BackgroundTransparency", UITheme.alpha(self.track_color))
	local fw = w * self.value
	local show = fw > 0.5
	self._fill.Visible = show
	self._glow.Visible = show and self.glow
	if show then
		local frw = math.max(fw, h)
		local fc = UITheme.to_rgba(self.fill_color)
		if self.glow then
			set_rect(self._glow, -1.5, y - 1.5, frw + 3, h + 3)
			self._glow_c.CornerRadius = UDim.new(0, math.floor((r + 1.5) * s + 0.5))
			self._glow.BackgroundColor3 = fc.color
			self:_part(self._glow, "BackgroundTransparency", 0.22)
		end
		set_rect(self._fill, 0, y, frw, h)
		self._fill.BackgroundColor3 = fc.color
		self:_part(self._fill, "BackgroundTransparency", fc.alpha)
		local c2 = UITheme.to_rgba(self.fill_color_2)
		if c2.alpha > 0 then
			-- gradient fill (Godot draws a square-cornered polygon)
			self._fill_c.CornerRadius = UDim.new(0, 0)
			self._fill.BackgroundColor3 = Color3.new(1, 1, 1)
			if self._grad == nil then
				self._grad = Instance.new("UIGradient")
				self._grad.Parent = self._fill
			end
			self._grad.Color = ColorSequence.new(fc.color, c2.color)
		else
			self._fill_c.CornerRadius = UDim.new(0, math.floor(r * s + 0.5))
			if self._grad then
				self._grad:Destroy()
				self._grad = nil
			end
		end
	end
	if self.goal >= 0 then
		local gx = math.floor(w * self.goal + 0.5)
		self._goal.Visible = true
		set_rect(self._goal, gx - 1, y - 4, 2, h + 8)
		self._goal.BackgroundColor3 = UITheme.color3(self.goal_color)
		self:_part(self._goal, "BackgroundTransparency", UITheme.alpha(self.goal_color))
	else
		self._goal.Visible = false
	end
	for i, m in ipairs(self.markers) do
		local pair = self._marks[i]
		if pair == nil then
			local dark = Instance.new("Frame")
			dark.BorderSizePixel = 0
			dark.AnchorPoint = Vector2.zero
			dark.ZIndex = 6
			dark.BackgroundColor3 = Color3.new(0, 0, 0)
			dark.Parent = self.gui
			local lit = Instance.new("Frame")
			lit.BorderSizePixel = 0
			lit.AnchorPoint = Vector2.zero
			lit.ZIndex = 7
			lit.Parent = self.gui
			pair = { dark, lit }
			self._marks[i] = pair
		end
		local mx = math.floor(w * math.clamp(m.v or 0, 0, 1) + 0.5)
		pair[1].Visible = true
		pair[2].Visible = true
		set_rect(pair[1], mx - 2, y - 3, 4, h + 6)
		self:_part(pair[1], "BackgroundTransparency", 0.6)
		set_rect(pair[2], mx - 1, y - 3, 2, h + 6)
		local mc = UITheme.to_rgba(m.color or UITheme.TEXT)
		pair[2].BackgroundColor3 = mc.color
		self:_part(pair[2], "BackgroundTransparency", mc.alpha)
	end
	for i = #self.markers + 1, #self._marks do
		self._marks[i][1].Visible = false
		self._marks[i][2].Visible = false
	end
end

return FillBar
