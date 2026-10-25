--!nocheck
-- The phone tray's widths (client/UI/TrayFit): the build slots and the gold SHOP button, wider than
-- a slot while there is anything left to get. Run: .bin/lune run tests/tray_fit.luau
require("./prelude")
local TrayFit = require("../src/client/UI/TrayFit")

local fails = 0
local function expect(c: any, w: string)
	if c then
		print("  ok   " .. w)
	else
		fails += 1
		print("FAIL " .. w)
	end
end

expect(TrayFit.shop_width(0) == 0, "nothing left to get: no width asked")
expect(TrayFit.shop_width(8) == 72 and TrayFit.shop_width(1) == 72, "anything left: the button is 72 wide")

-- what the row needs, as CommandBar lays it out
local function need(f: any, slots: number): number
	return slots * (f.slot_w + f.sep) + f.shop_w + f.sep + TrayFit.CHROME
end

-- nothing locked: the row of before the cards (ten slots and a SHOP slot the width of a slot)
do
	local f = TrayFit.fit(1000, 10, 0)
	expect(f.slot_w == 60 and f.sep == 8 and f.shop_w == 60 and not f.two_rows, "room for all: full slots")
	f = TrayFit.fit(733, 10, 0)
	expect(f.slot_w == 58 and f.sep == 5 and f.shop_w == 58 and not f.two_rows, "an iPhone's 733: slots of 58")
	f = TrayFit.fit(682, 10, 0)
	expect(f.slot_w == 54 and not f.two_rows, "682: the narrowest slots still fit")
	f = TrayFit.fit(681, 10, 0)
	expect(f.two_rows and f.slot_w == 60 and f.sep == 8, "681: two rows, full slots again")
end

-- items left to get: the SHOP button is wider, the slots give it the room
do
	local f = TrayFit.fit(1000, 10, 8)
	expect(f.shop_w == 72 and f.slot_w == 60 and not f.two_rows, "room for all: the button at its width")
	f = TrayFit.fit(733, 10, 8)
	expect(f.shop_w == 72 and f.slot_w == 57 and not f.two_rows, "an iPhone's 733: slots of 57, the button whole")
	expect(need(f, 10) <= 733, "  and it fits")
	-- narrower: the slots are at their minimum and the button gives way
	f = TrayFit.fit(690, 10, 8)
	expect(f.slot_w == 54 and f.shop_w < 72 and f.shop_w >= 54 and not f.two_rows, "690: the SHOP button narrows")
	expect(need(f, 10) <= 690, "  and it fits")
	-- never a second row where the plain SHOP slot had one
	for avail = 682, 760 do
		local g = TrayFit.fit(avail, 10, 8)
		if g.two_rows or need(g, 10) > avail or g.shop_w < g.slot_w then
			expect(false, "one row at " .. avail)
		end
	end
	expect(not TrayFit.fit(682, 10, 8).two_rows, "682..760: one row, as with a plain slot")
	expect(TrayFit.fit(682, 10, 8).shop_w == 54, "682: the SHOP button is one slot wide")
	f = TrayFit.fit(681, 10, 8)
	expect(f.two_rows and f.shop_w == 72, "681: two rows, and the button whole on the second")
end

-- unlocked kinds take slots
do
	local f = TrayFit.fit(733, 12, 4)
	expect(f.two_rows, "two more slots on an iPhone: two rows (as with a plain slot)")
	expect(TrayFit.fit(733, 12, 0).two_rows, "  the same with nothing left to get")
	f = TrayFit.fit(1100, 12, 4)
	expect(f.shop_w == 72 and not f.two_rows, "a tablet: the button whole")
	f = TrayFit.fit(1100, 12, 0)
	expect(f.shop_w == 60, "everything got: a slot's width")
end

if fails > 0 then
	error(fails .. " tray fit checks failed")
end
print("tray_fit: all ok")
