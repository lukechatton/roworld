--!nonstrict
-- ui-screens dev: a flat stand-in WorldView (until the globe lands in this place). Shows a lat/lon
-- window of the map as a coarse grid coloured by owner, and implements the WorldView surface the UI
-- uses: tile_hovered / tile_clicked / tile_context signals (mouse + touch, 6/12 px tap slop, 500 ms
-- long-press), tile_at_screen / screen_pos_of_tile (viewport px), focus_tile / focus_owner, and
-- no-op recorders for every set_* call.

local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local UI = script.Parent.Parent:WaitForChild("UI")
local UICtx = require(UI.UICtx)
local Signal = UICtx.core("Signal")
local Defs = UICtx.core("Defs")

local World = {}
World.__index = World

local COLS, ROWS = 96, 54

function World.new(parent: Instance)
	local self = setmetatable({}, World)
	self.tile_hovered = Signal.new()
	self.tile_clicked = Signal.new()
	self.tile_context = Signal.new()
	self.input_enabled = true
	self.calls = {}
	self.state = nil
	self.lat = 50.0
	self.lon = 15.0
	self.span_lon = 60.0 -- degrees across the viewport
	self._hover = -2
	self._press = nil
	local sg = Instance.new("ScreenGui")
	sg.Name = "MockWorld"
	sg.IgnoreGuiInset = true
	sg.ResetOnSpawn = false
	sg.DisplayOrder = -10
	sg.Parent = parent
	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromRGB(12, 15, 58)
	bg.BorderSizePixel = 0
	bg.Parent = sg
	self._cells = {}
	for j = 0, ROWS - 1 do
		for i = 0, COLS - 1 do
			local f = Instance.new("Frame")
			f.BorderSizePixel = 0
			f.Size = UDim2.fromScale(1 / COLS + 0.0005, 1 / ROWS + 0.0005)
			f.Position = UDim2.fromScale(i / COLS, j / ROWS)
			f.BackgroundTransparency = 1
			f.Parent = bg
			self._cells[j * COLS + i] = f
		end
	end
	self._bg = bg
	self:_connect_input()
	task.spawn(function()
		while self._bg.Parent do
			self:_paint()
			task.wait(0.5)
		end
	end)
	return self
end

function World.bind_state(self, s)
	self.state = s
end

function World._vp(_self): Vector2
	return workspace.CurrentCamera.ViewportSize
end

function World.tile_at_screen(self, p: Vector2): number
	local vp = self:_vp()
	local span_lat = self.span_lon * vp.Y / vp.X * 1.4
	local lon = self.lon + (p.X / vp.X - 0.5) * self.span_lon
	local lat = self.lat - (p.Y / vp.Y - 0.5) * span_lat
	if lat < -89 or lat > 89 then
		return -1
	end
	local x = math.floor(((lon + 180) % 360) / 360 * Defs.W)
	local y = math.floor((90 - lat) / 180 * Defs.H)
	return math.clamp(y, 0, Defs.H - 1) * Defs.W + math.clamp(x, 0, Defs.W - 1)
end

function World.screen_pos_of_tile(self, t: number): Vector2
	if t < 0 then
		return Vector2.new(-1, -1)
	end
	local vp = self:_vp()
	local span_lat = self.span_lon * vp.Y / vp.X * 1.4
	local lat, lon = Defs.tile_latlon(t)
	local dl = ((lon - self.lon + 540) % 360) - 180
	local x = (dl / self.span_lon + 0.5) * vp.X
	local y = ((self.lat - lat) / span_lat + 0.5) * vp.Y
	if x < 0 or y < 0 or x > vp.X or y > vp.Y then
		return Vector2.new(-1, -1)
	end
	return Vector2.new(x, y)
end

function World._paint(self)
	local s = self.state
	local vp = self:_vp()
	for j = 0, ROWS - 1 do
		for i = 0, COLS - 1 do
			local f = self._cells[j * COLS + i]
			local t = self:tile_at_screen(Vector2.new((i + 0.5) / COLS * vp.X, (j + 0.5) / ROWS * vp.Y))
			if t < 0 or s == nil then
				f.BackgroundTransparency = 1
			else
				local own = s:tile_owner(t)
				if own ~= 0 then
					f.BackgroundColor3 = s:owner_color(own)
					f.BackgroundTransparency = if own == self._hover_owner then 0.0 else 0.15
				elseif s.map:is_land(t) then
					f.BackgroundColor3 = Color3.fromRGB(70, 78, 60)
					f.BackgroundTransparency = 0.1
				else
					f.BackgroundTransparency = 1
				end
			end
		end
	end
end

function World._connect_input(self)
	local function vpos(io: InputObject): Vector2
		if io.UserInputType == Enum.UserInputType.Touch then
			return Vector2.new(io.Position.X, io.Position.Y) + GuiService:GetGuiInset()
		end
		return UserInputService:GetMouseLocation()
	end
	UserInputService.InputChanged:Connect(function(io, gp)
		if not self.input_enabled then
			return
		end
		if io.UserInputType == Enum.UserInputType.MouseMovement then
			local t = if gp then -1 else self:tile_at_screen(vpos(io))
			if t ~= self._hover then
				self._hover = t
				self.tile_hovered:Fire(t)
			end
			if self._press and (vpos(io) - self._press.pos).Magnitude > 6 then
				self._press.moved = true
			end
		elseif io.UserInputType == Enum.UserInputType.Touch and self._press and self._press.io == io then
			if (vpos(io) - self._press.pos).Magnitude > 12 then
				self._press.moved = true
			end
		end
	end)
	UserInputService.InputBegan:Connect(function(io, gp)
		if gp or not self.input_enabled then
			return
		end
		local ty = io.UserInputType
		if ty == Enum.UserInputType.MouseButton2 then
			local p = vpos(io)
			self.tile_context:Fire(self:tile_at_screen(p), p)
		elseif ty == Enum.UserInputType.MouseButton1 or ty == Enum.UserInputType.Touch then
			local press = { io = io, pos = vpos(io), moved = false, ctx = false }
			self._press = press
			task.delay(0.5, function()
				if self._press == press and not press.moved then
					press.ctx = true
					self.tile_context:Fire(self:tile_at_screen(press.pos), press.pos)
				end
			end)
		end
	end)
	UserInputService.InputEnded:Connect(function(io, _gp)
		local press = self._press
		if press == nil or (io ~= press.io and io.UserInputType ~= Enum.UserInputType.MouseButton1) then
			return
		end
		self._press = nil
		if not self.input_enabled or press.moved or press.ctx then
			return
		end
		local t = self:tile_at_screen(press.pos)
		if t >= 0 then
			self.tile_clicked:Fire(t)
		end
	end)
end

function World.set_input_enabled(self, on: boolean)
	self.input_enabled = on
	if not on then
		self._press = nil
	end
end

function World.set_hover_owner(self, id)
	self._hover_owner = id
end

function World.focus_tile(self, t, _d, _dur)
	local lat, lon = Defs.tile_latlon(t)
	self.lat, self.lon = lat, lon
end

function World.focus_owner(self, id)
	if self.state then
		self:focus_tile(self.state:label_tile(id))
	end
end

function World.aim_sams()
	return 0
end

function World.camera_distance()
	return 2.6
end

function World.touch_owned_by_world()
	return false
end

function World.unit_at_screen()
	return -1
end

for _, m in ipairs({
	"set_attract_mode",
	"set_selected_owner",
	"set_aim",
	"set_labels_visible",
	"set_safe_area",
	"set_hud_rects",
	"set_hud_controls",
	"set_range_mode",
	"set_range_owner",
	"set_range_focus",
	"set_selected_unit",
}) do
	World[m] = function(self, ...)
		table.insert(self.calls, { m, ... })
		if #self.calls > 200 then
			table.remove(self.calls, 1)
		end
	end
end

return World
