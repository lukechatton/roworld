--!strict
-- The Robux prices the interface shows: Roblox's own for this player (MarketplaceService), never
-- the number in Data/Products once Roblox has answered. With Managed Pricing (dynamic pricing,
-- on since 2026-10-05) a product's price differs by region and while Roblox tests prices, and a
-- button that prints 49 beside a prompt that charges 20 loses the sale. Roblox asks for prices to be
-- read this way before it lets an experience opt in (it looks for hard-coded ones).
--
--   Prices.robux(key)  the price of Data/Products[key]: Roblox's, or the set one until it answers
--   Prices.fetch()     ask Roblox for every product's price (at most once every REFRESH_S), but the
--                      flag shop's (Products' `shop_flag`: dozens, of which the shop shows a few)
--   Prices.fetch_keys(keys)   ask for these products' prices (each at most once every REFRESH_S)
--   Prices.changed     Signal(): a price arrived or moved
local UITheme = require("./UITheme")
local Signal = UITheme.core("Signal")

local IS_ROBLOX = typeof(game) == "Instance"
local Products: any = if IS_ROBLOX
	then require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Airfront").Data.Products)
	else (require :: any)("../../shared/Data/Products")

local Prices = {}

--- A price is asked for again after this long (a price test starts or ends while a server is up).
Prices.REFRESH_S = 600
Prices.changed = Signal.new()

local known: { [string]: number } = {}
local asked_at = -1e9
local asking = false
--- (fetch_keys: when each product was last asked for)
local key_asked: { [string]: number } = {}

function Prices.robux(key: string): number
	local p = Products[key]
	return known[key] or (if type(p) == "table" then tonumber(p.robux) or 0 else 0)
end

--- Roblox's price of product `key` is `robux` (fetch; tests).
function Prices.set(key: string, robux: number)
	if known[key] ~= robux then
		known[key] = robux
		Prices.changed:Fire()
	end
end

function Prices.fetch()
	if not IS_ROBLOX or asking or os.clock() - asked_at < Prices.REFRESH_S then
		return
	end
	asking = true
	task.spawn(function()
		local mps = game:GetService("MarketplaceService")
		local moved = false
		for key, p in Products do
			if type(p) == "table" and (tonumber(p.id) or 0) ~= 0 and p.shop_flag == nil and p.shop_set == nil then
				local ok, info = pcall(function()
					return mps:GetProductInfo(p.id, Enum.InfoType.Product)
				end)
				if ok and type(info) == "table" and type(info.PriceInRobux) == "number" then
					if known[key] ~= info.PriceInRobux then
						known[key] = info.PriceInRobux
						moved = true
					end
				end
			end
		end
		asked_at = os.clock()
		asking = false
		if moved then
			Prices.changed:Fire()
		end
	end)
end

function Prices.fetch_keys(keys: { string })
	if not IS_ROBLOX then
		return
	end
	local want = {}
	for _, key in keys do
		local p = Products[key]
		if
			type(p) == "table"
			and (tonumber(p.id) or 0) ~= 0
			and os.clock() - (key_asked[key] or -1e9) >= Prices.REFRESH_S
		then
			key_asked[key] = os.clock()
			table.insert(want, key)
		end
	end
	if #want == 0 then
		return
	end
	task.spawn(function()
		local mps = game:GetService("MarketplaceService")
		local moved = false
		for _, key in want do
			local ok, info = pcall(function()
				return mps:GetProductInfo(Products[key].id, Enum.InfoType.Product)
			end)
			if
				ok
				and type(info) == "table"
				and type(info.PriceInRobux) == "number"
				and known[key] ~= info.PriceInRobux
			then
				known[key] = info.PriceInRobux
				moved = true
			end
		end
		if moved then
			Prices.changed:Fire()
		end
	end)
end

return Prices
