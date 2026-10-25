--!nonstrict
-- Map picker (the single-player map list): a modal grid of map cards (thumbnail, name, size) under
-- category tabs. Maps and thumbnails are CC BY-SA 4.0, attributed in the footer. The grid is a Roblox
-- ScrollingFrame with a UIGridLayout hosted in a kit Control (the kit has no scroll container); card
-- sizes follow UITheme.scale.
-- Signals: picked(map_id), closed.
-- Entries come from set_entries({ {id, name, width, height, categories, thumb}, ... }).

local UITheme = require("./UITheme")
local W = require("./Widgets")
local GlassPanel = require("./GlassPanel")
local UICtx = require("./UICtx")
local Signal = UITheme.core("Signal")

local MapPicker = W.class(W.Control)

--- Tabs: { label, predicate on the categories set }.
MapPicker.TABS = {
	{ "Featured", { featured = true } },
	{ "World", { world = true, continental = true } },
	{ "Europe", { europe = true } },
	{ "Asia", { asia = true } },
	{ "Americas", { north_america = true, south_america = true } },
	{ "Africa · Oceania", { africa = true, oceania = true, antarctica = true } },
	{ "All", nil },
}
MapPicker.CARD = Vector2.new(168, 132)
MapPicker.GRID_SIZE = Vector2.new(740, 420)
MapPicker.ATTRIBUTION = "Maps from OpenFront, CC BY-SA 4.0"

function MapPicker.new(c: any)
	local self = setmetatable({}, MapPicker.__mt)
	W.Control._init(self)
	self.ctx = c
	self.picked = Signal.new()
	self.closed = Signal.new()
	self.is_open = false
	self.entries = {} :: { any }
	self.selected = ""
	self._tab = 1
	self:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self:set_mouse_filter(W.MOUSE_STOP)
	self:set_visible(false)
	self._dim = W.ColorRect.new(UITheme.rgba(0.01, 0.015, 0.05, 0.6))
	self._dim:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self._dim.gui_input:Connect(function(e)
		-- (a press on the window's own ground reaches the dim too: only one outside it closes)
		if e.pressed and not self._panel:has_global_point(e.global_position) then
			self:close()
		end
	end)
	self:add_child(self._dim)
	self._panel = GlassPanel.new(22.0, 20.0, 18, true, 34)
	self._panel:set_tint(UITheme.rgba(0.045, 0.065, 0.13, 0.95))
	self:add_child(self._panel)
	local v = UITheme.vbox(12)
	self._panel:add_child(v)
	-- head: title + close
	local head = UITheme.hbox(10)
	local title = UITheme.label("CHOOSE A MAP", 20, 800, UITheme.TEXT, 3)
	title.size_flags_horizontal = W.EXPAND_FILL
	title.size_flags_vertical = W.SHRINK_CENTER
	head:add_child(title)
	local close = W.Button.new("", "GhostButton")
	close:set_icon("close")
	close.expand_icon = true
	close:set_min_size(Vector2.new(34, 34))
	close:add_theme_constant_override("icon_max_width", 13)
	close:add_theme_stylebox_override("normal", UITheme.empty_box(8, 8))
	close:add_theme_stylebox_override("hover", UITheme.flat(UITheme.FILL, 8, UITheme.CLEAR, 0, 8, 8))
	close.size_flags_vertical = W.SHRINK_CENTER
	close.pressed:Connect(function()
		self:close()
	end)
	head:add_child(close)
	v:add_child(head)
	-- tabs
	local tabs = UITheme.hbox(6)
	self._tabs = {}
	for i, t in ipairs(MapPicker.TABS) do
		local chip = UITheme.button(t[1], "ChipButton", "", 32.0)
		chip.toggle_mode = true
		chip:set_font_size(12)
		chip:set_pressed_no_signal(i == self._tab)
		chip.pressed:Connect(function()
			self._tab = i
			for j, ch in ipairs(self._tabs) do
				ch:set_pressed_no_signal(j == i)
			end
			self:_rebuild()
		end)
		table.insert(self._tabs, chip)
		tabs:add_child(chip)
	end
	v:add_child(tabs)
	-- grid host
	local host = W.Control.new()
	host:set_min_size(MapPicker.GRID_SIZE)
	host:set_mouse_filter(W.MOUSE_PASS)
	self._host = host
	v:add_child(host)
	local sf = Instance.new("ScrollingFrame")
	sf.Name = "MapGrid"
	sf.BackgroundTransparency = 1
	sf.BorderSizePixel = 0
	sf.Size = UDim2.fromScale(1, 1)
	sf.ScrollBarThickness = 6
	sf.ScrollBarImageColor3 = Color3.new(1, 1, 1)
	sf.ScrollBarImageTransparency = 0.6
	sf.AutomaticCanvasSize = Enum.AutomaticSize.Y
	sf.CanvasSize = UDim2.new(0, 0, 0, 0)
	sf.ScrollingDirection = Enum.ScrollingDirection.Y
	sf.ZIndex = 40
	sf.Parent = host.gui
	host:_part(sf, "ScrollBarImageTransparency", 0.4)
	self._sf = sf
	local grid = Instance.new("UIGridLayout")
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = sf
	self._grid = grid
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 2)
	pad.PaddingLeft = UDim.new(0, 2)
	pad.Parent = sf
	-- footer
	self._foot = UITheme.label(MapPicker.ATTRIBUTION, 11, 500, UITheme.TEXT_3)
	v:add_child(self._foot)
	self._cards = {} :: { [string]: TextButton }
	return self
end

function MapPicker.set_entries(self, entries: { any })
	self.entries = entries or {}
	if self.is_open then
		self:_rebuild()
	end
end

local function in_tab(e: any, set: { [string]: boolean }?): boolean
	if set == nil then
		return true
	end
	for _, c in e.categories or {} do
		if set[c] then
			return true
		end
	end
	return false
end

function MapPicker._card(self, e: any, order: number): TextButton
	local s = UITheme.scale
	local b = Instance.new("TextButton")
	b.Name = e.id
	b.Text = ""
	b.AutoButtonColor = false
	b.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	b.BackgroundTransparency = 0.94
	b.LayoutOrder = order
	b.ZIndex = 41
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, math.floor(10 * s))
	corner.Parent = b
	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Transparency = 0.88
	stroke.Thickness = 1
	stroke.Parent = b
	local img = Instance.new("ImageLabel")
	img.Name = "Thumb"
	img.BackgroundTransparency = 1
	img.Image = e.thumb or ""
	img.ScaleType = Enum.ScaleType.Fit
	img.Position = UDim2.fromOffset(math.floor(8 * s), math.floor(8 * s))
	img.Size = UDim2.new(1, -math.floor(16 * s), 1, -math.floor(46 * s))
	img.ZIndex = 42
	img.Parent = b
	local name = Instance.new("TextLabel")
	name.Name = "MapName"
	name.BackgroundTransparency = 1
	name.FontFace = Font.fromId(12187365977, Enum.FontWeight.Bold)
	name.TextSize = math.floor(14 * s)
	name.TextColor3 = Color3.new(1, 1, 1)
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.Text = e.name or e.id
	name.Position = UDim2.new(0, math.floor(8 * s), 1, -math.floor(36 * s))
	name.Size = UDim2.new(1, -math.floor(16 * s), 0, math.floor(18 * s))
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.ZIndex = 42
	name.Parent = b
	local sub = Instance.new("TextLabel")
	sub.Name = "Size"
	sub.BackgroundTransparency = 1
	sub.FontFace = Font.fromId(12187365977, Enum.FontWeight.Medium)
	sub.TextSize = math.floor(11 * s)
	sub.TextColor3 = Color3.fromRGB(170, 180, 205)
	sub.Text = if e.width and e.height then string.format("%d × %d", e.width, e.height) else ""
	sub.Position = UDim2.new(0, math.floor(8 * s), 1, -math.floor(18 * s))
	sub.Size = UDim2.new(1, -math.floor(16 * s), 0, math.floor(14 * s))
	sub.TextXAlignment = Enum.TextXAlignment.Left
	sub.ZIndex = 42
	sub.Parent = b
	-- Every piece is a part of the grid host, so the panel's pop-in / fade-out reaches the cards
	-- (raw instances showed at full strength before the panel did).
	local host = self._host
	host:_part(b, "BackgroundTransparency", 0.06)
	host:_part(stroke, "Transparency", 0.12)
	host:_part(img, "ImageTransparency", 1.0)
	host:_part(name, "TextTransparency", 1.0)
	host:_part(sub, "TextTransparency", 1.0)
	b.MouseEnter:Connect(function()
		host:_part(b, "BackgroundTransparency", 0.12)
	end)
	b.MouseLeave:Connect(function()
		host:_part(b, "BackgroundTransparency", 0.06)
	end)
	b.Activated:Connect(function()
		self.selected = e.id
		self.ctx:sfx("click")
		self.picked:Fire(e.id)
		self:close()
	end)
	b.Parent = self._sf
	return b
end

function MapPicker._rebuild(self)
	for _, b in self._cards do
		self._host:_drop_part(b)
		for _, d in b:GetDescendants() do
			self._host:_drop_part(d)
		end
		b:Destroy()
	end
	table.clear(self._cards)
	local s = UITheme.scale
	self._grid.CellSize = UDim2.fromOffset(math.floor(MapPicker.CARD.X * s), math.floor(MapPicker.CARD.Y * s))
	self._grid.CellPadding = UDim2.fromOffset(math.floor(10 * s), math.floor(10 * s))
	local set = MapPicker.TABS[self._tab][2]
	local list = {}
	for _, e in self.entries do
		if in_tab(e, set) then
			table.insert(list, e)
		end
	end
	table.sort(list, function(a, b)
		local ra, rb = a.featured_rank or 999, b.featured_rank or 999
		if ra ~= rb then
			return ra < rb
		end
		return (a.name or a.id) < (b.name or b.id)
	end)
	for i, e in list do
		local b = self:_card(e, i)
		if e.id == self.selected then
			local st = b:FindFirstChildOfClass("UIStroke") :: UIStroke
			st.Color = UITheme.color3(UITheme.to_rgba(UITheme.AMBER))
			self._host:_part(st, "Transparency", 1.0)
			st.Thickness = 2
		end
		self._cards[e.id] = b
	end
	self._sf.CanvasPosition = Vector2.zero
end

function MapPicker.open(self, selected: string?)
	if self.is_open then
		return
	end
	self.is_open = true
	self.selected = selected or self.selected
	-- open on the tab that shows the selected map
	self._tab = #MapPicker.TABS
	for i, t in ipairs(MapPicker.TABS) do
		for _, e in self.entries do
			if e.id == self.selected and in_tab(e, t[2]) then
				self._tab = i
				break
			end
		end
		if self._tab == i then
			break
		end
	end
	for j, ch in ipairs(self._tabs) do
		ch:set_pressed_no_signal(j == self._tab)
	end
	self:_rebuild()
	self:set_visible(true)
	self._panel:set_modulate_a(1.0)
	self:_center()
	self._dim:set_modulate_a(0.0)
	W.fade(self._dim, 1.0, 0.2)
	UICtx.pop_in(self._panel, 0.0, 0.94, 0.3)
	self.ctx:sfx("open")
end

function MapPicker.close(self)
	if not self.is_open then
		return
	end
	self.is_open = false
	self.ctx:sfx("close")
	local t = self:create_tween():set_parallel(true)
	t:tween_property(self._dim, "modulate:a", 0.0, 0.15)
	t:tween_property(self._panel, "modulate:a", 0.0, 0.15)
	t:chain():tween_callback(function()
		if not self.is_open then
			self:set_visible(false)
		end
	end)
	self.closed:Fire()
end

function MapPicker.apply_layout(self)
	local ctx = self.ctx
	local area = ctx:clear_rect()
	-- the grid takes what the screen allows (phones: fewer columns / rows)
	local gw = math.clamp(area.Width - 80, 360, MapPicker.GRID_SIZE.X)
	local gh = math.clamp(area.Height - 190, 200, MapPicker.GRID_SIZE.Y)
	self._host:set_min_size(Vector2.new(gw, gh))
	if self.is_open then
		self:_rebuild()
	end
	self:_center()
end

function MapPicker._center(self)
	local ctx = self.ctx
	local sz = self._panel:get_combined_minimum_size()
	local area = ctx:clear_rect()
	local p = area.Min + (Vector2.new(area.Width, area.Height) - sz) * 0.5
	local y = math.max(p.Y, area.Min.Y + 4.0)
	local rp = Vector2.new(math.floor(p.X + 0.5), math.floor(y + 0.5))
	self._panel:set_offsets(rp.X, rp.Y, rp.X, rp.Y)
	self._panel:reset_size()
end

return MapPicker
