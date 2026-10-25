--!nonstrict
-- Port of scripts/ui/ui_root.gd (UIRoot)
-- AIRFRONT interface root. Built entirely in code: title screen, spawn banner, HUD (command bar,
-- world-control status, leaderboard, event feed, nuke alert), tooltips, radial menu, help, game
-- menu and the victory / defeat screen. Wire with setup(session, world, audio) (DESIGN.md §10).
--
-- Roblox: one ScreenGui "AirfrontUI" (DisplayOrder 10, above the map-label layer at 0; below
-- Main's top bar at 50) holding a Widgets.Root (the kit's Godot-like node tree, logical px with
-- one UI scale). One render-step loop (after the camera) runs every per-frame update, then the
-- kit's tweens / layout (Widgets.step). Main owns M / Home and the top-bar buttons.

local UITheme = require("./UITheme")
local W = require("./Widgets")
local GlassPanel = require("./GlassPanel")
local UICtx = require("./UICtx")
local UIInteract = require("./UIInteract")
local Telemetry = require("./Telemetry")
local MusicMood = require("../Audio/MusicMood")
local UIAdvisor = require("./UIAdvisor")
local UILayoutProbe = require("./UILayoutProbe")
local TouchRouter = require("./TouchRouter")
local TitleScreen = require("./TitleScreen")
local SpawnOverlay = require("./SpawnOverlay")
local GameOver = require("./GameOver")
local Takeover = require("./Takeover")
local Locker = require("./Locker")
local Arsenal = require("./Arsenal")
local StarterOffer = require("./StarterOffer")
local FlagShop = require("./FlagShop")
local ArsenalData: any = if typeof(game) == "Instance"
	then require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Airfront").Data.Arsenal)
	else (require :: any)("../../shared/Data/Arsenal")
local CrateOpening = require("./CrateOpening")
local HelpOverlay = require("./HelpOverlay")
local PauseMenu = require("./PauseMenu")
local MapPicker = require("./MapPicker")
local UIMaps = require("./UIMaps")
local RotateCard = require("./RotateCard")
local Tooltip = require("./Tooltip")
local RadialMenu = require("./RadialMenu")
local HoldRing = require("./HoldRing")
local Tutorial = require("./Tutorial")
local TutorialData = UICtx.data("Tutorial")
local StarterData = UICtx.data("Starter")
local TargetCard = require("./TargetCard")
local UnitCard = require("./UnitCard")
local PlaceConfirm = require("./PlaceConfirm")
local Coach = require("./Coach")
local Signal = UITheme.core("Signal")
local Defs = UICtx.core("Defs")

local UIRoot = {}
UIRoot.__index = UIRoot

--- Kit components by name (tests may override entries before UIRoot.new).
UIRoot.kit = {}
--- UIRoot.new waits at most this long for the Rubik weights before building (see _make_gui).
UIRoot.FONT_WAIT_S = 2.5
local function kit(name: string): any
	local k = UIRoot.kit[name]
	if k ~= nil then
		return k
	end
	-- (kept once required: _hook_buttons asks again on every slow poll, and a require late in a
	-- session can fail, UICtx.prime)
	return UICtx.mod(name)
end

function UIRoot.new(opts: any?)
	local self = setmetatable({}, UIRoot)
	opts = opts or {}
	--- Emitted when the UI changes a setting that Main mirrors on a top-bar button.
	self.music_toggled = Signal.new()
	self.labels_toggled = Signal.new()
	self.leaderboard_toggled = Signal.new()
	self.help_toggled = Signal.new()
	--- "title", "spawn", "play" or "over".
	self.screen_changed = Signal.new()
	--- Test hooks: safe-area insets override (x < 0 = use the platform) and forced touch mode.
	self.debug_insets = opts.debug_insets or { x = -1, y = -1, z = -1, w = -1 }
	self.debug_touch = opts.debug_touch or -1
	--- Main may set this: function() -> Rect (viewport px) of its top-bar buttons.
	self.topbar_provider = nil
	self.ctx = UICtx.new()
	--- the soundtrack's mood (title / wait / calm / war / victory / defeat)
	self._music = MusicMood.new()
	--- Creator Dashboard milestones (server/Analytics)
	self.telemetry = Telemetry.new(self.ctx)
	self.ctx.telemetry = self.telemetry
	self.labels_on = true
	self._screen = ""
	self._conns = {}
	self._sconns = {}
	self._apply_pending = false
	self._poll = 0.0
	self._last_vp = Vector2.zero
	self._last_insets = { x = 0, y = 0, z = 0, w = 0 }
	self._stats = {}
	self._elim_timer = nil
	self._reserved_probe = Rect.new(0, 0, 0, 0)
	self._chat_probe = Rect.new(0, 0, 0, 0)
	self._world_safe = Rect.new(-1, -1, -1, -1)
	--- Transient nodes registered with add_hud_control (banners).
	self._extra_hud = {}
	self._relayout_pending = false
	self._building = false
	--- A solo restart ("Play again" / "Restart match") is building: the old match stays frozen.
	self._restart_pending = false
	self._solo_msec = -100000
	self._threat_poll = 0.0
	self._hook_poll = 0.0
	self._theme = ""
	local ctx = self.ctx
	local UIS = if UICtx.IS_ROBLOX then game:GetService("UserInputService") else nil
	ctx.touch_device = UIS ~= nil and UIS.TouchEnabled and not UIS.MouseEnabled
	if opts.touch_device ~= nil then
		ctx.touch_device = opts.touch_device
	end
	ctx.touch = ctx.touch_device
	self.labels_on = ctx:setting("labels", true) ~= false
	self:_make_gui(opts.parent)
	self:_build()
	self:_layout()
	self:_apply_screen()
	return self
end

-- =============================================================================================
-- Public API (DESIGN.md §10)
-- =============================================================================================

function UIRoot.setup(self, session: any, world: any, audio: any)
	local ctx = self.ctx
	ctx.session = session
	ctx.world = world
	ctx:world_call("set_borders", { ctx.borders })
	ctx.audio = audio
	-- every button clicks when pressed and ticks under the pointer (the interface kit, Assets/AudioUI)
	W.button_sound = function(kind: string, _button: any)
		if kind == "hover" then
			if not ctx.touch then
				ctx:sfx("hover", -12.0, 0.03)
			end
		elseif kind == "tab" then
			ctx:sfx("tab", -3.0, 0.02)
		else
			ctx:sfx("click", -1.0, 0.03)
		end
	end
	if session ~= nil then
		ctx:reload_settings()
		self.labels_on = ctx:setting("labels", true) ~= false
		self:_sig(session, "state_ready", function(s)
			self:_on_state_ready(s)
		end)
		self:_sig(session, "mode_changed", function(_m)
			self:_request_apply()
		end)
		if self.locker ~= nil then
			self.locker:bind(session)
		end
		if self.arsenal ~= nil then
			self.arsenal:bind(session)
		end
		if self.title ~= nil and self.title._arsenal_btn ~= nil then
			self.title._arsenal_btn:bind(session)
		end
		if self.starter ~= nil then
			self.starter:bind(session)
		end
		if self.title ~= nil and self.title._starter_btn ~= nil then
			self.title._starter_btn:bind(session)
		end
		if self.flag_shop ~= nil then
			self.flag_shop:bind(session)
		end
		-- an Arsenal unlock: the build slots open up; outside the Arsenal a toast says so
		self:_sig(session, "unlocked", function(key: string)
			self.bar:refresh_buttons()
			-- (the starter pack just bought says so once for its three items)
			local pack = self.starter ~= nil and self.starter.bought_at ~= nil and os.clock() - self.starter.bought_at < 5
			if self.arsenal ~= nil and not self.arsenal.is_open and not pack then
				local it = ArsenalData.item(key)
				ctx:sfx("unlock")
				self:_on_notice((if it ~= nil then it.title else "Arsenal item") .. " unlocked!", 0)
			end
		end)
		self:_sig(session, "inventory_changed", function()
			self.bar:refresh_buttons()
			-- (the result screen's offers: what was just unlocked is no longer one)
			if self.over ~= nil then
				self.over:refresh_offers()
			end
		end)
		self:_sig(session, "hop_result", function(going: boolean)
			self:_on_hop_result(going)
		end)
		-- a match's Stars: the result screen counts them up
		self:_sig(session, "stars_awarded", function(award: any)
			if self.over ~= nil and self.over.is_open then
				self.over:set_award(award)
			end
		end)
		if self.title ~= nil and self.title._crate_btn ~= nil then
			self.title._crate_btn:bind(session)
		end
		self:_sig(session, "credits_changed", function(_c)
			if self.takeover ~= nil then
				self.takeover:on_credits()
			end
		end)
		self:_sig(session, "credit_result", function(kind, ok, reason)
			if self.takeover ~= nil then
				self.takeover:on_result(kind, ok, reason)
			end
		end)
		self:_sig(session, "took_over", function(id)
			self:_on_took_over(id)
		end)
		self:_sig(session, "lobby_updated", function(info)
			self.title:set_lobby(info)
		end)
		-- public lobbies (hub servers): the game-wide list and join outcomes
		self:_sig(session, "admin_changed", function()
			self.board:mark_dirty()
			self.title:_refresh_greeting()
			ctx:world_call("set_admin_bots", { session.admin_bots })
		end)
		self:_sig(session, "lobbies_updated", function(list)
			self.title:set_lobbies(list, session.lobby_kinds)
		end)
		-- Quick Play: asking, in line, on the way (PUBLIC_STATE)
		self:_sig(session, "public_changed", function(st)
			self.title:set_public(st)
		end)
		-- parties (team games on: staging only for now)
		self:_sig(session, "party_changed", function(st)
			self.title:set_party(st)
		end)
		self:_sig(session, "join_failed", function(_reason)
			self.title:join_failed()
		end)
		self:_sig(session, "joined_owner", function(id)
			self:_on_joined_owner(id)
		end)
		self:_sig(session, "notice", function(text, severity)
			self:_on_notice(text, severity)
		end)
		self:_sig(session, "building_started", function(mode)
			self:_on_building(mode)
		end)
		self:_sig(session, "settings_loaded", function()
			self:_on_settings_loaded()
		end)
		if session.settings_ready == true then
			-- They arrived while the UI was still being built (Main starts the Session first).
			self:_on_settings_loaded()
		end
		if session.state ~= nil then
			self:_bind_state(session.state)
		end
		if type(session.lobby) == "table" then
			self.title:set_lobby(session.lobby)
		end
		if type(session.lobbies) == "table" then
			self.title:set_lobbies(session.lobbies, session.lobby_kinds)
		end
		if type(session.public) == "table" then
			self.title:set_public(session.public)
		end
		if type(session.party) == "table" then
			self.title:set_party(session.party)
		end
	end
	if world ~= nil then
		local inter = self.interact
		self:_sig(world, "tile_hovered", function(t)
			inter:on_hover(t)
		end)
		self:_sig(world, "tile_clicked", function(t)
			inter:on_click(t)
		end)
		self:_sig(world, "tile_context", function(t, pos)
			inter:on_context(t, if typeof(pos) == "Vector2" then ctx:to_logical(pos) else ctx:mouse_pos())
		end)
		ctx:world_call("set_labels_visible", { self.labels_on })
		-- Map labels step around every floating panel (the view tracks their rects itself).
		ctx:world_call("set_hud_controls", { self:hud_controls() })
		-- the globe can't draw territories (editable budget / Mesh-Image APIs off): a notice (R2-3)
		self:_sig(world, "territory_status_changed", function(st)
			self.globe_notice:set_status(st)
		end)
		local st = ctx:world_call("territory_status", {})
		if type(st) == "table" then
			self.globe_notice:set_status(st)
		end
	end
	if audio ~= nil then
		self:_sig(audio, "music_enabled_changed", function(on)
			self.pause:sync_music(on)
		end)
		if audio.pops_enabled_changed ~= nil then
			self:_sig(audio, "pops_enabled_changed", function(on)
				self.pause:sync_pops(on)
			end)
		end
	end
	self._theme = ""
	self:_request_apply()
end

--- A new player (Data/Tutorial.is_new, or "Replay as new player") on the title: their first match
--- starts by itself, as the tutorial (14% of new players never started one). Not in a Studio
--- session with the dev diag on, where it would start under every test (dev diag: `tutorial`).
UIRoot.TUTORIAL_DELAY_S = 0.9

function UIRoot._check_new_player(self, forced: boolean?)
	local ctx = self.ctx
	local s = ctx.session
	if self.tutorial == nil or self.tutorial.active or s == nil then
		return
	end
	if not forced then
		if UICtx.IS_ROBLOX and workspace:GetAttribute("AF_DIAG") == true then
			return
		end
		local stats = if type(s.load_settings) == "function" then s:load_settings("stats") else nil
		if not TutorialData.is_new(ctx.settings, stats) then
			return
		end
	end
	self._tutorial_at = UICtx.msec() + UIRoot.TUTORIAL_DELAY_S * 1000
end

function UIRoot._tutorial_step(self)
	local ctx = self.ctx
	if UICtx.msec() < self._tutorial_at then
		return
	end
	if self._autostart ~= nil or self._hop ~= nil or ctx:mode() ~= UICtx.MODE_TITLE or ctx:mp_waiting() then
		self._tutorial_at = nil -- (they are on their way into a match already)
		return
	end
	if self._screen ~= "title" or ctx:session_call("is_building") == true then
		return
	end
	self._tutorial_at = nil
	self:start_tutorial()
end

--- Starts the tutorial's match: a solo match on the default map with the gentlest AI and fewer
--- tribes, the steps on top (UI/Tutorial).
function UIRoot.start_tutorial(self)
	local ctx = self.ctx
	if ctx:session_call("is_building") == true or ctx:mode() ~= UICtx.MODE_TITLE then
		return
	end
	self._solo_msec = UICtx.msec()
	ctx:set_setting("tutorial", "started")
	self.coach.muted = true
	self.coach:clear()
	self.tutorial:begin()
	ctx:session_call("start_solo", {
		TutorialData.DIFFICULTY,
		UIMaps.DEFAULT_ID,
		{ tribes = TutorialData.TRIBES, countdown_ticks = TutorialData.COUNTDOWN_TICKS },
	})
end

--- Rofront Staging: "Replay as new player" (the game menu, and the settings page: the title's gear).
--- Everything first-time is as new again and the title follows, where the tutorial starts.
function UIRoot.replay_as_new_player(self)
	local ctx = self.ctx
	if not ctx.staging then
		return
	end
	self.coach:reset()
	self.tutorial:stop("left")
	ctx:set_setting("tutorial", "")
	ctx:session_call("new_player")
	-- (the starter pack is on offer again from the start: it may open by itself again)
	self._starter_shown = false
	ctx:set_setting("starter_auto_at", 0)
	if self.pause.is_open then
		self.pause:close()
	end
	if ctx:mode() ~= UICtx.MODE_TITLE then
		ctx:session_call("leave_match")
	end
	self:_check_new_player(true)
	-- (the way back to the title takes a moment)
	self._tutorial_at = UICtx.msec() + 2500
end

--- The player's saved [ui] settings arrived from the server.
function UIRoot._on_settings_loaded(self)
	local ctx = self.ctx
	ctx:reload_settings()
	self:_check_new_player(false)
	self.labels_on = ctx:setting("labels", true) ~= false
	self.title.difficulty =
		math.clamp(tonumber(ctx:setting("difficulty", UICtx.DEFAULT_DIFFICULTY)) or UICtx.DEFAULT_DIFFICULTY, 0, 2)
	for i, ch in ipairs(self.title._chips) do
		ch:set_pressed_no_signal(i - 1 == self.title.difficulty)
	end
	self.title:_refresh_diff()
	-- the saved solo map arrives with the settings: Play Solo uses it, so the title must show it
	self.title:set_map_name(UIMaps.name_of(UIMaps.valid(ctx:setting("map_id", UIMaps.DEFAULT_ID))))
	ctx:world_call("set_labels_visible", { self.labels_on and self._screen ~= "title" and self._screen ~= "" })
end

--- Every HUD panel that floats over the globe (WorldView.set_hud_controls: labels avoid them).
--- Returned as Roblox GuiObjects: viewport rect = AbsolutePosition + GuiService:GetGuiInset(), AbsoluteSize.
function UIRoot.hud_controls(self): { GuiObject }
	local out = {}
	local list = {
		self.top.panel,
		self.board.panel,
		self.board._pill,
		self.attacks.panel,
		self.bar.panel,
		self.bar.tray,
		self.bar._place_chip,
		self.spawn.panel,
		self.alert.panel,
		self.coach._card,
		self.target_card._panel,
		self.tooltip._panel,
		self.place_confirm._panel,
		self.unit_card._panel,
		self.feed._stack,
		self.notices._stack,
		self.spectate_pill,
		self.globe_notice and self.globe_notice.card,
		-- the result screen's column (title, copy, stats, buttons): labels keep showing through
		-- the dim around it, never under its text (review R2-3)
		self.over and self.over._center,
	}
	for i = 1, 19 do
		local n = list[i]
		if n ~= nil and n.gui ~= nil then
			table.insert(out, n.gui)
		end
	end
	for _, n in ipairs(self._extra_hud) do
		if n.gui ~= nil then
			table.insert(out, n.gui)
		end
	end
	return out
end

--- A transient HUD node (the war-begins banner's text) that map labels avoid while it is up; it
--- is dropped again when the node is freed.
function UIRoot.add_hud_control(self, node: any)
	if node == nil or node.gui == nil or node._freed then
		return
	end
	table.insert(self._extra_hud, node)
	node.tree_exiting:Connect(function()
		local i = table.find(self._extra_hud, node)
		if i ~= nil then
			table.remove(self._extra_hud, i)
			self.ctx:world_call("set_hud_controls", { self:hud_controls() })
		end
	end)
	self.ctx:world_call("set_hud_controls", { self:hud_controls() })
end

function UIRoot.toggle_help(self)
	if self.help.is_open then
		self.help:close()
	else
		self.radial:close(false)
		self.interact:cancel_aim(false)
		self.tooltip:hide_tip()
		self.help:open()
		self.help_toggled:Fire(true)
		self.telemetry:help(if self.title.visible then "title" else "match")
	end
	self:_update_input_gate()
	self:_update_pause()
end

function UIRoot.toggle_leaderboard(self)
	if self._screen == "title" or self._screen == "" then
		return
	end
	self.board:toggle()
	self.leaderboard_toggled:Fire(self.board.expanded)
end

--- Coalesced full re-layout (panel toggles): at most once per frame.
function UIRoot._request_relayout(self)
	if self._relayout_pending then
		return
	end
	self._relayout_pending = true
	W.defer(function()
		self._relayout_pending = false
		self:_layout()
	end)
end

--- The Arsenal (Data/Arsenal): units unlocked with Stars or Robux. `focus`: an item to bring into
--- view; `from`: "title" / "match" (the bar's SHOP) / "locked" (a locked unit pressed) / "over" /
--- "offer" (one of the result screen's offers).
--- A solo match stands still while it is open.
function UIRoot.open_arsenal(self, focus: string?, from: string?)
	if self.arsenal == nil then
		return
	end
	self.interact:cancel_aim(false)
	self.bar:set_tray(false)
	self.arsenal:open(focus, from)
	self:_update_input_gate()
	self:_update_pause()
end

--- The flag shop (FlagShop; Data/Shop): the title's shop button. Opening it marks today's shop seen
--- (the button's NEW sticker goes).
function UIRoot.open_shop(self)
	local fs = self.flag_shop
	if fs == nil or fs.is_open then
		return
	end
	fs:open()
	local ctx = self.ctx
	ctx:set_setting("shop_seen_day", FlagShop.contents(FlagShop.now()).day)
	if self.title ~= nil and self.title._shop_btn ~= nil then
		self.title._shop_btn:refresh()
	end
	self:_update_input_gate()
end

--- The starter pack's offer (StarterOffer; Data/Starter). `from`: "auto" | "button".
function UIRoot.open_starter(self, from: string)
	local st = self.starter
	local s = self.ctx.session
	if st == nil or st.is_open or s == nil then
		return
	end
	local o = s.inventory and s.inventory.starter
	if type(o) ~= "table" then
		return
	end
	st:open(from)
	if o.state == "ready" then
		s:starter_seen() -- (its 48 hours start now)
	end
	self:_update_input_gate()
end

--- The starter pack opens by itself on the title, once nothing else is going on: the first time (its
--- clock starts then), then at most once every Starter.AUTO_GAP_S (6 h, saved in the player's [ui]
--- settings as "starter_auto_at") while it runs (2026-10-15, as Tribes' offer; 2026-10-17: less
--- often, it opened on every server joined). The title's starter button opens it any time.
UIRoot.STARTER_DELAY_S = 1.5

function UIRoot._starter_auto(self)
	local ctx = self.ctx
	local s = ctx.session
	if self.starter == nil or self.starter.is_open or self._starter_shown or s == nil then
		return
	end
	local o = if s.inventory ~= nil and s.inventory.loaded then s.inventory.starter else nil
	if type(o) ~= "table" or s.settings_ready ~= true then
		return -- (no offer, or the saved settings with the last automatic opening aren't here yet)
	end
	if not StarterData.auto_due(o.state, ctx:setting("starter_auto_at", 0), os.time()) then
		self._starter_shown = true -- (opened by itself under 6 hours ago: not again this session)
		return
	end
	local quiet = self._screen == "title"
		and self.title.visible
		and ctx:mode() == UICtx.MODE_TITLE
		and not ctx:mp_waiting()
		and not self.title:public_busy()
		and not (self.help.is_open or self.pause.is_open or self.over.is_open or self.map_picker.is_open)
		and not (self.locker ~= nil and self.locker.is_open)
		and not (self.flag_shop ~= nil and self.flag_shop.is_open)
		and not (self.arsenal ~= nil and self.arsenal.is_open)
		and not (self.crate_opening ~= nil and self.crate_opening.is_open)
		and self._tutorial_at == nil
		and not (self.tutorial ~= nil and self.tutorial.active)
		and self._autostart == nil
		and self._hop == nil
		and ctx:session_call("is_building") ~= true
		and not (UICtx.IS_ROBLOX and workspace:GetAttribute("AF_DIAG") == true)
	if not quiet then
		self._starter_since = nil
		return
	end
	local now = UICtx.msec()
	if self._starter_since == nil then
		self._starter_since = now
		return
	end
	if now - self._starter_since < UIRoot.STARTER_DELAY_S * 1000 then
		return
	end
	self._starter_shown = true
	ctx:set_setting("starter_auto_at", os.time())
	self:open_starter("auto")
end

--- The Locker (Main's crate button on the title): crates, skins and flags.
function UIRoot.open_locker(self)
	if self.locker == nil or self.locker.is_open then
		return
	end
	self.locker:open()
	self:_update_input_gate()
end

function UIRoot.open_pause_menu(self)
	if self.pause.is_open then
		self.pause:close()
		return
	end
	if self.help.is_open then
		self.help:close()
	end
	self.radial:close(false)
	self.interact:cancel_aim(false)
	self.tooltip:hide_tip()
	self.pause:open(self.labels_on)
	self:_update_input_gate()
	self:_update_pause()
end

--- Settings (the top bar's gear): the game menu's window on its settings page, on the title too.
--- A second press closes it; over the open game menu it turns the page.
function UIRoot.open_settings(self)
	if self.pause.is_open then
		if self.pause:page() == "settings" then
			self.pause:close()
		else
			self.pause:show_settings()
		end
		return
	end
	if self.help.is_open then
		self.help:close()
	end
	self.radial:close(false)
	self.interact:cancel_aim(false)
	self.tooltip:hide_tip()
	self.pause:open(self.labels_on, "settings")
	self:_update_input_gate()
	self:_update_pause()
end

--- Current screen: "title", "spawn", "play" or "over".
function UIRoot.screen(self): string
	return self._screen
end

-- =============================================================================================
-- Construction
-- =============================================================================================

function UIRoot._make_gui(self, parent: Instance?)
	local sg = Instance.new("ScreenGui")
	sg.Name = "AirfrontUI"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.ScreenInsets = Enum.ScreenInsets.None
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.DisplayOrder = 10
	local p = parent
	if p == nil and UICtx.IS_ROBLOX then
		local lp = game:GetService("Players").LocalPlayer
		p = if lp then lp:WaitForChild("PlayerGui") else nil
	end
	sg.Parent = p
	self.gui = sg
	-- Exact Rubik metrics make the first layout final, but a cold client (first visit, slow network)
	-- must never sit on a blank screen: wait at most FONT_WAIT_S, then build with approximate metrics
	-- (the kit re-lays out every tree when the fonts arrive; UITheme.init keeps loading meanwhile).
	-- Main starts the Session, the globe and the top bar before building the UI.
	if UICtx.IS_ROBLOX and not UITheme.fonts_ready() then
		task.spawn(UITheme.init)
		local t0 = os.clock()
		while not UITheme.fonts_ready() and os.clock() - t0 < UIRoot.FONT_WAIT_S do
			task.wait()
		end
	end
	local root = W.Root.new(sg, { touch_device = self.ctx.touch_device })
	root.name = "UI"
	self.root = root
	self.ctx.root = root
	W.set_external_driver(true)
end

function UIRoot._layer(self, n: string)
	local c = W.Control.new()
	c.name = n
	c.gui.Name = n
	c:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	c:set_mouse_filter(W.MOUSE_IGNORE)
	return c
end

--- A full-rect node hosting a raw logical canvas (RadialMenu).
function UIRoot._host(self, canvas: GuiObject, n: string)
	local host = self:_layer(n)
	canvas.Parent = host.gui
	canvas.ZIndex = 1
	return host
end

function UIRoot._build(self)
	local ctx = self.ctx
	local root = self.root
	local CommandBar = kit("CommandBar")
	local TopStatus = kit("TopStatus")
	local Leaderboard = kit("Leaderboard")
	local EventFeed = kit("EventFeed")
	local AttacksPanel = kit("AttacksPanel")
	local AlertBanner = kit("AlertBanner")
	local BusyChip = kit("BusyChip")

	local hud = self:_layer("HUD")
	self.hud = hud
	local top = TopStatus.new(ctx)
	top.name = "TopStatus"
	self.top = top
	top.tapped:Connect(function()
		if ctx.compact and self._screen ~= "title" then
			self:toggle_leaderboard()
		end
	end)
	hud:add_child(top)
	local board = Leaderboard.new(ctx)
	board.name = "Leaderboard"
	self.board = board
	top.rank_provider = function()
		return board:my_rank()
	end
	board.toggled:Connect(function(_open)
		self:_request_relayout()
	end)
	hud:add_child(board)
	local feed = EventFeed.new(ctx)
	feed.name = "EventFeed"
	self.feed = feed
	hud:add_child(feed)
	local attacks = AttacksPanel.new(ctx)
	attacks.name = "Attacks"
	self.attacks = attacks
	attacks.retreat_requested:Connect(function(aid)
		self.interact:retreat(aid)
	end)
	attacks.toggled:Connect(function(_c)
		if self.bar.tray ~= nil and self.bar.tray.visible then
			self.bar:set_tray(false)
			attacks:peek()
		end
		self:_request_relayout()
	end)
	hud:add_child(attacks)
	local bar = CommandBar.new(ctx)
	bar.name = "CommandBar"
	self.bar = bar
	bar.build_chosen:Connect(function(kind)
		self.interact:select_action(kind)
	end)
	bar.slots_changed:Connect(function()
		self:relayout()
	end)
	bar.arsenal_wanted:Connect(function(key: string?, from: string?)
		ctx:sfx("confirm")
		-- (the SHOP button opens the Arsenal on the item it showed)
		self:open_arsenal(key, from or (if key ~= nil then "locked" else "match"))
	end)
	bar.cancel_placement:Connect(function()
		self.interact:cancel_aim()
	end)
	bar.footprint_changed:Connect(function()
		self:_request_relayout()
		-- The open tray takes the bottom of the screen: cards placed above the bar step aside.
		if bar.tray ~= nil and bar.tray.visible then
			self.target_card:hide_card()
			if self.tooltip:is_shown() and self.tooltip.place == Tooltip.Place.PINNED then
				self.tooltip:hide_tip()
			end
		end
	end)
	bar.stats_tapped:Connect(function()
		self:_toggle_stats_card()
	end)
	hud:add_child(bar)
	local spawn = SpawnOverlay.new(ctx)
	spawn.name = "Spawn"
	self.spawn = spawn
	hud:add_child(spawn)
	local alert = AlertBanner.new(ctx)
	alert.name = "NukeAlert"
	self.alert = alert
	hud:add_child(alert)
	self.spectate_pill = self:_build_spectate_pill()
	hud:add_child(self.spectate_pill)
	root:add_child(hud)

	local target_card = TargetCard.new(ctx)
	target_card.name = "TargetCard"
	target_card:set_meta("bar", bar)
	self.target_card = target_card
	hud:add_child(target_card)
	local place_confirm = PlaceConfirm.new(ctx)
	place_confirm.name = "PlaceConfirm"
	place_confirm:set_meta("bar", bar)
	place_confirm.blockers = function()
		local out = {}
		for _, c in ipairs({ top.panel, attacks.panel, bar.panel, bar.tray, bar._place_chip, alert.panel, board.panel }) do
			if c ~= nil and c:is_visible_in_tree() then
				table.insert(out, c:get_global_rect())
			end
		end
		return out
	end
	self.place_confirm = place_confirm
	hud:add_child(place_confirm)
	local unit_card = UnitCard.new(ctx)
	unit_card.name = "UnitCard"
	unit_card:set_meta("bar", bar)
	self.unit_card = unit_card
	hud:add_child(unit_card)
	local coach = Coach.new(ctx)
	coach.name = "Coach"
	self.coach = coach
	-- a new player's first match, step by step (UI/Tutorial, Data/Tutorial); the coach's tips wait
	local tutorial = Tutorial.new(ctx, self)
	tutorial.name = "Tutorial"
	self.tutorial = tutorial
	tutorial.step_done:Connect(function(step: number, _name: string)
		local s = ctx.session
		if s ~= nil and type(s.report) == "function" then
			s:report("tutorial", step)
		end
	end)
	tutorial.closed:Connect(function()
		coach.muted = false
	end)
	tutorial.finished:Connect(function(how: string)
		ctx:set_setting("tutorial", how)
		if how == "done" then
			-- what the steps taught is not said again as a tip
			for _, id in { "expand", "ratio", "city", "contact", "select" } do
				coach:complete(id)
			end
		end
		if how == "skipped" then
			local s = ctx.session
			if s ~= nil and type(s.report) == "function" then
				s:report("tutorial_skip", tutorial._i)
			end
		end
	end)
	ctx.ratio_changed:Connect(function(_r)
		if self._screen == "play" then
			coach:complete("ratio")
		end
	end)
	ctx.coach = coach
	coach.blockers = function()
		local out = {}
		for _, c in ipairs({
			top.panel,
			board.panel,
			board._pill,
			attacks.panel,
			bar.panel,
			bar.tray,
			bar._place_chip,
			alert.panel,
			spawn.panel,
		}) do
			if c ~= nil and c:is_visible_in_tree() then
				table.insert(out, c:get_global_rect())
			end
		end
		table.insert(out, self.feed:stack_rect())
		return out
	end
	coach.keepout = function()
		local r = ctx:world_call("local_label_rect", {})
		if typeof(r) == "Rect" then
			return { ctx:rect_to_logical(r) }
		end
		return nil
	end
	hud:add_child(coach)
	hud:add_child(tutorial)
	self.float_layer = self:_layer("Floats")
	root:add_child(self.float_layer)
	-- touch: the ring closing in around a finger held for the menu
	local hold = HoldRing.new(ctx)
	self.hold_ring = hold
	root:add_child(self:_host(hold.gui, "HoldRing"))
	local radial = RadialMenu.new(ctx)
	self.radial = radial
	radial.bottom_limit = function(): number?
		local bar = self.bar
		return if bar ~= nil and bar:is_visible_in_tree() then bar:base_edge() else nil
	end
	self._radial_host = self:_host(radial.gui, "Radial")
	root:add_child(self._radial_host)
	local tooltip = Tooltip.new(ctx)
	tooltip.name = "Tooltip"
	self.tooltip = tooltip
	ctx.tooltip = tooltip

	local title = TitleScreen.new(ctx)
	title.name = "Title"
	self.title = title
	title.play_solo:Connect(function(d)
		self:_on_play_solo(d)
	end)
	title.play_multi:Connect(function()
		ctx:session_call("join_multiplayer")
	end)
	title.vote_start:Connect(function()
		ctx:session_call("vote_start")
	end)
	title.join_lobby:Connect(function(id: string)
		ctx:sfx("click")
		ctx:session_call("join_lobby", { id })
	end)
	title.join_public:Connect(function(mode: string)
		ctx:sfx("click")
		ctx:session_call("join_public", { mode })
	end)
	title.leave_line:Connect(function()
		ctx:sfx("click")
		ctx:session_call("leave_line")
	end)
	title.party_action:Connect(function(action: string, uid: number?)
		ctx:session_call("party_action", { action, uid })
	end)
	title.show_help:Connect(function()
		self:toggle_help()
	end)
	title.open_locker:Connect(function()
		self:open_locker()
	end)
	title.open_shop:Connect(function()
		self:open_shop()
	end)
	title.open_starter:Connect(function()
		self:open_starter("button")
	end)
	title.open_arsenal:Connect(function()
		ctx:sfx("confirm")
		self:open_arsenal(nil, "title")
	end)
	title.pick_map:Connect(function()
		self.map_picker:set_entries(UIMaps.entries())
		self.map_picker:open(UIMaps.valid(ctx:setting("map_id", UIMaps.DEFAULT_ID)))
		self:_update_input_gate()
	end)
	title:set_map_name(UIMaps.name_of(UIMaps.valid(ctx:setting("map_id", UIMaps.DEFAULT_ID))))
	title.leave_queue:Connect(function()
		ctx:session_call("leave_match")
	end)
	root:add_child(title)
	local over = GameOver.new(ctx)
	over.name = "GameOver"
	self.over = over
	over.play_again:Connect(function()
		over:close()
		self:_restart_solo(
			math.clamp(tonumber(ctx:setting("difficulty", UICtx.DEFAULT_DIFFICULTY)) or UICtx.DEFAULT_DIFFICULTY, 0, 2)
		)
	end)
	over.spectate:Connect(function()
		self:_update_input_gate()
		self:_layout()
	end)
	over.open_arsenal:Connect(function(key: string?, from: string?)
		ctx:sfx("confirm")
		self:open_arsenal(key, from or "over")
	end)
	over.to_title:Connect(function()
		over:close()
		ctx:session_call("leave_match")
	end)
	-- solo: take over the nation that eliminated you (Takeover.luau)
	self.takeover = Takeover.new(self)
	over.take_over:Connect(function()
		self.takeover:start()
	end)
	root:add_child(over)
	local pause = PauseMenu.new(ctx)
	pause.name = "GameMenu"
	self.pause = pause
	pause.closed:Connect(function()
		self:_update_input_gate()
		self:_update_pause()
	end)
	pause.restart_requested:Connect(function()
		self:_restart_solo(
			math.clamp(tonumber(ctx:setting("difficulty", UICtx.DEFAULT_DIFFICULTY)) or UICtx.DEFAULT_DIFFICULTY, 0, 2)
		)
	end)
	pause.tips_reset:Connect(function()
		coach:reset()
	end)
	pause.new_player_requested:Connect(function()
		self:replay_as_new_player()
	end)
	pause.help_requested:Connect(function()
		self:toggle_help()
	end)
	pause.leave_requested:Connect(function()
		ctx:session_call("leave_match")
	end)
	pause.labels_toggled:Connect(function(on)
		self:_set_labels(on)
	end)
	pause.music_toggled:Connect(function(on)
		ctx:set_music(on)
		self.music_toggled:Fire(on)
	end)
	pause.music_volume_changed:Connect(function(v: number, final: boolean)
		ctx:set_music_volume(v, final)
	end)
	pause.pops_toggled:Connect(function(on)
		ctx:set_pops(on)
	end)
	root:add_child(pause)
	local help = HelpOverlay.new(ctx)
	help.name = "Help"
	self.help = help
	help.closed:Connect(function()
		self.help_toggled:Fire(false)
		self:_update_input_gate()
		self:_update_pause()
	end)
	root:add_child(help)
	local picker = MapPicker.new(ctx)
	picker.name = "MapPicker"
	self.map_picker = picker
	picker.picked:Connect(function(id: string)
		ctx:set_setting("map_id", id)
		self.title:set_map_name(UIMaps.name_of(id))
	end)
	picker.closed:Connect(function()
		self:_update_input_gate()
	end)
	root:add_child(picker)
	-- the Locker: cosmetic crates, skins and flags (the title's crate button)
	local locker = Locker.new(ctx)
	locker.name = "Locker"
	self.locker = locker
	locker._toast = function(_l, text: string)
		self:_on_notice(text, 0)
	end
	locker.closed:Connect(function()
		self:_update_input_gate()
	end)
	root:add_child(locker)
	-- the Arsenal: units unlocked with Stars or Robux (the title's Arsenal button, the bar's tray)
	local arsenal = Arsenal.new(ctx)
	arsenal.name = "Arsenal"
	self.arsenal = arsenal
	arsenal.closed:Connect(function()
		self:_update_input_gate()
		self:_update_pause()
		self.bar:refresh_buttons()
	end)
	root:add_child(arsenal)
	-- the starter pack's offer (the title's starter button; opens by itself once: _starter_auto)
	local starter = StarterOffer.new(ctx)
	starter.name = "StarterOffer"
	self.starter = starter
	starter.ui_notice = function(text: string)
		self:_on_notice(text, 0)
	end
	starter.closed:Connect(function()
		self:_update_input_gate()
	end)
	root:add_child(starter)
	-- the flag shop (the title's shop button)
	local flag_shop = FlagShop.new(ctx)
	flag_shop.name = "FlagShop"
	self.flag_shop = flag_shop
	flag_shop._toast = function(_f, text: string)
		self:_on_notice(text, 0)
	end
	flag_shop.closed:Connect(function()
		self:_update_input_gate()
	end)
	root:add_child(flag_shop)
	-- opening a crate: the show above the Locker (CrateOpening.luau)
	local opening = CrateOpening.new(ctx)
	opening.name = "CrateOpening"
	self.crate_opening = opening
	locker:set_opening(opening)
	root:add_child(opening)
	local busy = BusyChip.new(ctx)
	busy.name = "Busy"
	self.busy = busy
	root:add_child(busy)
	local notices = EventFeed.new(ctx, true)
	notices.name = "Notices"
	self.notices = notices
	root:add_child(notices)
	-- "territory map unavailable" card (review_code.md R2-3)
	local globe_notice = kit("GlobeNotice").new(ctx)
	globe_notice.name = "GlobeNotice"
	self.globe_notice = globe_notice
	root:add_child(globe_notice)
	root:add_child(tooltip)

	self.advisor = UIAdvisor.new(self)
	self.probe = UILayoutProbe.new(self)
	local interact = UIInteract.new(ctx)
	interact.bar = bar
	interact.tooltip = tooltip
	interact.radial = radial
	interact.float_layer = self.float_layer
	interact.ui = self
	self.interact = interact
	radial.picked:Connect(function(id, t)
		interact:on_radial(id, t)
	end)
	interact.target_card = target_card
	interact.place_confirm = place_confirm
	interact.unit_card = unit_card
	unit_card.closed:Connect(function()
		ctx:world_call("set_selected_unit", { -1 })
	end)
	place_confirm.confirmed:Connect(function()
		interact:confirm_ghost()
	end)
	place_confirm.cancelled:Connect(function()
		interact:cancel_aim()
	end)
	target_card.fire:Connect(function()
		interact:fire_from_card()
	end)
	target_card.ally:Connect(function()
		interact:ally_from_card()
	end)
	target_card.betray:Connect(function(attack)
		interact:betray_from_card(attack)
	end)
	target_card.donate:Connect(function()
		interact:donate_from_card()
	end)
	target_card.closed:Connect(function()
		ctx:world_call("set_selected_owner", { 0 })
		ctx:world_call("set_range_mode", { "auto" })
		ctx:world_call("set_range_owner", { 0 })
	end)
	self.touch_router = TouchRouter.new(self)
	self.touch_router:connect()
	local rotate_card = RotateCard.new(ctx)
	rotate_card.name = "RotateCard"
	self.rotate_card = rotate_card
	root:add_child(rotate_card)
	rotate_card.changed:Connect(function(_shown)
		self:_update_input_gate()
	end)
	interact:connect_input()
	self:_hook_buttons(root)
	if UICtx.IS_ROBLOX then
		local RunService = game:GetService("RunService")
		self._step_name = "AirfrontUI_" .. tostring(math.random(1, 1e9))
		local perf = { frames = 0, process = 0.0, kit = 0.0, max = 0.0 }
		self._perf = perf
		-- (Telemetry "slow" says how much of a slow frame the HUD's own work was)
		self.telemetry.ui_perf = perf
		-- (the frame's dt: a Studio film steps it)
		local FrameClock = require("../Map/FrameClock") :: any
		RunService:BindToRenderStep(self._step_name, Enum.RenderPriority.Camera.Value + 10, function(real_dt)
			local dt = FrameClock.dt(real_dt)
			local t0 = os.clock()
			-- _process guards each component itself; this outer guard keeps W.step (tweens, timers,
			-- layout) running even if something outside those guards throws.
			W.guard("UIRoot._process", self._process, self, dt)
			local t1 = os.clock()
			W.guard("Widgets.step", W.step, dt)
			local t2 = os.clock()
			perf.frames += 1
			perf.process += t1 - t0
			perf.kit += t2 - t1
			perf.max = math.max(perf.max, t2 - t0)
		end)
		table.insert(
			self._conns,
			root.resized:Connect(function()
				self:_layout()
			end)
		)
	end
end

--- The spectating pill's takeover button (Takeover.refresh): nil hides it.
function UIRoot._set_spec_takeover(self, info: any)
	local b = self._spec_take
	if b == nil then
		return
	end
	self._spec_take_info = info
	if info == nil then
		b:set_visible(false)
	else
		b:set_visible(true)
		b:set_disabled(info.busy == true)
		if info.saved > 0 then
			b:set_icon("check")
			b:set_text(if info.busy then "Taking over…" else "Take over (saved)")
		else
			b:set_icon("robux")
			b:set_text(if info.busy then "Taking over…" else string.format("Take over  ·  %d", info.price))
		end
	end
	self:_layout()
end

--- Solo: the player took over nation `id` (Session.take_over): back to playing, camera on it.
function UIRoot._on_took_over(self, id: number)
	local ctx = self.ctx
	if self._elim_timer ~= nil then
		self._elim_timer.cancel()
		self._elim_timer = nil
	end
	self._stats.elim = false
	self._stats.killer = 0
	self._stats.over = false
	if self.over.is_open then
		self.over:close()
	end
	-- everything bound to "me" follows the new nation: its borders (attack / expand reach — the
	-- tracker still pointed at the fallen nation: "No border or sea route" everywhere), its structure
	-- counts (build costs), the HUD, its pending alliance requests, its attacks
	ctx.rules:recount()
	self:_bind_refresh()
	self.attacks:mark_dirty()
	self.board:mark_dirty()
	ctx:world_call("focus_owner", { id })
	ctx:sfx("start")
	self:_update_pause()
	self:_update_input_gate()
	self:_request_apply()
end

function UIRoot._build_spectate_pill(self)
	local ctx = self.ctx
	local p = GlassPanel.new(16.0, 8.0, 999, true, 16)
	local h = UITheme.hbox(12)
	p:add_child(h)
	local eye = UITheme.icon_rect("eye", 18.0, UITheme.CYAN)
	eye.size_flags_vertical = W.SHRINK_CENTER
	h:add_child(eye)
	local v = UITheme.vbox(0)
	v.size_flags_vertical = W.SHRINK_CENTER
	v:add_child(UITheme.label("SPECTATING", 13, 800, UITheme.TEXT, 2))
	self._spec_sub = UITheme.label("Drag to look around · click a nation for details", 11, 500, UITheme.TEXT_2)
	v:add_child(self._spec_sub)
	h:add_child(v)
	-- solo: take over the nation that conquered you (Takeover.luau; hidden without an offer)
	self._spec_take = UITheme.button("Take over", "PrimaryButton", "robux", 44.0)
	self._spec_take:set_font_size(13)
	self._spec_take.size_flags_vertical = W.SHRINK_CENTER
	self._spec_take.pressed:Connect(function()
		if self.takeover ~= nil then
			self.takeover:start()
		end
	end)
	self._spec_take:set_visible(false)
	h:add_child(self._spec_take)
	self._spec_again = UITheme.button("Play again", "PrimaryButton", "play", 44.0)
	self._spec_again:set_font_size(13)
	self._spec_again.pressed:Connect(function()
		self:_restart_solo(
			math.clamp(tonumber(ctx:setting("difficulty", UICtx.DEFAULT_DIFFICULTY)) or UICtx.DEFAULT_DIFFICULTY, 0, 2)
		)
	end)
	self._spec_again.size_flags_vertical = W.SHRINK_CENTER
	h:add_child(self._spec_again)
	local b = UITheme.button("Title", "GlassButton", "exit", 44.0)
	self._spec_leave = b
	b:set_font_size(13)
	b.size_flags_vertical = W.SHRINK_CENTER
	b.pressed:Connect(function()
		ctx:session_call("leave_match")
	end)
	h:add_child(b)
	p:set_visible(false)
	return p
end

--- Connect to a signal of a duck-typed object (Session / WorldView / AudioDirector) if it has it.
function UIRoot._sig(self, obj: any, sig: string, cb: (...any) -> ())
	local s = obj[sig]
	if (type(s) == "table" and type(s.Connect) == "function") or typeof(s) == "RBXScriptSignal" then
		table.insert(self._sconns, s:Connect(cb))
	end
end

--- Button sounds (GDScript _on_node_added): click on press, soft hover on desktop. The kit tree
--- has no node_added signal, so new buttons are hooked on layout / every half second.
function UIRoot._hook_buttons(self, n: any)
	local ctx = self.ctx
	local BuildButton = kit("BuildButton")
	local Leaderboard = self.board and getmetatable(self.board)
	local function rec(node)
		if node._freed then
			return
		end
		if node.pressed ~= nil and node.gui ~= nil and node.gui:IsA("GuiButton") and not node._sfx_hooked then
			node._sfx_hooked = true
			local quiet = (BuildButton ~= nil and getmetatable(node) == BuildButton.__mt)
				or (node.__row_of_leaderboard == true)
			if quiet then
				node.pressed:Connect(function()
					ctx:sfx("click", -4.0)
				end)
			else
				node.pressed:Connect(function()
					ctx:sfx("click", -2.0)
				end)
				node.mouse_entered:Connect(function()
					if not node.disabled and not ctx.touch then
						ctx:sfx("hover", -14.0)
					end
				end)
			end
		end
		for _, c in ipairs(node.children or {}) do
			rec(c)
		end
		for _, c in ipairs(node._internal or {}) do
			rec(c)
		end
	end
	local _ = Leaderboard
	rec(n)
end

-- =============================================================================================
-- Session
-- =============================================================================================

function UIRoot._on_state_ready(self, s: any)
	self:_end_building()
	-- (a new state schedules the deferred rebind, which ends with the screen switch)
	self:_bind_state(s)
	if s == nil then
		self:_request_apply()
	end
end

function UIRoot._on_joined_owner(self, _id: number)
	local ctx = self.ctx
	if ctx.state ~= nil then
		-- the border scan and the HUD refresh run in the deferred rebind step (_bind_refresh)
		ctx.borders:bind(ctx.state, 0)
		ctx.rules:recount()
		self:_schedule_rebind()
	else
		self:_request_apply()
	end
end

--- The frame that delivers a new match (state_ready / joined_owner) already carries the Session's
--- last build slice and the view's rebind, and the next one the territory rebuild. The UI's own
--- rebind work (~5 ms on desktop, several times that on phones) is therefore spread over the frames
--- after them: _bind_refresh (border scan, HUD refresh) REBIND_FRAMES later, then the screen switch
--- (_apply_screen and its layout) one frame after that. Screen requests meanwhile wait for it.
UIRoot.REBIND_FRAMES = 2

function UIRoot._schedule_rebind(self)
	if self._rebind_refresh_in == nil then
		self._rebind_refresh_in = UIRoot.REBIND_FRAMES
	end
	self._rebind_apply_in = nil
end

--- True while a deferred rebind (refresh or screen switch) is pending.
function UIRoot.rebind_pending(self): boolean
	return self._rebind_refresh_in ~= nil or self._rebind_apply_in ~= nil
end

local function rebind_step(self)
	local n = self._rebind_refresh_in
	if n ~= nil then
		if n > 0 then
			self._rebind_refresh_in = n - 1
			return
		end
		self._rebind_refresh_in = nil
		self._rebind_apply_in = 1
		self:_bind_refresh()
		return
	end
	local a = self._rebind_apply_in
	if a ~= nil then
		if a > 0 then
			self._rebind_apply_in = a - 1
			return
		end
		self._rebind_apply_in = nil
		-- inside the kit step like _request_apply, so its follow-up layout (W.defer) lands next frame
		W.defer(function()
			if not self:rebind_pending() then
				self:_apply_screen()
			end
		end)
	end
end

--- Phones: the strip shows only numbers; one tap opens the details card above it.
function UIRoot._toggle_stats_card(self)
	local tooltip = self.tooltip
	if tooltip:is_shown() and tooltip.place == Tooltip.Place.PINNED and tooltip:has_meta("stats") then
		tooltip:hide_tip()
		return
	end
	local spec = self.bar:stats_spec()
	if spec == nil or next(spec) == nil then
		return
	end
	self.target_card:hide_card()
	local r = self.bar:stats_rect()
	local top_y = math.min(r.Min.Y, self.bar:top_edge()) - 8.0
	tooltip:show_pinned(spec, Rect.new(0, 0, r.Min.X + 236.0, top_y))
	tooltip:set_meta("stats", true)
end

--- A solo match started on an outdated server is played on a fresh one (server/FreshServers;
--- 2026-10-04).
--- The server says so in workspace attribute RF_Outdated; it is asked to
--- teleport us (Session.hop_solo) and the match starts on arrival (autostart_solo). Once a session:
--- no answer within HOP_ANSWER_S, "stay", or still here HOP_TRAVEL_S after "going" starts it here.
UIRoot.HOP_ANSWER_S = 4.0
UIRoot.HOP_TRAVEL_S = 25.0

function UIRoot._hop_instead(self, difficulty: number, restart: boolean): boolean
	local ctx = self.ctx
	if not UICtx.IS_ROBLOX or self._hop_tried or self._hop ~= nil then
		return false
	end
	if workspace:GetAttribute("RF_Outdated") ~= true then
		return false
	end
	local s = ctx.session
	local map_id = UIMaps.valid(ctx:setting("map_id", UIMaps.DEFAULT_ID))
	if s == nil or type(s.hop_solo) ~= "function" or not s:hop_solo(difficulty, map_id) then
		return false
	end
	self._hop_tried = true
	self._hop = { difficulty = difficulty, restart = restart, deadline = UICtx.msec() + UIRoot.HOP_ANSWER_S * 1000 }
	self.busy:show_text("Updating to the latest version…")
	return true
end

function UIRoot._on_hop_result(self, going: boolean)
	local h = self._hop
	if h == nil then
		return
	end
	if going then
		h.deadline = UICtx.msec() + UIRoot.HOP_TRAVEL_S * 1000
	else
		self:_hop_fallback()
	end
end

--- The hop is off: the match starts on this server after all.
function UIRoot._hop_fallback(self)
	local h = self._hop
	if h == nil then
		return
	end
	self._hop = nil
	self.busy:hide_chip()
	if h.restart then
		self:_restart_solo(h.difficulty)
	else
		self:_on_play_solo(h.difficulty)
	end
end

--- Arrived from an outdated server with a solo match asked for there (the teleport's data; Main):
--- it starts as soon as the title is up.
function UIRoot.autostart_solo(self, difficulty: number, map_id: string?)
	self._hop_tried = true
	self._autostart = {
		difficulty = math.clamp(math.floor(difficulty), 0, 2),
		map_id = map_id,
		deadline = UICtx.msec() + 20000,
	}
end

function UIRoot._autostart_step(self)
	local a = self._autostart
	local ctx = self.ctx
	if a == nil then
		return
	end
	if UICtx.msec() > a.deadline or ctx:mode() == UICtx.MODE_SOLO or ctx:mode() == UICtx.MODE_MULTI then
		self._autostart = nil
		return
	end
	if self._screen ~= "title" or ctx:session_call("is_building") == true or ctx:mp_waiting() then
		return
	end
	self._autostart = nil
	if a.map_id ~= nil then
		ctx:set_setting("map_id", UIMaps.valid(a.map_id))
	end
	self:_on_play_solo(a.difficulty)
end

function UIRoot._on_play_solo(self, difficulty: number)
	local ctx = self.ctx
	-- A second tap can land after a fast build finished but before the title fades out: never
	-- start a second match over the one just built.
	if
		ctx:session_call("is_building") == true
		or ctx:mode() == UICtx.MODE_SOLO
		or UICtx.msec() - self._solo_msec < 1500
		or self._hop ~= nil
	then
		return
	end
	-- waiting in line for a public match (Quick Play): out of it first
	if self.title:public_busy() then
		ctx:session_call("leave_line")
	end
	if self:_hop_instead(difficulty, false) then
		return
	end
	self._solo_msec = UICtx.msec()
	ctx:set_setting("difficulty", difficulty)
	ctx:sfx("click")
	ctx:session_call("start_solo", { difficulty, UIMaps.valid(ctx:setting("map_id", UIMaps.DEFAULT_ID)) })
end

--- A fresh solo match from inside one: the results screen's "Play again", the game menu's "Restart
--- match" and the spectate pill's "Play again". DELIBERATE DEVIATION: ui_root.gd routed these through
--- _on_play_solo, whose "already in solo" guard (meant for a second tap on the title) made all three
--- dead buttons. Session.start_solo builds the new world in the background (the old one stays frozen
--- meanwhile, with the "Deploying a new world…" chip) and swaps it in on state_ready.
function UIRoot._restart_solo(self, difficulty: number)
	local ctx = self.ctx
	if
		ctx:mode() ~= UICtx.MODE_SOLO
		or ctx:session_call("is_building") == true
		or UICtx.msec() - self._solo_msec < 1500
		or self._hop ~= nil
	then
		return
	end
	if self:_hop_instead(difficulty, true) then
		return
	end
	self._solo_msec = UICtx.msec()
	ctx:set_setting("difficulty", difficulty)
	ctx:sfx("click")
	self._restart_pending = true
	ctx:session_call("start_solo", { difficulty, UIMaps.valid(ctx:setting("map_id", UIMaps.DEFAULT_ID)) })
	self:_update_pause()
end

--- Session builds new worlds in the background: acknowledge instantly, swap when state_ready fires.
function UIRoot._on_building(self, mode: number)
	self._building = true
	local what = if mode == UICtx.MODE_TITLE then "Returning to the title…" else "Deploying a new world…"
	self.title:set_building(mode ~= UICtx.MODE_TITLE)
	self.over:set_building(mode ~= UICtx.MODE_TITLE)
	if mode ~= UICtx.MODE_TITLE or self._screen ~= "title" then
		self.busy:show_text(what)
	end
end

function UIRoot._end_building(self)
	self._restart_pending = false
	if not self._building then
		return
	end
	self._building = false
	self.title:set_building(false)
	self.over:set_building(false)
	self.busy:hide_chip()
end

function UIRoot._bind_state(self, s: any)
	local ctx = self.ctx
	for _, c in ipairs(self._conns_state or {}) do
		c:Disconnect()
	end
	self._conns_state = {}
	ctx.state = s
	-- the mode this state was built for (Session.state_mode): a title backdrop that finishes while
	-- the player waits for a multiplayer match must not pass for the match
	local sm = if ctx.session ~= nil then tonumber(ctx.session.state_mode) else nil
	ctx.state_mode = sm or ctx:mode()
	W.guard("Telemetry.bind", self.telemetry.bind, self.telemetry, s)
	self:_reset_match()
	-- a new match: the Attack bar starts at its default and the leaderboard closed (not the state a
	-- resync hands over mid-match)
	if not (ctx.session ~= nil and ctx.session.state_is_resync == true) then
		ctx:reset_ratio()
		if self.board.expanded then
			self.board:close_for_match()
			self.leaderboard_toggled:Fire(false)
			self:_request_relayout()
		end
	end
	local adv = self.advisor
	table.clear(adv._ship_state)
	table.clear(adv._ship_vet)
	table.clear(adv._sam_by_nuke)
	table.clear(adv._volleys)
	table.clear(adv._shells)
	if self.unit_card ~= nil then
		self.unit_card:hide_card()
	end
	if s == nil then
		return
	end
	local function c(name: string, cb: (...any) -> ())
		local sig = s[name]
		if type(sig) == "table" and sig.Connect then
			table.insert(self._conns_state, sig:Connect(cb))
		end
	end
	local bar = self.bar
	c("tiles_changed", function(changed)
		ctx.borders:on_tiles_changed(changed)
		adv:on_tiles_changed(changed)
	end)
	c("stats_changed", function()
		adv:track_stats()
		adv:check_renewals()
		bar:sample_growth()
		if bar.visible then
			bar:refresh()
		end
		self.board:mark_dirty()
	end)
	c("owner_eliminated", function(id, killer)
		adv:on_owner_eliminated(id, killer)
	end)
	c("structure_added", function(sid)
		adv:on_structure_added(sid)
	end)
	c("structure_changed", function(sid, old)
		local st = ctx.state.structures[sid]
		if st ~= nil and ctx.rules:on_structure(st.kind, old, st.owner) then
			bar:refresh_buttons()
		end
	end)
	c("structure_removed", function(sid)
		local st2 = ctx.state.structures[sid]
		if st2 ~= nil and ctx.rules:on_structure(st2.kind, st2.owner, 0) then
			bar:refresh_buttons()
		end
	end)
	c("structure_leveled", function(sid)
		local sl = ctx.state.structures[sid]
		if sl ~= nil and sl.owner == ctx:me() then
			bar:refresh_buttons() -- levels count toward the next price
		end
	end)
	c("unit_added", function(uid)
		adv:on_unit_added(uid)
	end)
	c("sam_launched", function(id)
		adv:on_sam_launched(id)
	end)
	c("shell_fired", function(id)
		adv:on_shell_fired(id)
	end)
	c("shell_impact", function(id, hit)
		adv:on_shell_impact(id, hit)
	end)
	c("unit_removed", function(uid, reason)
		adv:on_unit_removed(uid, reason)
	end)
	for _, sig_name in ipairs({ "unit_state_changed", "unit_hp_changed", "unit_veterancy_changed" }) do
		c(sig_name, function(uid)
			adv:on_unit_changed(uid)
		end)
	end
	c("unit_removed", function(uid, _reason)
		local u = ctx.state.units[uid]
		if u ~= nil and ctx.rules:on_unit(u.kind, u.owner, -1) then
			bar:refresh_buttons()
		end
	end)
	c("nuke_launched", function(uid)
		adv:on_nuke_launched(uid)
	end)
	c("nuke_detonated", function(uid, kind, tile, radius, owner)
		adv:on_nuke_detonated(uid, kind, tile, radius, owner)
	end)
	c("attack_started", function(aid)
		adv:on_attack_started(aid)
	end)
	c("attack_updated", function(aid)
		self:_on_attack_touched(aid)
	end)
	c("attack_ended", function(aid)
		self:_on_attack_touched(aid)
	end)
	c("alliance_requested", function(from, to)
		adv:on_alliance_requested(from, to)
	end)
	c("alliance_request_closed", function(from, to)
		adv:on_alliance_request_closed(from, to)
	end)
	c("alliance_changed", function(a, b, formed, traitor, expired)
		adv:on_alliance_changed(a, b, formed, traitor, expired)
	end)
	c("traitor_marked", function(_id, _until)
		self.board:mark_dirty()
	end)
	c("message", function(to, cat, text)
		adv:on_message(to, cat, text)
	end)
	c("phase_changed", function(phase, left)
		self:_on_phase_changed(phase, left)
	end)
	c("game_over", function(winner, reason)
		adv:on_game_over(winner, reason)
	end)
	c("owner_spawned", function(id, tile)
		self:_on_owner_spawned(id, tile)
	end)
	-- cheap now: the tracker forgets the previous match (its events stop), the rule counts are
	-- current; the full border scan waits for _bind_refresh
	ctx.borders:bind(s, 0)
	ctx.rules:recount()
	ctx.play_start_tick = -1.0
	if s.phase ~= Defs.PHASE_SPAWN then
		-- Joined a running match. time_limit_ticks is absolute (= start of play + the limit), so the
		-- start of play follows exactly; without a limit fall back to the lobby clock.
		if (s.time_limit_ticks or 0) > 0 then
			ctx.play_start_tick = math.max(0.0, s.time_limit_ticks - ctx:match_limit_s() * Defs.TICK_RATE)
		elseif ctx:mode() == UICtx.MODE_MULTI then
			ctx.play_start_tick = math.max(0.0, s.tick - (tonumber(ctx:lobby().elapsed_s) or 0.0) * Defs.TICK_RATE)
		else
			ctx.play_start_tick = 0.0
		end
	end
	self:_schedule_rebind()
end

--- The expensive half of a (re)bind, run a few frames after state_ready (see REBIND_FRAMES): the
--- local player's border scan, the HUD refresh and pending alliance requests. The screen switch
--- follows one frame later.
function UIRoot._bind_refresh(self)
	local ctx = self.ctx
	local s = ctx.state
	if s == nil then
		return
	end
	local bar = self.bar
	self.advisor:track_stats()
	ctx.borders:bind(s, s.local_owner)
	self.top:on_bind()
	self.spawn:on_phase(if s.phase == Defs.PHASE_SPAWN then (s.phase_ticks_left or 0) else 0)
	bar:reset_rate()
	bar:refresh(false)
	self.board:refresh()
	local keys = {}
	for key in pairs(s.requests or {}) do
		table.insert(keys, key)
	end
	table.sort(keys)
	for _, key in ipairs(keys) do
		if key % 1024 == s.local_owner and s.local_owner ~= 0 and not self.feed:has_request_card(key // 1024) then
			self.feed:alliance_request(key // 1024)
		end
	end
	ctx.state_bound:Fire()
end

--- Attack events arrive for every war on the planet; only ours matter to the panel.
function UIRoot._on_attack_touched(self, aid: number)
	local ctx = self.ctx
	local a = if ctx.state ~= nil then ctx.state.attacks[aid] else nil
	if a ~= nil and ctx:me() ~= 0 and (a.attacker == ctx:me() or a.target == ctx:me()) then
		self.attacks:mark_dirty()
	end
end

function UIRoot._reset_match(self)
	local ctx = self.ctx
	self.feed:clear()
	self.target_card:hide_card()
	self.coach:clear()
	self.advisor:reset()
	ctx:set_paused(false)
	self.alert:clear()
	self.interact:cancel_aim(false)
	self.radial:close(false)
	self.tooltip:hide_tip()
	if self.over.is_open then
		self.over:close()
	end
	if self._elim_timer ~= nil then
		self._elim_timer.cancel()
	end
	self._elim_timer = nil
	self._stats =
		{ peak_share = 0.0, max_troops = 0, kills = 0, duration_s = 0.0, over = false, elim = false, killer = 0 }
	ctx:world_call("set_selected_owner", { 0 })
end

--- Elimination curtain after `sec` (UIAdvisor).
function UIRoot._start_elim_timer(self, sec: number, killer: number)
	if self._elim_timer ~= nil then
		self._elim_timer.cancel()
	end
	local h
	h = W.timer(sec, function()
		h.done = true
		self.advisor:on_elim_timeout(killer)
	end)
	self._elim_timer = h
end

function UIRoot._elim_timer_pending(self): boolean
	local h = self._elim_timer
	return h ~= nil and not h.cancelled and not h.done
end

-- =============================================================================================
-- GameState events
-- =============================================================================================

function UIRoot._on_notice(self, text: string, severity: number)
	local cat = Defs.MSG_INFO
	if severity == 1 then
		cat = Defs.MSG_BAD
	elseif severity == 2 then
		cat = Defs.MSG_ALERT
	end
	self.notices:toast(cat, text, if severity == 0 then "info" else "target", if severity > 0 then 9.0 else 6.0)
	self.ctx:sfx(if severity == 2 then "deny" else "toast", -4.0)
end

function UIRoot._on_phase_changed(self, phase: number, ticks_left: number)
	local ctx = self.ctx
	self.top:on_phase(phase, ticks_left)
	if phase == Defs.PHASE_SPAWN then
		self.spawn:on_phase(ticks_left)
	end
	if phase == Defs.PHASE_PLAYING and ctx.play_start_tick < 0.0 and ctx.state ~= nil then
		ctx.play_start_tick = ctx.state.tick
	end
	if phase == Defs.PHASE_PLAYING and self._screen == "spawn" and ctx:in_match() and not ctx:needs_spawn() then
		ctx:sfx("start")
		-- After the HUD has switched to play (and the globe's safe area follows), so the camera
		-- push-in and the banner use the final layout.
		self:_request_apply()
		W.defer(function()
			W.defer(function()
				self.advisor:war_begins()
			end)
		end)
		return
	end
	self:_request_apply()
end

function UIRoot._on_owner_spawned(self, id: number, _tile: number)
	local ctx = self.ctx
	if id == ctx:me() and id ~= 0 then
		self.spawn:refresh()
		self:_request_apply()
		-- landed once play had begun (placed automatically after not picking, or a late landing):
		-- the camera goes to the new nation, and the start sound the others heard plays now
		if ctx.state ~= nil and ctx.state.phase == Defs.PHASE_PLAYING and self._screen == "spawn" then
			ctx:world_call("focus_owner", { id })
			ctx:sfx("start")
		end
	end
end

-- =============================================================================================
-- Screens
-- =============================================================================================

function UIRoot._request_apply(self)
	if self._apply_pending then
		return
	end
	self._apply_pending = true
	W.defer(function()
		if self:rebind_pending() then
			-- a deferred rebind is in flight: its last step applies the screen
			self._apply_pending = false
			return
		end
		self:_apply_screen()
	end)
end

function UIRoot._compute_screen(self): string
	local ctx = self.ctx
	local m = ctx:mode()
	if ctx.session == nil or m == UICtx.MODE_TITLE or ctx.state_mode ~= m or ctx.state == nil then
		return "title"
	end
	local ph = ctx.state.phase
	if ph == Defs.PHASE_SPAWN then
		return "spawn"
	elseif ph == Defs.PHASE_PLAYING then
		return if ctx:needs_spawn() then "spawn" else "play"
	end
	return "over"
end

function UIRoot._apply_screen(self)
	local ctx = self.ctx
	self._apply_pending = false
	local scr = self:_compute_screen()
	local prev = self._screen
	self._screen = scr
	local changed = scr ~= prev
	local in_game = scr ~= "title"
	local alive = ctx:alive_player()
	if changed then
		self.radial:close(false)
		self.tooltip:hide_tip()
		self.target_card:hide_card()
		self.interact:cancel_aim(false)
		self.screen_changed:Fire(scr)
		-- back on the title from the tutorial's match: it is over
		if scr == "title" and self.tutorial ~= nil and self.tutorial.active then
			self.tutorial:stop("left")
		end
	end
	if scr == "title" then
		-- Queued for multiplayer: mode is already MULTI but no match state yet, so keep the
		-- cinematic title globe.
		ctx:world_call("set_attract_mode", { true })
	end
	-- Title
	local title = self.title
	if scr == "title" then
		if changed or not title.visible then
			title:set_visible(true)
			title:on_show()
			self.telemetry:title_shown()
		end
		-- (the settings page may stand open over the title; the game menu goes when the title comes)
		if self.pause.is_open and (changed or self.pause:page() ~= "settings") then
			self.pause:close()
		end
		if self.over.is_open then
			self.over:close()
		end
	elseif title.visible and changed then
		title:hide_animated()
	end
	-- Territory labels stay off over the cinematic title globe.
	ctx:world_call("set_labels_visible", { self.labels_on and in_game })
	-- HUD
	self.hud:set_visible(in_game)
	self.spawn:set_visible(scr == "spawn")
	self.top:set_visible(scr == "play" or scr == "over")
	self.bar:set_visible(scr == "play" and alive)
	self.spectate_pill:set_visible(in_game and scr ~= "spawn" and not alive and not self.over.is_open)
	self.board:set_visible(in_game and scr ~= "spawn")
	self.feed:set_visible(in_game and not self.over.is_open)
	self.attacks:set_visible(scr == "play")
	self.coach:set_visible((scr == "play" or scr == "spawn") and not self.over.is_open)
	self.interact.enabled = scr == "spawn" or scr == "play"
	self:_layout()
	W.defer(function()
		self:_layout()
	end)
	if changed then
		if scr == "spawn" then
			self.spawn:on_show()
			self.advisor:spawn_view()
		elseif scr == "play" then
			if prev == "spawn" or prev == "title" then
				W.slide_in(self.bar.panel, Vector2.new(0, 60), 0.1, 0.55)
				W.slide_in(self.top.panel, Vector2.new(0, -40), 0.2, 0.5)
				W.slide_in(
					if self.board.expanded then self.board.panel else self.board._pill,
					Vector2.new(40, 0),
					0.25,
					0.5
				)
			end
			self.bar:refresh(false)
			self.board:refresh()
			self.top:refresh()
		end
	end
	self:_play_music(scr)
	if scr == "over" and not self.over.is_open and not self._stats.over and ctx.state ~= nil then
		self.advisor:on_game_over(ctx.state.winner, ctx.state.over_reason)
	end
	self:_update_input_gate()
	self:_hook_buttons(self.root)
end

function UIRoot._play_music(self, _scr: string)
	self:_update_music()
end

--- The soundtrack's mood for the moment (MusicMood); polled, and on every screen change.
function UIRoot._update_music(self)
	local ctx = self.ctx
	local st = ctx.state
	local scr = self._screen
	if scr == "" then
		return -- (booting: AudioDirector already opens with the title music)
	end
	local me = if scr ~= "title" and ctx:in_match() then ctx:me() else 0
	local my = if me ~= 0 then ctx:my() else nil
	local mood = self._music:mood({
		screen = scr,
		waiting = ctx:mp_waiting(),
		me = me,
		alive = my == nil or my.alive ~= false,
		winner = if st ~= nil then (tonumber(st.winner) or 0) else 0,
		fighting = scr == "play" and MusicMood.fighting(st, me),
	}, os.clock())
	ctx:set_music_mood(mood)
end

function UIRoot._update_input_gate(self)
	local ctx = self.ctx
	local modal = self.help.is_open
		or self.pause.is_open
		or self.over.is_open
		or self.map_picker.is_open
		or (self.locker ~= nil and self.locker.is_open)
		or (self.flag_shop ~= nil and self.flag_shop.is_open)
		or (self.arsenal ~= nil and self.arsenal.is_open)
		or (self.starter ~= nil and self.starter.is_open)
	ctx:set_world_input(not modal and not self.rotate_card.visible and not self.radial.is_open)
	self.feed:set_visible(self.hud.visible and not self.over.is_open)
	self.coach:set_visible(
		self.hud.visible and (self._screen == "play" or self._screen == "spawn") and not self.over.is_open
	)
	self.interact.enabled = not modal
		and not self.rotate_card.visible
		and (self._screen == "spawn" or self._screen == "play")
	self.spectate_pill:set_visible(
		self.hud.visible and self._screen ~= "spawn" and not ctx:alive_player() and not self.over.is_open
	)
	self._spec_again:set_visible(ctx:mode() == UICtx.MODE_SOLO)
	-- a public match's own server: leaving goes back to a hub (the title with the lobby list)
	self._spec_leave:set_text(if ctx:mode() == UICtx.MODE_MULTI then "Leave" else "Title")
	local killer = self._stats.killer or 0
	if ctx:mode() == UICtx.MODE_MULTI and ctx:me() == 0 and ctx.state ~= nil then
		self._spec_sub:set_text("Watching this match · drag to look around, click a nation")
	elseif self._stats.elim and ctx.state ~= nil then
		self._spec_sub:set_text(
			if killer ~= 0
				then string.format("Conquered by %s · the war goes on without you", ctx.state:owner_name(killer))
				else "Your nation fell · the war goes on without you"
		)
	else
		self._spec_sub:set_text("Drag to look around · click a nation for details")
	end
end

--- Solo freezes the simulation while help or the game menu is open.
function UIRoot._update_pause(self)
	local ctx = self.ctx
	local want = (
		self.help.is_open
		or self.pause.is_open
		or (self.takeover ~= nil and self.takeover:pending())
		or (self.arsenal ~= nil and self.arsenal.is_open)
	)
		and ctx:mode() == UICtx.MODE_SOLO
		and ctx:in_match()
		and ctx.state ~= nil
		and ctx.state.phase ~= Defs.PHASE_OVER
	-- A solo restart is building: the match being replaced stays frozen until the new world swaps in.
	ctx:set_paused(want or (self._restart_pending and ctx:mode() == UICtx.MODE_SOLO))
end

function UIRoot._set_labels(self, on: boolean)
	self.labels_on = on
	self.ctx:set_setting("labels", on)
	self.ctx:world_call("set_labels_visible", { on })
	self.labels_toggled:Fire(on)
end

-- =============================================================================================
-- Layout
-- =============================================================================================

function UIRoot._safe_insets(self): any
	local d = self.debug_insets
	if d.x >= 0.0 then
		return d
	end
	return self.probe:safe_insets()
end

--- Recompute every panel position (viewport, safe area, touch or layout mode changed).
function UIRoot.relayout(self)
	self:_layout()
end

local function insets_equal(a: any, b: any): boolean
	return a.x == b.x and a.y == b.y and a.z == b.z and a.w == b.w
end

function UIRoot._layout(self)
	local root = self.root
	if root == nil then
		return
	end
	local ctx = self.ctx
	local vp = root.vp
	ctx.vp = vp
	ctx:update_origin()
	ctx.insets = self:_safe_insets()
	self._last_vp = vp
	self._last_insets = ctx.insets
	ctx.compact = vp.Y < 560.0 or vp.X < 900.0
	-- Studio: workspace attribute AF_FORCE_COMPACT previews the phone layout on a desktop viewport
	if not ctx.compact and UICtx.IS_ROBLOX and workspace:GetAttribute("AF_FORCE_COMPACT") == true then
		ctx.compact = game:GetService("RunService"):IsStudio()
	end
	-- (and AF_FORCE_DESKTOP the desktop layout on Studio's small game view, squeezed)
	if ctx.compact and UICtx.IS_ROBLOX and workspace:GetAttribute("AF_FORCE_DESKTOP") == true then
		ctx.compact = not game:GetService("RunService"):IsStudio()
	end
	-- (the single-row bar: ten slots, plus the Arsenal's SHOP slot and a slot per unlocked kind)
	ctx.wide = vp.X >= 1420.0 + (if self.bar ~= nil then self.bar:extra_width() else 62.0)
	if self.debug_touch >= 0 then
		ctx.touch = self.debug_touch == 1
	elseif UICtx.IS_ROBLOX and workspace:GetAttribute("AF_FORCE_TOUCH") == true then
		-- Studio: preview the touch HUD (tray, place confirm, …) with the mouse
		ctx.touch = ctx.touch or game:GetService("RunService"):IsStudio()
	end
	ctx.reserved_top_left = self.probe:airship_reserved()
	UITheme.min_font_size = if ctx.touch then 12 else 0
	self.title:apply_layout()
	self.top:apply_layout()
	self.spawn:apply_layout()
	self.bar:apply_layout()
	-- Leaderboard: top-right, dropping below the status pill / spawn banner when they would touch.
	local board_top = 12.0 + ctx.insets.y
	local board_w = if ctx.compact then 250.0 else 300.0
	local board_left = vp.X - 12.0 - ctx.insets.z - board_w
	local blockers = {}
	if self.top.visible then
		table.insert(blockers, self.top.panel)
	end
	if self.spawn.visible then
		table.insert(blockers, self.spawn.panel)
	end
	for _, b in ipairs(blockers) do
		local r = b:get_global_rect()
		if r.Max.X + 12.0 > board_left then
			board_top = math.max(board_top, r.Max.Y + 10.0)
		end
	end
	local board = self.board
	board:apply_layout(board_top)
	-- Phones: when the status pill had to drop below the top bar, the rank pill sits beside it.
	if ctx.compact and self.top.visible and not board.expanded and board._pill ~= nil then
		local tr = self.top.panel:get_global_rect()
		local pill_w = board._pill:get_combined_minimum_size().X
		local min_x = if tr.Min.Y >= ctx.reserved_top_left.Max.Y
			then ctx.insets.x + 8.0
			else ctx.reserved_top_left.Max.X + 8.0
		if tr.Min.X - 8.0 - pill_w >= min_x then
			board:place_pill_left_of(tr)
		end
	end
	local bar = self.bar
	local attacks_top = math.max(board:bottom_edge(), if self.top.visible then self.top:bottom_edge() else 0.0) + 10.0
	attacks_top = attacks_top
	self.attacks.tray_open = bar.tray ~= nil and bar.tray.visible
	self.attacks:apply_layout(attacks_top, (if bar.visible then bar:top_edge() else vp.Y - ctx.insets.w) - 8.0)
	self.attacks:refresh()
	self.notices:apply_layout_top(
		if self._screen ~= "title" then ctx.insets.y + (if ctx.compact then 70.0 else 96.0) else ctx.insets.y + 12.0
	)
	self.coach:apply_layout()
	self.tutorial:apply_layout()
	-- the territory notice sits top-left under the top bar, below panels reaching that corner
	self.globe_notice:apply_layout({ self.top.panel, self.spawn.panel, self.title._head })
	local bar_top = if bar.visible then bar:top_edge() else vp.Y - ctx.insets.w
	local sp = self.spectate_pill
	if sp.visible then
		bar_top = math.min(bar_top, vp.Y - ctx.insets.w - 12.0 - sp:get_combined_minimum_size().Y)
	end
	self.feed:apply_layout(bar_top - 12.0)
	self:_layout_alert()
	local sb = 14.0 + ctx.insets.w
	sp.anchor_left, sp.anchor_right, sp.anchor_top, sp.anchor_bottom = 0.5, 0.5, 1.0, 1.0
	sp.grow_horizontal = W.GROW_BOTH
	sp.grow_vertical = W.GROW_BEGIN
	sp.offset_top = -sb
	sp.offset_bottom = -sb
	sp.offset_left = 0
	sp.offset_right = 0
	UITheme.fix_width(self._spec_sub, if ctx.compact then 250.0 else 330.0, W.ALIGN_LEFT, false)
	sp:reset_size()
	self.help:apply_layout()
	self.pause:apply_layout()
	self.map_picker:apply_layout()
	if self.locker ~= nil and self.locker.is_open then
		self.locker:apply_layout()
	end
	if self.flag_shop ~= nil and self.flag_shop.is_open then
		self.flag_shop:apply_layout()
	end
	if self.arsenal ~= nil and self.arsenal.is_open then
		self.arsenal:apply_layout()
	end
	if self.starter ~= nil and self.starter.is_open then
		self.starter:apply_layout()
	end
	if self.crate_opening ~= nil then
		self.crate_opening:apply_layout()
	end
	if self.over.is_open then
		self.over:apply_layout()
	end
	if UITheme.min_font_size > 0 then
		self.probe:enforce_min_font(root)
	end
	self.rotate_card:refresh()
	ctx:fit_canvas(self.radial.gui)
	self.probe:update_world_safe_area()
	ctx.layout_changed:Fire()
end

function UIRoot.relayout_alert(self)
	self:_layout_alert()
end

function UIRoot._layout_alert(self)
	local ctx = self.ctx
	if ctx.compact then
		-- Phones: the alert temporarily takes over the status pill's slot (top-right).
		self.alert:apply_layout(self.top.panel.offset_top, 8.0 + ctx.insets.z)
		return
	end
	local y = 12.0 + ctx.insets.y
	if self.top.visible then
		y = self.top:bottom_edge() + 10.0
	elseif self.spawn.visible then
		y = self.spawn:bottom_edge() + 10.0
	end
	self.alert:apply_layout(y)
end

-- =============================================================================================
-- Frame
-- =============================================================================================

local function call_update(comp: any, delta: number)
	comp:update(delta)
end

local function process_interact(self, delta: number)
	self.interact:process_frame(delta)
end

local function update_radial(self, delta: number)
	self.radial:update(delta)
	-- the hold ring follows a finger held on the map (touch only)
	local ctx = self.ctx
	local w = ctx.world
	local inp = if w ~= nil then w.input else nil
	if ctx.touch and inp ~= nil and type(inp.hold_state) == "function" and not self.radial.is_open then
		local pos, k = inp:hold_state()
		self.hold_ring:set(if pos ~= nil then ctx:to_logical(pos) else nil, k)
	else
		self.hold_ring:set(nil, 0)
	end
end

local function slow_poll(self)
	local ctx = self.ctx
	-- A build that ended without a new world (failed, or the Core was missing): don't leave the
	-- "Deploying…" chip up or the old solo match frozen.
	if self._building and ctx:session_call("is_building") == false then
		self:_end_building()
		self:_update_pause()
	end
	self:_poll_layout()
	self:_update_music()
end

local function tips_and_threats(self)
	self.advisor:check_threats()
	self.advisor:check_tips()
	self.advisor:flush_volleys()
end

local function telemetry_tick(self)
	self.telemetry:tick()
end

--- Per-frame UI work. Each unit runs under W.guard (one failing component is reported once per
--- distinct error and never stops the others, nor the kit step that follows).
function UIRoot._process(self, delta: number)
	local ctx = self.ctx
	local guard = W.guard
	if self._rebind_refresh_in ~= nil or self._rebind_apply_in ~= nil then
		guard("UIRoot rebind", rebind_step, self)
	end
	guard("UIInteract.process_frame", process_interact, self, delta)
	guard("RadialMenu.update", update_radial, self, delta)
	local comps = self._frame_comps
	if comps == nil then
		comps = {}
		for _, key in ipairs({ "bar", "top", "board", "feed", "notices", "attacks", "alert" }) do
			local comp = self[key]
			if comp ~= nil and comp.update then
				table.insert(comps, { comp, key .. ".update" })
			end
		end
		self._frame_comps = comps
	end
	for i = 1, #comps do
		local e = comps[i]
		guard(e[2], call_update, e[1], delta)
	end
	self._poll += delta
	if self._poll >= 0.5 then
		self._poll = 0.0
		guard("UIRoot poll", slow_poll, self)
	end
	-- The radial menu takes the globe's input while it is open (GDScript: its full-rect STOP).
	local want_world = not (
		self.help.is_open
		or self.pause.is_open
		or self.over.is_open
		or self.rotate_card.visible
		or self.radial.is_open
	)
	if want_world ~= self._world_input then
		self._world_input = want_world
		ctx:set_world_input(want_world)
	end
	-- Tips step aside while the player is placing something or using the radial menu.
	local coach = self.coach
	local target = if self.radial.is_open or self.interact.aim_kind ~= "" then 0.0 else 1.0
	local a = Defs.move_toward(coach.modulate_a, target, delta * 6.0)
	if a ~= coach.modulate_a then
		coach:set_modulate_a(a)
	end
	self.telemetry:frame(delta)
	if self._hop ~= nil and UICtx.msec() > self._hop.deadline then
		guard("UIRoot hop", self._hop_fallback, self)
	end
	if self._autostart ~= nil then
		guard("UIRoot autostart", self._autostart_step, self)
	end
	if self._tutorial_at ~= nil then
		guard("UIRoot tutorial", self._tutorial_step, self)
	end
	if self.arsenal ~= nil and self.arsenal.is_open then
		guard("Arsenal.frame", self.arsenal.frame, self.arsenal, delta)
	end
	self._threat_poll += delta
	if self._threat_poll >= 1.0 then
		self._threat_poll = 0.0
		guard("UIAdvisor checks", tips_and_threats, self)
		guard("Telemetry.tick", telemetry_tick, self)
		if self.takeover ~= nil then
			guard("Takeover.tick", self.takeover.tick, self.takeover)
		end
		if self.locker ~= nil and self.locker.is_open then
			guard("Locker.tick", self.locker.tick, self.locker)
		end
		if self.flag_shop ~= nil then
			guard("FlagShop.tick", self.flag_shop.tick, self.flag_shop)
		end
		if self.arsenal ~= nil and self.arsenal.is_open then
			guard("Arsenal.tick", self.arsenal.tick, self.arsenal)
		end
		guard("UIRoot starter", self._starter_auto, self)
	end
end

--- Twice a second: re-layout on viewport / safe-area changes, keep cross-panel positions current.
function UIRoot._poll_layout(self)
	local ctx = self.ctx
	local vp = self.root.vp
	if
		vp ~= self._last_vp
		or not insets_equal(self:_safe_insets(), self._last_insets)
		or self.probe:airship_bar_moved()
	then
		self:_layout()
	elseif self.hud.visible then
		-- Cross-panel positions (feed above the bar, alert under the status) follow content size.
		local bar = self.bar
		local bar_top = if bar.visible then bar:top_edge() else vp.Y - ctx.insets.w
		self.feed:apply_layout(bar_top - 12.0)
		self.attacks.tray_open = bar.tray ~= nil and bar.tray.visible
		self.attacks:apply_layout(
			math.max(self.board:bottom_edge(), if self.top.visible then self.top:bottom_edge() else 0.0) + 10.0,
			(if bar.visible then bar:top_edge() else vp.Y - ctx.insets.w) - 8.0
		)
		self:_layout_alert()
		self.probe:update_world_safe_area()
	end
	self:_hook_buttons(self.root)
end

--- UI CPU cost per frame in ms since the last call: {process, kit, total, max, frames}.
function UIRoot.perf_stats(self): { [string]: number }
	local p = self._perf
	if p == nil or p.frames == 0 then
		return { process = 0, kit = 0, total = 0, max = 0, frames = 0 }
	end
	local n = p.frames
	local out = {
		process = p.process / n * 1000,
		kit = p.kit / n * 1000,
		total = (p.process + p.kit) / n * 1000,
		max = p.max * 1000,
		frames = n,
	}
	p.frames, p.process, p.kit, p.max = 0, 0.0, 0.0, 0.0
	return out
end

--- Tear down (tests): disconnect everything and free the GUI.
function UIRoot.destroy(self)
	if UICtx.IS_ROBLOX and self._step_name then
		game:GetService("RunService"):UnbindFromRenderStep(self._step_name)
	end
	for _, c in ipairs(self._sconns) do
		c:Disconnect()
	end
	for _, c in ipairs(self._conns_state or {}) do
		c:Disconnect()
	end
	for _, c in ipairs(self._conns) do
		c:Disconnect()
	end
	self.interact:destroy()
	self.touch_router:destroy()
	self.root:destroy()
	self.gui:Destroy()
	self.ctx.rules = nil
	self.ctx.state = nil
	self.ctx.coach = nil
	self.ctx.tooltip = nil
end

return UIRoot
