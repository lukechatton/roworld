--!nonstrict
-- Solo: take over the nation that eliminated you, for 25 Robux (2026-09-28). Offered on the
-- ELIMINATED screen and the spectating pill while the nation that conquered you is still alive.
-- A press pauses the match, then spends a saved credit or opens Roblox's purchase prompt; the server
-- stores the purchase as a credit (server/Purchases), spends it, and the player takes over
-- (Session.take_over: its land, army, gold and buildings, its AI off). A purchase whose moment passed
-- stays saved for the next time a nation conquers the player.
--
-- UIRoot drives it: tick() once a second, on_credits() / on_result() from the session, refresh()
-- when the ELIMINATED screen opens; pending() pauses the solo match.
local UICtx = require("./UICtx")

local Takeover = {}
Takeover.__index = Takeover

Takeover.KIND = "takeover"
--- Seconds to wait for the stored purchase / the spend before giving up (the credit stays saved).
Takeover.CREDIT_WAIT_S = 30
--- Roblox's prompt left open this long without an answer: give up (the match unpauses).
Takeover.PROMPT_WAIT_S = 180

local IS_ROBLOX = typeof(game) == "Instance"
local products_mod: any = nil
local function products(): any
	if products_mod == nil then
		products_mod = {}
		if IS_ROBLOX then
			local ok, m = pcall(function()
				return require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Airfront").Data.Products)
			end)
			if ok and type(m) == "table" then
				products_mod = m
			end
		end
	end
	return products_mod
end

local prices_mod: any = nil
local function Prices(): any
	if prices_mod == nil then
		prices_mod = require("./Prices") :: any
	end
	return prices_mod
end

function Takeover.new(ui: any)
	local self = setmetatable({}, Takeover)
	self.ui = ui
	self.ctx = ui.ctx
	--- { target, phase = "prompt" | "credit" | "using", since }
	self._pending = nil
	--- the match state each milestone was reported for (once per match)
	self._offer_for = nil
	self._click_for = nil
	self._shown_key = ""
	if IS_ROBLOX then
		local mps = game:GetService("MarketplaceService")
		self._conn = mps.PromptProductPurchaseFinished:Connect(
			function(user_id: number, product_id: number, purchased: boolean)
				self:_on_prompt_done(user_id, product_id, purchased)
			end
		)
	end
	return self
end

function Takeover.product_id(self): number
	if self._preview_id ~= nil then
		return self._preview_id -- (dev diagnostics: preview the priced offer before the product exists)
	end
	local p = products()[Takeover.KIND]
	return if type(p) == "table" then (tonumber(p.id) or 0) else 0
end

--- Roblox's price for this player (UI/Prices), the set one until it answers.
function Takeover.price(_self): number
	local p = products()[Takeover.KIND]
	if type(p) ~= "table" then
		return 25
	end
	Prices().fetch()
	local r = Prices().robux(Takeover.KIND)
	return if r > 0 then r else (tonumber(p.robux) or 25)
end

--- Takeovers bought and not used yet.
function Takeover.saved(self): number
	local s = self.ctx.session
	local c = if s ~= nil then s.credits else nil
	return if type(c) == "table" then (tonumber(c[Takeover.KIND]) or 0) else 0
end

function Takeover.pending(self): boolean
	return self._pending ~= nil
end

--- The nation the player could take over now (0: no offer).
function Takeover.target(self): number
	local ctx = self.ctx
	local m = ctx:mode()
	if (m ~= UICtx.MODE_SOLO and m ~= UICtx.MODE_MULTI) or not ctx:in_match() or ctx.state == nil then
		return 0
	end
	local st = self.ui._stats
	local k = if st ~= nil then (tonumber(st.killer) or 0) else 0
	if st == nil or not st.elim or k == 0 then
		return 0
	end
	if self:product_id() == 0 and self:saved() <= 0 then
		return 0
	end
	local s = ctx.session
	if s == nil or type(s.can_take_over) ~= "function" or not s:can_take_over(k) then
		return 0
	end
	return k
end

function Takeover._report(self, kind: string)
	local t = self.ui.telemetry
	if t ~= nil and type(t._send) == "function" then
		t:_send(kind)
	end
end

function Takeover._notice(self, text: string, severity: number?)
	self.ui:_on_notice(text, severity or 0)
end

--- The TAKE OVER button.
function Takeover.start(self)
	local target = self:target()
	if target == 0 or self._pending ~= nil then
		return
	end
	if self._click_for ~= self.ctx.state then
		self._click_for = self.ctx.state
		self:_report("takeover_click")
	end
	self._pending = { target = target, phase = "", since = os.clock() }
	self.ui:_update_pause()
	if self:saved() > 0 then
		self:_use()
	else
		local id = self:product_id()
		if id == 0 or not IS_ROBLOX then
			self:_cancel(nil)
			return
		end
		self._pending.phase = "prompt"
		local ok = pcall(function()
			local mps = game:GetService("MarketplaceService")
			mps:PromptProductPurchase(game:GetService("Players").LocalPlayer, id)
		end)
		if not ok then
			self:_cancel("Purchases aren't available right now.")
			return
		end
	end
	self:refresh()
end

function Takeover._use(self)
	local p = self._pending
	if p == nil then
		return
	end
	p.phase = "using"
	p.since = os.clock()
	local s = self.ctx.session
	-- (a public match's server makes the takeover itself: it needs the nation)
	local target = if self.ctx:mode() == UICtx.MODE_MULTI then p.target else nil
	if s == nil or not s:use_credit(Takeover.KIND, target) then
		self:_cancel("Couldn't reach the server. Try again in a moment.")
	end
end

function Takeover._cancel(self, message: string?)
	self._pending = nil
	self.ui:_update_pause()
	if message ~= nil then
		self:_notice(message, 0)
	end
	self:refresh()
end

function Takeover._on_prompt_done(self, _user_id: number, product_id: number, purchased: boolean)
	local p = self._pending
	if p == nil or p.phase ~= "prompt" or product_id ~= self:product_id() then
		return
	end
	if not purchased then
		self:_cancel(nil)
		return
	end
	-- bought: the server stores it (a credit) and says so; then it is spent
	p.phase = "credit"
	p.since = os.clock()
	if self:saved() > 0 then
		self:_use()
	end
	self:refresh()
end

--- The session's credits changed (a purchase stored, a credit spent).
function Takeover.on_credits(self)
	local p = self._pending
	if p ~= nil and p.phase == "credit" and self:saved() > 0 then
		self:_use()
	end
	self:refresh()
end

--- The server's answer to use_credit.
function Takeover.on_result(self, kind: string, ok: boolean, reason: string?)
	local p = self._pending
	if kind ~= Takeover.KIND or p == nil or p.phase ~= "using" then
		return
	end
	self._pending = nil
	local s = self.ctx.session
	-- (a takeover that happens goes on in UIRoot._on_took_over, from the session's took_over signal;
	-- a public match's server already made it and said so with OWNER_CHANGED)
	local multi = self.ctx:mode() == UICtx.MODE_MULTI
	local took = ok and (multi or (s ~= nil and s:take_over(p.target)))
	if ok and not took then
		self:_notice("That nation has fallen, so the takeover couldn't happen.", 1)
	elseif not ok and reason == "gone" then
		self:_notice("That nation has fallen. Your takeover is still saved.", 1)
	elseif not ok then
		self:_notice("Couldn't use your takeover right now. It's still saved.", 0)
	end
	self.ui:_update_pause()
	self:refresh()
end

--- Once a second: the offer's first showing (analytics), timeouts, the buttons.
function Takeover.tick(self)
	local p = self._pending
	if p ~= nil then
		local wait = if p.phase == "prompt" then Takeover.PROMPT_WAIT_S else Takeover.CREDIT_WAIT_S
		if os.clock() - p.since > wait then
			self:_cancel(
				if p.phase == "prompt"
					then nil
					else "Your takeover is saved. Use it the next time a nation conquers you."
			)
		end
	end
	if self:target() ~= 0 and self._offer_for ~= self.ctx.state then
		self._offer_for = self.ctx.state
		self:_report("takeover_offer")
	end
	self:refresh()
end

--- Show / update the offer on the ELIMINATED screen and the spectating pill.
function Takeover.refresh(self)
	local target = self:target()
	local info = nil
	if target ~= 0 then
		local st = self.ctx.state
		local o = st:get_owner(target)
		info = {
			target = target,
			name = st:owner_name(target),
			color = if o ~= nil then o.color else nil,
			price = self:price(),
			saved = self:saved(),
			busy = self._pending ~= nil,
		}
	end
	local key = if info == nil
		then ""
		else string.format("%d|%s|%d|%s|%d", info.target, info.name, info.saved, tostring(info.busy), info.price)
	if key == self._shown_key then
		return
	end
	self._shown_key = key
	self.ui.over:set_takeover(info)
	self.ui:_set_spec_takeover(info)
end

return Takeover
