--!nocheck
-- The Robux prices the interface shows (client/UI/Prices): the set price until Roblox answers, then
-- Roblox's. Run: .bin/lune run tests/prices.luau
require("./prelude")
local Prices = require("../src/client/UI/Prices")
local Products = require("../src/shared/Data/Products")

local fails = 0
local function expect(c: any, w: string)
	if c then
		print("  ok   " .. w)
	else
		fails += 1
		print("FAIL " .. w)
	end
end

for key, p in Products do
	expect(Prices.robux(key) == p.robux, key .. ": the set price before Roblox answers")
end
expect(Prices.robux("no_such_product") == 0, "an unknown product: 0")

local fired = 0
Prices.changed:Connect(function()
	fired += 1
end)
Prices.fetch() -- (outside Roblox: nothing to ask)
expect(fired == 0, "no answer, no change")
Prices.set("crate", 20)
expect(Prices.robux("crate") == 20 and fired == 1, "Roblox's price replaces the set one, and says so")
Prices.set("crate", 20)
expect(fired == 1, "the same price again: no change")
expect(Prices.robux("crate_first") == Products.crate_first.robux, "the other products keep theirs")

if fails > 0 then
	error(fails .. " price checks failed")
end
print("prices: all ok")
