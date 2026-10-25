-- Touch: a ring that closes in around a finger held on the map until the long-press menu opens
-- (2026-09-29: the press-and-hold quick build menu felt inconsistent on phones). It shows that the
-- hold is counting (keep still) and when it will open. Driven each frame by UIRoot from
-- MapInput.hold_state(); drawn on a raw logical-px canvas (UICtx.canvas), input-transparent.
local UICtx = require("./UICtx") :: any

local HoldRing = {}
HoldRing.__index = HoldRing

--- The ring appears once a hold is this far along (a tap never flashes it).
HoldRing.SHOW_FROM = 0.2
HoldRing.SIZE = 58.0 -- logical px, the closed ring's diameter

function HoldRing.new(c: any)
	local self = setmetatable({}, HoldRing)
	self.ctx = c
	local canvas = UICtx.canvas(nil, "HoldRing")
	canvas.Visible = false
	self.gui = canvas
	local ring = UICtx.make("Frame", {
		Name = "Ring",
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(HoldRing.SIZE, HoldRing.SIZE),
		ZIndex = 2,
	}, canvas)
	UICtx.make("UICorner", { CornerRadius = UDim.new(0.5, 0) }, ring)
	self._stroke = UICtx.make("UIStroke", {
		Color = Color3.fromRGB(255, 214, 120),
		Thickness = 3,
		Transparency = 1,
	}, ring)
	self._ring = ring
	-- a soft fill that brightens as it closes
	local fill = UICtx.make("Frame", {
		Name = "Fill",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		BackgroundColor3 = Color3.fromRGB(255, 214, 120),
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 1,
	}, ring)
	UICtx.make("UICorner", { CornerRadius = UDim.new(0.5, 0) }, fill)
	self._fill = fill
	return self
end

--- pos: the finger (logical px) or nil; k: the hold's progress 0..1.
function HoldRing.set(self: any, pos: Vector2?, k: number)
	if pos == nil or k < HoldRing.SHOW_FROM or k >= 1 then
		if self.gui.Visible then
			self.gui.Visible = false
		end
		return
	end
	if not self.gui.Visible then
		self.ctx:fit_canvas(self.gui)
		self.gui.Visible = true
	end
	local q = (k - HoldRing.SHOW_FROM) / (1 - HoldRing.SHOW_FROM)
	local e = 1 - (1 - q) * (1 - q)
	local d = HoldRing.SIZE * (1.9 - 0.9 * e)
	self._ring.Position = UDim2.fromOffset(pos.X, pos.Y)
	self._ring.Size = UDim2.fromOffset(d, d)
	self._stroke.Transparency = 0.85 - 0.7 * e
	self._stroke.Thickness = 2 + 2 * e
	self._fill.BackgroundTransparency = 0.95 - 0.25 * e
end

return HoldRing
