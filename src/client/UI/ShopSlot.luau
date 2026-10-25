--!nonstrict
-- The SHOP button that closes the build row (CommandBar): one gold button, a little wider than a build
-- slot, that opens the Arsenal (2026-10-12: one button instead of six sub-buttons, as too few players
-- were opening the shop and more of them should click it; from 2026-10-05
-- it held a small card for each locked unit, before that it was a plain glass slot).
--
-- Solid gold with SHOP on it in dark letters. Over the word, the render of something the player has
-- yet to get (Assets/ArsenalArt.renders, the shop cards' pictures), a new one every CYCLE_S; a shine
-- crosses it every SHINE_S. Until the player has opened the Arsenal in this session, a red badge
-- counts what there is to get and the button gives a little shake every WIGGLE_S. With everything
-- got it is the Arsenal's shield over SHOP, still gold.
--
-- A press opens the Arsenal on the item it shows.
--
-- Signals: wanted(key: string?, from: string) (from: "match", for the analytics).
local UITheme = require("./UITheme")
local W = require("./Widgets")
local Signal = UITheme.core("Signal")

local IS_ROBLOX = typeof(game) == "Instance"
local TweenService = if IS_ROBLOX then game:GetService("TweenService") else nil
local function airfront(folder: string, name: string): any
	if IS_ROBLOX then
		return require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Airfront")[folder][name]) :: any
	end
	return (require :: any)("../../shared/" .. folder .. "/" .. name)
end
local Catalog = airfront("Data", "Arsenal")
local Art: any = (function()
	local ok, m = pcall(airfront, "Assets", "ArsenalArt")
	return if ok and type(m) == "table" then m else {}
end)()

local ShopSlot = W.class(W.Control)

--- A new item every this long, the crossfade's length, a shine every this long, a shake every this
--- long (while the badge shows).
ShopSlot.CYCLE_S = 2.4
ShopSlot.FADE_S = 0.3
ShopSlot.SHINE_S = 3.2
ShopSlot.WIGGLE_S = 6.4
--- The strip at the bottom the word SHOP sits in, logical px.
ShopSlot.CAPTION_H = 17.0

local GOLD_LIGHT = Color3.fromRGB(255, 226, 122)
local GOLD_DEEP = Color3.fromRGB(238, 148, 28)
local INK = Color3.fromRGB(52, 28, 2)
local RED = Color3.fromRGB(232, 52, 52)
local FONT_H = Font.fromId(12187365977, Enum.FontWeight.Heavy)

local function new(class: string, props: { [string]: any }, parent: Instance?): any
	local i = Instance.new(class)
	for k, v in props do
		(i :: any)[k] = v
	end
	if parent then
		i.Parent = parent
	end
	return i
end

local function tween(inst: Instance, t: number, props: { [string]: any }, style: Enum.EasingStyle?)
	if TweenService ~= nil then
		TweenService:Create(inst, TweenInfo.new(t, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
			:Play()
	end
end

function ShopSlot.new(c: any)
	local self = setmetatable({}, ShopSlot.__mt)
	W.Control._init(self)
	self.ctx = c
	self.wanted = Signal.new()
	--- the items shown, in shop order
	self._items = {} :: { any }
	self._sig = nil :: string?
	--- the Arsenal was opened from here in this session (the badge and the shake stop)
	self._seen = false
	self._t = 0.0
	self._hover = false
	self:set_mouse_filter(W.MOUSE_IGNORE)
	self:_build()
	self:set_block(58.0, 60.0)
	self:set_process(true)
	return self
end

function ShopSlot._build(self)
	local root = self.gui
	root.ClipsDescendants = false
	local body = new("Frame", {
		Name = "Shop",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		ZIndex = 1,
	}, root)
	self._body = body
	self._scale = new("UIScale", {}, body)
	local ground = new("Frame", {
		Name = "Ground",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 1,
	}, body)
	self._corner = new("UICorner", {}, ground)
	-- (a UIGradient multiplies the frame's colour: the frame is white)
	self._grad = new("UIGradient", { Color = ColorSequence.new(GOLD_LIGHT, GOLD_DEEP), Rotation = 90 }, ground)
	self._stroke = new("UIStroke", {
		Color = INK,
		Thickness = 1.5,
		Transparency = 0.25,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, ground)
	-- the two pictures it crossfades between, and its shield when there is nothing left to get
	self._pics = {}
	for i = 1, 2 do
		self._pics[i] = new("ImageLabel", {
			Name = "Item" .. i,
			BackgroundTransparency = 1,
			Image = "",
			ImageTransparency = 1,
			ScaleType = Enum.ScaleType.Fit,
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = 3,
		}, body)
	end
	self._shield = new("ImageLabel", {
		Name = "Shield",
		BackgroundTransparency = 1,
		Image = UITheme.icon("arsenal") or "",
		ImageColor3 = INK,
		ScaleType = Enum.ScaleType.Fit,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Visible = false,
		ZIndex = 3,
	}, body)
	self._cap = new("TextLabel", {
		Name = "Caption",
		BackgroundTransparency = 1,
		Text = "SHOP",
		FontFace = FONT_H,
		TextColor3 = INK,
		AnchorPoint = Vector2.new(0.5, 1),
		ZIndex = 4,
	}, body)
	-- the shine: a bright band in a gradient's transparency, moved across by its offset
	local shine = new("Frame", {
		Name = "Shine",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 5,
	}, body)
	self._shine_corner = new("UICorner", {}, shine)
	self._shine = new("UIGradient", {
		Rotation = 24,
		Offset = Vector2.new(-1, 0),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.4, 1),
			NumberSequenceKeypoint.new(0.5, 0.45),
			NumberSequenceKeypoint.new(0.6, 1),
			NumberSequenceKeypoint.new(1, 1),
		}),
	}, shine)
	-- the count of what there is to get, top right
	local badge = new("TextLabel", {
		Name = "Badge",
		BackgroundColor3 = RED,
		Text = "",
		FontFace = FONT_H,
		TextColor3 = Color3.new(1, 1, 1),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Visible = false,
		ZIndex = 7,
	}, body)
	new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, badge)
	new(
		"UIStroke",
		{ Color = Color3.fromRGB(90, 10, 10), Thickness = 1.5, ApplyStrokeMode = Enum.ApplyStrokeMode.Border },
		badge
	)
	self._badge = badge
	local hit = new("TextButton", {
		Name = "Hit",
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 10,
	}, root)
	hit.MouseEnter:Connect(function()
		self._hover = true
		tween(self._scale, 0.12, { Scale = 1.06 })
		if not self.ctx.touch then
			self.ctx:sfx("hover", -12.0)
		end
	end)
	hit.MouseLeave:Connect(function()
		self._hover = false
		tween(self._scale, 0.12, { Scale = 1 })
	end)
	hit.MouseButton1Down:Connect(function()
		tween(self._scale, 0.08, { Scale = 0.93 })
	end)
	hit.MouseButton1Up:Connect(function()
		tween(self._scale, 0.12, { Scale = if self._hover then 1.06 else 1 })
	end)
	hit.Activated:Connect(function()
		self._seen = true
		self._badge.Visible = false
		self.wanted:Fire(self:_current_key(), "match")
	end)
end

--- The slot's size in the row (logical px).
function ShopSlot.set_block(self, w: number, h: number)
	self:set_min_size(Vector2.new(w, h))
	self:_place()
end

--- The Arsenal items the player has yet to get, in shop order.
function ShopSlot.locked(self): { any }
	local out = {}
	local s = self.ctx.session
	local has = s ~= nil and type(s.has_unlock) == "function"
	for _, it in Catalog.ITEMS do
		if not (has and s:has_unlock(it.key)) then
			table.insert(out, it)
		end
	end
	return out
end

--- Sizes the parts (raw instances: px, logical x UITheme.scale).
function ShopSlot._place(self)
	local size = if self.size.X > 0 and self.size.Y > 0 then self.size else self.custom_minimum_size
	local u = UITheme.scale
	local w, h = size.X * u, size.Y * u
	local r = UDim.new(0, UITheme.R_MD * u)
	self._corner.CornerRadius = r
	self._shine_corner.CornerRadius = r
	local cap_h = ShopSlot.CAPTION_H * u
	self._cap.TextSize = math.floor(12 * u)
	self._cap.Position = UDim2.new(0.5, 0, 1, -3 * u)
	self._cap.Size = UDim2.new(1, 0, 0, cap_h)
	local art_h = math.max(8, h - cap_h - 5 * u)
	self._art_cy = 3 * u + art_h / 2
	for _, p in self._pics do
		p.Size = UDim2.fromOffset(w - 10 * u, art_h)
		p.Position = UDim2.fromOffset(w / 2, self._art_cy)
	end
	self._shield.Size = UDim2.fromOffset(art_h * 0.8, art_h * 0.8)
	self._shield.Position = UDim2.fromOffset(w / 2, self._art_cy)
	local bd = math.floor(16 * u)
	self._badge.Size = UDim2.fromOffset(bd, bd)
	self._badge.TextSize = math.floor(11 * u)
	self._badge.Position = UDim2.new(1, -3 * u, 0, 3 * u)
	self._art_w, self._art_h = w - 10 * u, art_h
end

function ShopSlot._on_resized(self)
	self:_place()
end

--- The item the button shows now (nil: it shows the shield).
function ShopSlot._current_key(self): string?
	local n = #self._items
	if n == 0 then
		return nil
	end
	local i = math.floor(self._t / ShopSlot.CYCLE_S) % n + 1
	return self._items[i].key
end

--- Follows what the player has yet to get (true when that changed: the slot may want another
--- width).
function ShopSlot.refresh(self): boolean
	local items = self:locked()
	local keys = {}
	for i, it in items do
		keys[i] = it.key
	end
	local sig = table.concat(keys, ",")
	local changed = sig ~= self._sig
	if changed then
		self._sig = sig
		-- (only items with a picture cycle; every item has one)
		local shown = {}
		for _, it in items do
			if type(Art.renders) == "table" and Art.renders[it.key] ~= nil then
				table.insert(shown, it)
			end
		end
		self._items = shown
		self._shield.Visible = #shown == 0
		self._badge.Text = tostring(#items)
		self._badge.Visible = #items > 0 and not self._seen
		for _, p in self._pics do
			p.Visible = #shown > 0
		end
	end
	return changed
end

function ShopSlot._process(self, dt: number)
	if not self:is_visible_in_tree() then
		return
	end
	self._t += dt
	local t = self._t
	-- the pictures: the current one fades and pops in over the one before
	local n = #self._items
	if n > 0 then
		local i = math.floor(t / ShopSlot.CYCLE_S)
		local cur = self._pics[i % 2 + 1]
		local prev = self._pics[(i + 1) % 2 + 1]
		local want = Art.renders[self._items[i % n + 1].key].id
		if cur.Image ~= want then
			cur.Image = want
		end
		local before = Art.renders[self._items[(i - 1) % n + 1].key].id
		if prev.Image ~= before then
			prev.Image = before
		end
		local k = math.clamp((t % ShopSlot.CYCLE_S) / ShopSlot.FADE_S, 0, 1)
		cur.ImageTransparency = 1 - k
		prev.ImageTransparency = if n > 1 then k else 1
		local bob = math.sin(t * 2.2) * (self._art_h or 30) * 0.03
		local pop = 0.82 + 0.18 * (1 - (1 - k) ^ 3)
		local aw, ah = self._art_w or 50, self._art_h or 30
		cur.Size = UDim2.fromOffset(aw * pop, ah * pop)
		cur.Position = UDim2.fromOffset(cur.Position.X.Offset, (self._art_cy or 20) + bob)
		prev.Size = UDim2.fromOffset(aw, ah)
		prev.Position = UDim2.fromOffset(prev.Position.X.Offset, (self._art_cy or 20) + bob)
		cur.Rotation = math.sin(t * 1.4) * 3
		prev.Rotation = cur.Rotation
	end
	-- the shine, now and then
	local sk = (t % ShopSlot.SHINE_S) / 0.75
	self._shine.Offset = Vector2.new(if sk < 1 then -1 + 2 * sk else -1, 0)
	-- and the shake, until the Arsenal has been opened from here
	local rot = 0
	if not self._seen then
		local wk = (t % ShopSlot.WIGGLE_S) / 0.55
		if wk < 1 then
			rot = math.sin(wk * math.pi * 4) * 7 * (1 - wk)
		end
	end
	self._body.Rotation = rot
end

return ShopSlot
