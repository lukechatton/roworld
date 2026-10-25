--!nonstrict
-- The party on the title screen (server/Party; team games on: Rofront Staging only for now). Who is
-- in it (the leader picks the public match and everyone goes with them; a team game puts them on one
-- team), the invites to answer, and an invite list: the players on this server, and a Roblox invite
-- for friends elsewhere (accepting it brings them to this server).
--   PartyPanel.new(ctx) · set_state(state) · apply_layout() · on_action = function(action, user_id?)
-- Phones: a PARTY button that opens and closes the panel.

local Players = game:GetService("Players")
local SocialService = game:GetService("SocialService")
local UITheme = require("./UITheme")
local W = require("./Widgets")
local GlassPanel = require("./GlassPanel")
local Scroll = (require("./HelpOverlay") :: any).Scroll

local PartyPanel = W.class(W.Control)

PartyPanel.WIDTH = 250.0
--- An invite button shows SENT this long.
PartyPanel.SENT_S = 3.0
--- The invite list's rows (px) and what the list leaves of the screen's height for its head, the Roblox
--- invite and the padding: the rows scroll in the rest (a full server is 30+ players; 2026-10-10: the
--- party invite menu overflowed and did not scroll).
PartyPanel.ROW_H = 34.0
PartyPanel.ROW_GAP = 6.0
PartyPanel.LIST_CHROME = 190.0
PartyPanel.LIST_CHROME_COMPACT = 165.0
--- Dev only (Dev/SessionDiag "party fake"): stand-ins for the server's players, to see a full list.
PartyPanel.fake_players = nil :: { any }?

function PartyPanel.new(c: any)
	local self = setmetatable({}, PartyPanel.__mt)
	W.Control._init(self)
	local T = UITheme
	self.ctx = c
	self.state = nil
	self.on_action = nil
	self._open = false
	self._sent = {}
	self:set_mouse_filter(W.MOUSE_IGNORE)
	self:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)

	-- the panel
	local p = GlassPanel.new(14.0, 12.0, 14, true, 24)
	self._panel = p
	self:add_child(p)
	local v = T.vbox(8)
	p:add_child(v)
	local head = T.hbox(8)
	local ic = T.icon_rect("users", 18.0, T.CYAN)
	ic.size_flags_vertical = W.SHRINK_CENTER
	head:add_child(ic)
	local title = T.label("PARTY", 14, 800, T.TEXT, 2)
	title.size_flags_horizontal = W.EXPAND_FILL
	title.size_flags_vertical = W.SHRINK_CENTER
	head:add_child(title)
	self._count = T.label("", 12, 600, T.TEXT_2)
	self._count.size_flags_vertical = W.SHRINK_CENTER
	head:add_child(self._count)
	v:add_child(head)
	self._members = T.vbox(4)
	v:add_child(self._members)
	self._invites = T.vbox(6)
	v:add_child(self._invites)
	self._hint = T.label("", 11, 500, T.TEXT_2)
	self._hint:set_autowrap(true)
	self._hint:set_min_size(Vector2.new(PartyPanel.WIDTH - 28, 0))
	v:add_child(self._hint)
	local btns = T.hbox(8)
	self._invite_btn = T.button("INVITE", "GlassButton", "users", 36.0)
	self._invite_btn:set_font_size(12)
	self._invite_btn:add_theme_constant_override("icon_max_width", 14)
	self._invite_btn.size_flags_horizontal = W.EXPAND_FILL
	self._invite_btn.pressed:Connect(function()
		self:open_list()
	end)
	btns:add_child(self._invite_btn)
	self._leave_btn = T.button("LEAVE", "GhostButton", "exit", 36.0)
	self._leave_btn:set_font_size(12)
	self._leave_btn:add_theme_constant_override("icon_max_width", 14)
	self._leave_btn.pressed:Connect(function()
		self:_act("leave")
	end)
	btns:add_child(self._leave_btn)
	v:add_child(btns)

	-- phones: the button that opens / closes the panel
	self._pill = T.button("PARTY", "GlassButton", "users", 40.0)
	self._pill:set_font_size(12)
	self._pill:add_theme_constant_override("icon_max_width", 16)
	self._pill.pressed:Connect(function()
		self._open = not self._open
		self:apply_layout()
	end)
	self:add_child(self._pill)

	-- the invite list
	local lp = GlassPanel.new(16.0, 14.0, 16, true, 40)
	self._list = lp
	self:add_child(lp)
	local lv = T.vbox(10)
	lp:add_child(lv)
	local lh = T.hbox(10)
	local lic = T.icon_rect("users", 20.0, T.CYAN)
	lic.size_flags_vertical = W.SHRINK_CENTER
	lh:add_child(lic)
	local lt = T.label("INVITE TO PARTY", 16, 800, T.TEXT, 2)
	lt.size_flags_horizontal = W.EXPAND_FILL
	lt.size_flags_vertical = W.SHRINK_CENTER
	lh:add_child(lt)
	local close = T.button("", "GhostButton", "close", 40.0)
	close.expand_icon = true
	close.icon_alignment = W.ALIGN_CENTER
	close:add_theme_constant_override("icon_max_width", 14)
	close:set_min_size(Vector2.new(40, 40))
	close.pressed:Connect(function()
		self:close_list()
	end)
	lh:add_child(close)
	lv:add_child(lh)
	self._roblox_btn = T.button("INVITE ROBLOX FRIENDS", "PrimaryButton", "users", 42.0)
	self._roblox_btn:set_font_size(13)
	self._roblox_btn:add_theme_constant_override("icon_max_width", 16)
	self._roblox_btn.pressed:Connect(function()
		-- (a friend who accepts lands on this server, where the party can take them in)
		pcall(function()
			SocialService:PromptGameInvite(Players.LocalPlayer)
		end)
	end)
	lv:add_child(self._roblox_btn)
	local note = T.label("Friends who accept join you on this server.", 11, 500, T.TEXT_3)
	note:set_alignment(W.ALIGN_CENTER)
	self._note = note
	lv:add_child(note)
	self._list_caption = T.caption("On this server", 11, T.TEXT_2)
	lv:add_child(self._list_caption)
	self._list_empty = T.label("Nobody else is on this server yet.", 12, 500, T.TEXT_2)
	lv:add_child(self._list_empty)
	-- the players scroll once they no longer fit on screen (friends first)
	self._list_scroll = Scroll.new()
	self._list_rows = T.vbox(PartyPanel.ROW_GAP)
	self._list_rows.size_flags_horizontal = W.EXPAND_FILL
	local inner = T.hbox(0)
	inner:add_child(self._list_rows)
	-- (room for the scroll bar on the right)
	local gutter = W.Control.new()
	gutter:set_mouse_filter(W.MOUSE_IGNORE)
	gutter:set_min_size(Vector2.new(10, 0))
	inner:add_child(gutter)
	self._list_scroll:add_child(inner)
	lv:add_child(self._list_scroll)
	--- user id → whether the local player is friends with them (asked once each, in the background)
	self._friends = {} :: { [number]: boolean }
	self._asking = {} :: { [number]: boolean }
	lp:set_visible(false)

	self._conns = {
		Players.PlayerAdded:Connect(function()
			if self._list.visible then
				self:_refresh_list()
			end
		end),
		Players.PlayerRemoving:Connect(function()
			if self._list.visible then
				task.defer(function()
					self:_refresh_list()
				end)
			end
		end),
	}
	self:set_visible(false)
	return self
end

function PartyPanel._act(self, action: string, user_id: number?)
	if self.on_action ~= nil then
		self.on_action(action, user_id)
	end
	self.ctx:sfx("click")
end

local function clear(box)
	for _, ch in ipairs(box:get_children()) do
		box:remove_child(ch)
		ch:queue_free()
	end
end

--- The party as the server sees it (server/Party.state), or nil (parties off: hidden).
function PartyPanel.set_state(self, st: any)
	self.state = st
	self:set_visible(st ~= nil)
	if st == nil then
		return
	end
	local T = UITheme
	local me = Players.LocalPlayer.UserId
	local members = if type(st.members) == "table" then st.members else {}
	local leader = st.leader == true
	clear(self._members)
	for _, m in members do
		local row = T.hbox(6)
		local crown = T.icon_rect(if m.leader then "crown" else "users", 14.0, if m.leader then T.AMBER else T.TEXT_3)
		crown.size_flags_vertical = W.SHRINK_CENTER
		row:add_child(crown)
		local nm = T.label(tostring(m.name) .. (if m.uid == me then "  (you)" else ""), 13, 600, T.TEXT)
		nm.text_overrun_behavior = W.OVERRUN_ELLIPSIS
		nm.clip_text = true
		nm.size_flags_horizontal = W.EXPAND_FILL
		nm.size_flags_vertical = W.SHRINK_CENTER
		row:add_child(nm)
		if leader and m.uid ~= me then
			local kick = T.button("", "GhostButton", "close", 26.0)
			kick.expand_icon = true
			kick.icon_alignment = W.ALIGN_CENTER
			kick:add_theme_constant_override("icon_max_width", 10)
			kick:set_min_size(Vector2.new(26, 26))
			kick.pressed:Connect(function()
				self:_act("kick", m.uid)
			end)
			row:add_child(kick)
		end
		self._members:add_child(row)
	end
	clear(self._invites)
	for _, inv in if type(st.invites) == "table" then st.invites else {} do
		local box = T.vbox(4)
		local who = T.label(tostring(inv.name) .. " invited you", 12, 600, T.CYAN)
		who.text_overrun_behavior = W.OVERRUN_ELLIPSIS
		who.clip_text = true
		box:add_child(who)
		local row = T.hbox(6)
		local yes = T.button("JOIN", "PrimaryButton", "check", 32.0)
		yes:set_font_size(12)
		yes:add_theme_constant_override("icon_max_width", 12)
		yes.size_flags_horizontal = W.EXPAND_FILL
		yes.pressed:Connect(function()
			self:_act("accept", inv.uid)
		end)
		row:add_child(yes)
		local no = T.button("NO", "GhostButton", "close", 32.0)
		no:set_font_size(12)
		no:add_theme_constant_override("icon_max_width", 10)
		no.pressed:Connect(function()
			self:_act("decline", inv.uid)
		end)
		row:add_child(no)
		box:add_child(row)
		self._invites:add_child(box)
	end
	local n = #members
	local max = tonumber(st.max) or 4
	self._count:set_text(if n >= 2 then ("%d / %d"):format(n, max) else "")
	self._leave_btn:set_visible(n >= 2)
	self._invite_btn:set_disabled(n >= max)
	self._hint:set_text(
		if n < 2
			then "Play public matches with friends: in a team game you're on the same team."
			elseif leader then "You pick the match. Your party comes with you."
			else "Your party leader picks the match."
	)
	self._pill:set_text(if n >= 2 then ("PARTY  %d"):format(n) elseif #self._invites:get_children() > 0 then "PARTY  •" else "PARTY")
	if #self._invites:get_children() > 0 then
		-- an invite to answer: phones open the panel
		self._open = true
	end
	if self._list.visible then
		self:_refresh_list()
	end
	self:apply_layout()
end

function PartyPanel.open_list(self)
	-- (phones: the list takes the small panel's place)
	if self.ctx.compact then
		self._open = false
	end
	-- (placed first: the rows' scroll height depends on where the list starts)
	self:apply_layout()
	self._list:set_visible(true)
	self:_refresh_list()
	W.pop_in(self._list, 0.0, 0.94, 0.25)
	self.ctx:sfx("open")
end

function PartyPanel.close_list(self)
	if self._list.visible then
		self._list:set_visible(false)
		self.ctx:sfx("close")
	end
end

--- The players on this server who could be invited (not already in the party).
function PartyPanel._refresh_list(self)
	local T = UITheme
	clear(self._list_rows)
	local inside = {}
	for _, m in if self.state and type(self.state.members) == "table" then self.state.members else {} do
		inside[m.uid] = true
	end
	local me = Players.LocalPlayer
	local shown = 0
	local now = os.clock()
	local list = {}
	for _, p in PartyPanel.fake_players or Players:GetPlayers() do
		if p ~= me and not inside[p.UserId] then
			table.insert(list, p)
			self:_ask_friend(p.UserId)
		end
	end
	local friends = self._friends
	table.sort(list, function(a, b)
		local fa, fb = friends[a.UserId] == true, friends[b.UserId] == true
		if fa ~= fb then
			return fa
		end
		return string.lower(a.DisplayName) < string.lower(b.DisplayName)
	end)
	for _, p in list do
		shown += 1
		local row = T.hbox(8)
		local friend = friends[p.UserId] == true
		local nm = T.label(
			(if p.DisplayName ~= "" then p.DisplayName else p.Name) .. (if friend then "  · friend" else ""),
			13,
			600,
			if friend then T.CYAN else T.TEXT
		)
		nm.text_overrun_behavior = W.OVERRUN_ELLIPSIS
		nm.clip_text = true
		nm.size_flags_horizontal = W.EXPAND_FILL
		nm.size_flags_vertical = W.SHRINK_CENTER
		nm:set_min_size(Vector2.new(150, 0))
		row:add_child(nm)
		local sent = self._sent[p.UserId] ~= nil and now - self._sent[p.UserId] < PartyPanel.SENT_S
		local b = T.button(if sent then "SENT" else "INVITE", if sent then "GhostButton" else "GlassButton", "", 34.0)
		b:set_font_size(12)
		b:set_min_size(Vector2.new(84, 34))
		b:set_disabled(sent)
		local uid = p.UserId
		b.pressed:Connect(function()
			self._sent[uid] = os.clock()
			self:_act("invite", uid)
			self:_refresh_list()
			task.delay(PartyPanel.SENT_S + 0.1, function()
				if self._list.visible then
					self:_refresh_list()
				end
			end)
		end)
		row:add_child(b)
		self._list_rows:add_child(row)
	end
	self._list_empty:set_visible(shown == 0)
	self._list_caption:set_visible(shown > 0)
	-- as tall as the rows, never past the screen
	local ctx = self.ctx
	local rows_h = if shown > 0 then shown * PartyPanel.ROW_H + (shown - 1) * PartyPanel.ROW_GAP else 0.0
	local room = if ctx.vp ~= nil
		then ctx:clear_rect().Max.Y
			- (self._list_top or 60.0)
			- 8.0
			- (if ctx.compact then PartyPanel.LIST_CHROME_COMPACT else PartyPanel.LIST_CHROME)
		else 300.0
	self._list_scroll:set_visible(shown > 0)
	self._list_scroll:set_min_size(Vector2.new(0, math.max(PartyPanel.ROW_H, math.min(rows_h, room))))
	self._list:reset_size()
end

--- Asks once (in the background) whether the local player is friends with `uid`; the list puts friends
--- first once it knows.
function PartyPanel._ask_friend(self, uid: number)
	if self._friends[uid] ~= nil or self._asking[uid] then
		return
	end
	self._asking[uid] = true
	task.spawn(function()
		local ok, yes = pcall(function()
			return Players.LocalPlayer:IsFriendsWith(uid)
		end)
		self._asking[uid] = nil
		self._friends[uid] = ok and yes == true
		if ok and yes == true and self._list.visible and not self._resort then
			-- (one re-sort for a burst of answers)
			self._resort = true
			task.delay(0.3, function()
				self._resort = false
				if self._list.visible then
					self:_refresh_list()
				end
			end)
		end
	end)
end

function PartyPanel.apply_layout(self)
	local ctx = self.ctx
	if ctx.vp == nil then
		return
	end
	local compact = ctx.compact
	local p, pill = self._panel, self._pill
	local x = 12.0 + ctx.insets.x
	p:set_min_size(Vector2.new(PartyPanel.WIDTH, 0))
	pill:set_visible(compact)
	if compact then
		-- phones: the PARTY button under the top bar on the left; the panel under it while open
		local y = math.max(ctx.reserved_top_left.Max.Y, 44.0) + 6.0 + ctx.insets.y
		pill:set_anchors(0, 0, 0, 0)
		pill:set_offsets(x, y, x + 120, y + 40)
		p:set_visible(self._open)
		p.anchor_left, p.anchor_right, p.anchor_top, p.anchor_bottom = 0, 0, 0, 0
		p.grow_horizontal = W.GROW_END
		p.grow_vertical = W.GROW_END
		p.offset_left, p.offset_right = x, x
		p.offset_top, p.offset_bottom = y + 46, y + 46
	else
		-- desktop: on the left, halfway down
		p:set_visible(true)
		p.anchor_left, p.anchor_right, p.anchor_top, p.anchor_bottom = 0, 0, 0.5, 0.5
		p.grow_horizontal = W.GROW_END
		p.grow_vertical = W.GROW_BOTH
		p.offset_left, p.offset_right = x + 4.0, x + 4.0
		p.offset_top, p.offset_bottom = 0, 0
	end
	p:reset_size()
	-- the invite list: under the top bar row (its buttons draw above our layer), growing down, its rows
	-- scrolling in what the screen leaves (_refresh_list)
	local lp = self._list
	local clear = ctx:clear_rect()
	local top = math.max(clear.Min.Y + 8.0, if compact then 0.0 else ctx.vp.Y * 0.1)
	self._list_top = top
	-- (phones: no note line and a shorter button, so more rows fit)
	self._note:set_visible(not compact)
	self._roblox_btn:set_min_size(Vector2.new(0, if compact then 36 else 42))
	lp:set_min_size(Vector2.new(if compact then math.min(360, ctx.vp.X - 24) else 380, 0))
	lp.anchor_left, lp.anchor_right, lp.anchor_top, lp.anchor_bottom = 0.5, 0.5, 0, 0
	lp.grow_horizontal = W.GROW_BOTH
	lp.grow_vertical = W.GROW_END
	lp.offset_left, lp.offset_right, lp.offset_top, lp.offset_bottom = 0, 0, top, top
	lp:reset_size()
	if lp.visible then
		-- (the screen changed: the rows' room too)
		self:_refresh_list()
	end
end

function PartyPanel.destroy_conns(self)
	for _, c in self._conns do
		c:Disconnect()
	end
end

return PartyPanel
