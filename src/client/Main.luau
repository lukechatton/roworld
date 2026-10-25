--!strict
-- Port of scripts/main.gd: the client root. Creates the AudioDirector, the globe (WorldView) and the
-- interface (UIRoot), wires them to the Session, and owns the top-bar buttons that the original put in
-- Airship's HUD bar: Music toggle (also key M), Help, Leaderboard, Home → focus your nation (also key
-- Home) and the Game menu. The buttons sit in Roblox's own top-bar row, right of Roblox's menu / chat
-- buttons (GuiService.TopbarInset), styled like them. Match-only buttons hide on the title screen.
--
-- UIRoot must NOT bind M / Home or call world:bind_state itself (DESIGN.md §10).
-- Missing modules (during development) are skipped so boot never errors.

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Session = require(script.Parent.Session) :: any
local AudioDirector = require(script.Parent.Audio.AudioDirector) :: any

local Main = {}
Main.session = nil :: any
Main.world = nil :: any
Main.ui = nil :: any
Main.audio = nil :: any
--- Boot timeline (os.clock seconds; diagnostics): start, session (title world requested), ui (UIRoot
--- built), first_state (first world live).
Main.boot = {} :: { [string]: number }

-- Top-bar geometry and look, measured from Roblox's own TopBarApp (menu button / unibar): 44 px
-- circles filled RGB(18,18,21) at 0.08 transparency, 36 px icon frames, 8 px apart, top edge 12 px
-- below the screen top (TopbarInset height 58), white state overlay on hover / press.
local BUTTON = 44
local GAP = 8
local ICON = 36 -- the hud_* masks keep Airship's 0.7 inset framing (glyph ≈ 25 px)
local FILL = Color3.fromRGB(18, 18, 21)
local FILL_T = 0.08
local OVERLAY_T = 1.0
local OVERLAY_HOVER_T = 0.92
local OVERLAY_PRESS_T = 0.84

local function optional(parent: Instance?, path: { string }): any
	local node: Instance? = parent
	for _, name in path do
		if node == nil then
			return nil
		end
		node = (node :: Instance):FindFirstChild(name)
	end
	if node == nil or not node:IsA("ModuleScript") then
		return nil
	end
	local ok, mod = pcall(require, node)
	if not ok then
		warn("[RoWorld] could not load " .. node:GetFullName() .. ": " .. tostring(mod))
		return nil
	end
	return mod
end

local call_warned: { [string]: boolean } = {}

--- Calls obj:method(...) if it exists. A failing view / UI call is reported once per method and never
--- breaks the wiring (Godot logs a script error in a signal handler and carries on).
local function call(obj: any, method: string, ...: any): any
	if obj == nil then
		return nil
	end
	local f = obj[method]
	if type(f) ~= "function" then
		return nil
	end
	local ok, res = xpcall(f, debug.traceback, obj, ...)
	if not ok then
		if not call_warned[method] then
			call_warned[method] = true
			warn("[RoWorld] " .. method .. " failed: " .. tostring(res))
		end
		return nil
	end
	return res
end

--- Roblox's CoreGui toggles can fail until the CoreScripts are ready: retry briefly.
local function hide_core_guis()
	task.spawn(function()
		for _ = 1, 50 do
			local ok = pcall(function()
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.EmotesMenu, false)
			end)
			if ok then
				pcall(function()
					StarterGui:SetCore("ResetButtonCallback", false)
				end)
				return
			end
			task.wait(0.2)
		end
	end)
end

-- =============================================================================================
-- Top bar
-- =============================================================================================

type Hud = { gui: ScreenGui, bar: Frame, buttons: { [string]: any }, tip: TextLabel }

local hud: Hud? = nil

local function icon_id(name: string): string?
	local icons = optional(ReplicatedStorage:FindFirstChild("Airfront"), { "Assets", "UiIcons" })
	if type(icons) ~= "table" then
		return nil
	end
	local id = icons["hud_" .. name]
	return if type(id) == "string" then id else nil
end

local FALLBACK_GLYPH =
	{ music_on = "♪", music_off = "♪", help = "?", leaderboard = "≡", globe = "⌂", exit = "⏻", settings = "⚙" }

local function show_tip(h: Hud, button: GuiObject?, text: string?)
	local tip = h.tip
	if button == nil or text == nil or UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
		tip.Visible = false
		return
	end
	tip.Text = text
	-- AbsolutePosition is relative to the area below the top-bar inset even in this IgnoreGuiInset
	-- ScreenGui (a button at screen y = 12 reports -46); the tip is positioned in screen space.
	local pos = button.AbsolutePosition + GuiService:GetGuiInset()
	local size = button.AbsoluteSize
	tip.Position = UDim2.fromOffset(pos.X + size.X / 2, pos.Y + size.Y + 8)
	tip.Visible = true
end

local function make_button(h: Hud, key: string, icon: string, tooltip: string, order: number, on_press: () -> ()): any
	local b = Instance.new("ImageButton")
	b.Name = key
	b.LayoutOrder = order
	b.Size = UDim2.fromOffset(BUTTON, BUTTON)
	b.AutoButtonColor = false
	b.BackgroundColor3 = FILL
	b.BackgroundTransparency = FILL_T
	b.BorderSizePixel = 0
	b.Image = ""
	b.Selectable = true
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = b
	local overlay = Instance.new("Frame")
	overlay.Name = "StateOverlay"
	overlay.BackgroundColor3 = Color3.new(1, 1, 1)
	overlay.BackgroundTransparency = OVERLAY_T
	overlay.BorderSizePixel = 0
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.ZIndex = 2
	local oc = Instance.new("UICorner")
	oc.CornerRadius = UDim.new(1, 0)
	oc.Parent = overlay
	overlay.Parent = b
	local img = Instance.new("ImageLabel")
	img.Name = "Icon"
	img.BackgroundTransparency = 1
	img.AnchorPoint = Vector2.new(0.5, 0.5)
	img.Position = UDim2.fromScale(0.5, 0.5)
	img.Size = UDim2.fromOffset(ICON, ICON)
	img.ScaleType = Enum.ScaleType.Fit
	img.ImageColor3 = Color3.new(1, 1, 1)
	img.ZIndex = 3
	img.Parent = b
	local glyph = Instance.new("TextLabel")
	glyph.Name = "Glyph"
	glyph.BackgroundTransparency = 1
	glyph.Size = UDim2.fromScale(1, 1)
	glyph.FontFace = Font.fromId(12187365977, Enum.FontWeight.Bold)
	glyph.TextSize = 20
	glyph.TextColor3 = Color3.new(1, 1, 1)
	glyph.Visible = false
	glyph.ZIndex = 3
	glyph.Parent = b
	local entry = { button = b, icon = img, glyph = glyph, tooltip = tooltip }
	local function set_icon(name: string)
		local id = icon_id(name)
		if id then
			img.Image = id
			img.Visible = true
			glyph.Visible = false
		else
			img.Visible = false
			glyph.Text = FALLBACK_GLYPH[name] or "•"
			glyph.Visible = true
		end
		-- music off: the fallback glyph is dimmed (the real icon has its own slash)
		glyph.TextTransparency = if name == "music_off" then 0.55 else 0
	end
	entry.set_icon = set_icon
	set_icon(icon)
	local function tween(t: number)
		TweenService:Create(
			overlay,
			TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = t }
		):Play()
	end
	b.MouseEnter:Connect(function()
		tween(OVERLAY_HOVER_T)
		show_tip(h, b, entry.tooltip)
	end)
	b.MouseLeave:Connect(function()
		tween(OVERLAY_T)
		show_tip(h, nil, nil)
	end)
	b.MouseButton1Down:Connect(function()
		tween(OVERLAY_PRESS_T)
	end)
	b.MouseButton1Up:Connect(function()
		tween(OVERLAY_HOVER_T)
	end)
	b.Activated:Connect(function()
		show_tip(h, nil, nil)
		on_press()
	end)
	b.Parent = h.bar
	h.buttons[key] = entry
	return entry
end

local function layout_hud()
	local h = hud
	if h == nil then
		return
	end
	local inset = GuiService.TopbarInset
	local height = inset.Height
	if height <= 0 then
		height = 58
	end
	-- The inset rect starts right of Roblox's menu / chat buttons; our row continues their spacing.
	local left = (if inset.Width > 0 then inset.Min.X else 164) + GAP
	h.bar.Position = UDim2.fromOffset(left, inset.Min.Y + math.max(0, height - BUTTON - 2))
	h.bar.Size = UDim2.fromOffset(math.max(inset.Width - GAP, BUTTON), BUTTON)
end

--- Viewport-px rect of the visible top-bar buttons (UIRoot keeps HUD panels clear of the row).
local function topbar_rect(): Rect?
	local h = hud
	if h == nil then
		return nil
	end
	local inset = GuiService:GetGuiInset()
	local min_x, min_y, max_x, max_y = math.huge, math.huge, -math.huge, -math.huge
	for _, e in h.buttons do
		local b = e.button
		if b.Visible then
			local p = b.AbsolutePosition + inset -- AbsolutePosition is relative to the inset area
			local sz = b.AbsoluteSize
			min_x = math.min(min_x, p.X)
			min_y = math.min(min_y, p.Y)
			max_x = math.max(max_x, p.X + sz.X)
			max_y = math.max(max_y, p.Y + sz.Y)
		end
	end
	if min_x == math.huge then
		return nil
	end
	return Rect.new(min_x, min_y, max_x, max_y)
end

local function focus_home()
	local session = Main.session
	local state = session and session.state
	if state ~= nil and state.local_owner ~= 0 then
		call(Main.world, "focus_owner", state.local_owner)
	end
end

local function toggle_music()
	local audio = Main.audio
	if audio == nil then
		return
	end
	audio:set_music_enabled(not audio:is_music_enabled())
end

local function current_screen(): string
	local s = call(Main.ui, "screen")
	return if type(s) == "string" then s else "title"
end

local function refresh_hud()
	local h = hud
	if h == nil then
		return
	end
	-- Match-only controls: the title screen has no leaderboard, nation or game menu yet.
	local in_match = Main.ui ~= nil and current_screen() ~= "title"
	-- Phones: no music button in the row (Settings has the switch). With the gear the row is six
	-- buttons, and beside Roblox's own (three with voice chat) that leaves an 852 px phone no room
	-- for the status pill, which then drops under the row.
	local music = h.buttons["music"]
	local ctx = Main.ui and Main.ui.ctx
	if music then
		-- (the phone layout, as the status pill knows it: UIRoot's ctx.compact)
		music.button.Visible = not (type(ctx) == "table" and ctx.compact == true)
	end
	for _, key in { "leaderboard", "home", "menu" } do
		local e = h.buttons[key]
		if e then
			e.button.Visible = in_match
		end
	end
	-- a crate opening fills the screen: the row steps aside meanwhile
	local co = Main.ui and Main.ui.crate_opening
	h.bar.Visible = not (co ~= nil and co.is_open)
end

local function build_hud(player: Player)
	local gui = Instance.new("ScreenGui")
	gui.Name = "AirfrontTopbar"
	gui.IgnoreGuiInset = true
	-- The safe area's coordinates, which are GuiService.TopbarInset's. This was ScreenInsets.None
	-- (full-screen coordinates) in the belief that TopbarInset is full-screen too. It is not: on an
	-- iPhone 17 Pro (Studio's emulation: a 62 px inset beside the notch) it reads min (164, 0), max
	-- (749, 58) on a 749 px wide safe area, 873 px of screen. So on a notched phone the row sat the
	-- inset's width too far left, its first button under Roblox's own (2026-10-07, a phone's
	-- screenshot: Roblox's top bar covered our music toggle).
	gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 50
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.BackgroundTransparency = 1
	bar.Parent = gui
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, GAP)
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.Parent = bar
	local tip = Instance.new("TextLabel")
	tip.Name = "Tooltip"
	tip.AnchorPoint = Vector2.new(0.5, 0)
	tip.AutomaticSize = Enum.AutomaticSize.XY
	tip.BackgroundColor3 = FILL
	tip.BackgroundTransparency = 0.1
	tip.TextColor3 = Color3.new(1, 1, 1)
	tip.FontFace = Font.fromId(12187365977, Enum.FontWeight.Medium)
	tip.TextSize = 14
	tip.Visible = false
	tip.ZIndex = 5
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.Parent = tip
	local tc = Instance.new("UICorner")
	tc.CornerRadius = UDim.new(0, 8)
	tc.Parent = tip
	tip.Parent = gui
	local h: Hud = { gui = gui, bar = bar, buttons = {}, tip = tip }
	hud = h

	local audio = Main.audio
	local music = make_button(
		h,
		"music",
		if audio:is_music_enabled() then "music_on" else "music_off",
		"Music (M)",
		1,
		toggle_music
	)
	-- The game menu can also toggle music; keep the icon in sync.
	audio.music_enabled_changed:Connect(function(on: boolean)
		music.set_icon(if on then "music_on" else "music_off")
	end)
	-- (2026-10-25: "Help & Credits", the window ends with the credits, licence and source)
	make_button(h, "help", "help", "Help & Credits (H)", 2, function()
		call(Main.ui, "toggle_help")
	end)
	make_button(h, "leaderboard", "leaderboard", "Leaderboard (Tab)", 3, function()
		call(Main.ui, "toggle_leaderboard")
	end)
	make_button(h, "home", "globe", "Center on your nation (Home)", 4, focus_home)
	-- settings (2026-10-07): music, the border pops, labels; on the title too
	make_button(h, "settings", "settings", "Settings", 5, function()
		call(Main.ui, "open_settings")
	end)
	make_button(h, "menu", "exit", "Game menu", 6, function()
		call(Main.ui, "open_pause_menu")
	end)
	GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(layout_hud)
	-- (a resized window may change layouts: the row follows once the UI has laid itself out)
	local cam = workspace.CurrentCamera
	if cam ~= nil then
		cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			task.delay(0.25, refresh_hud)
		end)
	end
	task.delay(1.5, refresh_hud)
	layout_hud()
	refresh_hud()
	gui.Parent = player:WaitForChild("PlayerGui")
end

-- =============================================================================================
-- Boot
-- =============================================================================================

local function on_screen_changed(screen: string)
	call(Main.world, "set_attract_mode", screen == "title")
	refresh_hud()
end

local function on_state_ready(state: any)
	call(Main.world, "bind_state", state)
	-- UIRoot picks its new screen a frame later (screen_changed then updates the globe / top bar);
	-- before the UI exists this keeps the title look.
	on_screen_changed(current_screen())
end

local function bind_keys()
	local function handler(
		_name: string,
		input_state: Enum.UserInputState,
		input: InputObject
	): Enum.ContextActionResult
		if input_state ~= Enum.UserInputState.Begin or GuiService.MenuIsOpen then
			return Enum.ContextActionResult.Pass
		end
		if UserInputService:GetFocusedTextBox() ~= nil then
			return Enum.ContextActionResult.Pass
		end
		if input.KeyCode == Enum.KeyCode.M then
			toggle_music()
		elseif input.KeyCode == Enum.KeyCode.Home then
			focus_home()
		end
		return Enum.ContextActionResult.Sink
	end
	ContextActionService:BindAction("AirfrontMainKeys", handler, false, Enum.KeyCode.M, Enum.KeyCode.Home)
end

--- In multiplayer the server drops participants who look idle between matches; any real input
--- (clicks, keys, touches, camera drags) counts as presence. Session throttles the reports.
local function watch_activity()
	local function note(input: InputObject)
		local t = input.UserInputType
		if
			t == Enum.UserInputType.MouseButton1
			or t == Enum.UserInputType.MouseButton2
			or t == Enum.UserInputType.MouseMovement
			or t == Enum.UserInputType.MouseWheel
			or t == Enum.UserInputType.Touch
			or t == Enum.UserInputType.Keyboard
			or t == Enum.UserInputType.Gamepad1
		then
			local session = Main.session
			if session ~= nil then
				session:note_activity()
			end
		end
	end
	UserInputService.InputBegan:Connect(note)
	UserInputService.InputChanged:Connect(note)
end

function Main.start()
	Main.boot.start = os.clock()
	local player = Players.LocalPlayer
	hide_core_guis()
	-- The globe is always played in landscape (either way up); main.gd reasserted this on mobile too.
	task.spawn(function()
		local pg = player:WaitForChild("PlayerGui") :: PlayerGui
		pcall(function()
			pg.ScreenOrientation = Enum.ScreenOrientation.LandscapeSensor
		end)
	end)
	local session = Session.new()
	Main.session = session
	Main.boot.session_new = os.clock()
	local audio = AudioDirector.new("menu")
	audio:bind_settings(session)
	Main.audio = audio
	Main.boot.audio = os.clock()

	local client = script.Parent
	-- the 2D map (Map/MapView); View/WorldView was the 3D globe (tag globe-v7)
	local WorldView = optional(client, { "Map", "MapView" })
	if WorldView ~= nil and type(WorldView.new) == "function" then
		local ok, w = pcall(WorldView.new)
		if ok then
			Main.world = w
		else
			warn("[RoWorld] WorldView.new failed: " .. tostring(w))
		end
	end
	Main.boot.world = os.clock()
	-- The title world, the globe and the top bar come up first: UIRoot.new may wait (bounded) for the
	-- Rubik weights on a cold client, and the attract globe must already be alive behind it.
	session.state_ready:Connect(on_state_ready)
	session.state_ready:Once(function()
		Main.boot.first_state = os.clock()
	end)
	build_hud(player)
	bind_keys()
	watch_activity()
	Main.boot.hud = os.clock()
	session:bind()
	session:start_title()
	Main.boot.session = os.clock()
	local UIRoot = optional(client, { "UI", "UIRoot" })
	if UIRoot ~= nil and type(UIRoot.new) == "function" then
		local ok, u = pcall(UIRoot.new)
		if ok then
			Main.ui = u
			local ok2, err = pcall(function()
				u:setup(session, Main.world, audio)
			end)
			if not ok2 then
				warn("[RoWorld] UIRoot:setup failed: " .. tostring(err))
			end
		else
			warn("[RoWorld] UIRoot.new failed: " .. tostring(u))
		end
	end
	local ui = Main.ui
	if ui ~= nil and ui.screen_changed ~= nil then
		ui.screen_changed:Connect(on_screen_changed)
	end
	-- sent here from an outdated server while starting a solo match (server/FreshServers): it starts here
	pcall(function()
		local data = game:GetService("TeleportService"):GetLocalPlayerTeleportData()
		if
			type(data) == "table"
			and type(data.solo) == "table"
			and ui ~= nil
			and type(ui.autostart_solo) == "function"
		then
			ui:autostart_solo(tonumber(data.solo.d) or 0, if type(data.solo.m) == "string" then data.solo.m else nil)
		end
	end)
	if ui ~= nil and ui.crate_opening ~= nil and ui.crate_opening.shown ~= nil then
		ui.crate_opening.shown:Connect(refresh_hud)
	end
	if ui ~= nil then
		ui.topbar_provider = topbar_rect
	end
	on_screen_changed(current_screen())
	Main.boot.ui = os.clock()
	Main.launch_hooks(player)
	-- Dev diagnostics (workspace attribute AF_DIAG; never set in the shipped place).
	if workspace:GetAttribute("AF_DIAG") == true then
		local diag = optional(client, { "Dev", "SessionDiag" })
		if diag then
			diag.start(Main)
		end
	end
end

-- Owner-only real-client test hook: joining with launchData "autosolo[:lat,lon]" (e.g.
-- roblox://experiences/start?placeId=137151641329864&launchData=autosolo:48,10) starts a Standard solo
-- match and picks the unclaimed land nearest to lat/lon, so the published game can be verified on a
-- real Roblox client without clicking through the title. Ignored for everyone else.
Main.OWNER_USER_ID = 22641473
function Main.launch_hooks(player: Player)
	task.spawn(function()
		local ld = player:GetAttribute("AF_LaunchData")
		local t0 = os.clock()
		while ld == nil and os.clock() - t0 < 6 do
			task.wait(0.25)
			ld = player:GetAttribute("AF_LaunchData")
		end
		if type(ld) ~= "string" or string.sub(ld, 1, 8) ~= "autosolo" then
			return
		end
		if player.UserId ~= Main.OWNER_USER_ID and not game:GetService("RunService"):IsStudio() then
			return
		end
		local lat, lon = 30.0, 100.0
		local a, b = string.match(ld, "^autosolo:(%-?[%d%.]+),(%-?[%d%.]+)$")
		if a and b then
			lat, lon = tonumber(a) or lat, tonumber(b) or lon
		end
		local session = Main.session
		-- wait for the title world, then start solo through the UI's own path
		while session.state == nil or session:is_building() do
			task.wait(0.2)
		end
		task.wait(1.0)
		if Main.ui ~= nil and type(Main.ui._on_play_solo) == "function" then
			pcall(Main.ui._on_play_solo, Main.ui, 1)
		else
			session:start_solo(1)
		end
		-- spawn phase of the new solo world: pick the nearest unclaimed contestable land
		local deadline = os.clock() + 30
		while os.clock() < deadline do
			task.wait(0.2)
			local st = session.state
			if st ~= nil and st.map ~= nil and st.local_owner ~= 0 and not session:is_building() then
				local map = st.map
				local c = map:latlon_to_tile(lat, lon)
				local cx, cy = c % 1024, c // 1024
				local best = nil
				for r = 0, 60 do
					for dy = -r, r do
						for dx = -r, r do
							if math.max(math.abs(dx), math.abs(dy)) == r then
								local y = cy + dy
								if y >= 0 and y < 512 then
									local t = y * 1024 + (cx + dx) % 1024
									if map:is_contestable(t) and st:owner_of(t) == 0 then
										best = t
										break
									end
								end
							end
						end
						if best then
							break
						end
					end
					if best then
						break
					end
				end
				if best ~= nil then
					session:send_intent({ type = "spawn", tile = best })
					call(Main.world, "focus_tile", best, -1.0, 1.0)
					print("[RoWorld] autosolo: spawn requested at tile", best)
				end
				return
			end
		end
	end)
end

return Main
