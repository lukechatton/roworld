--!strict
-- Widths in the build row (CommandBar): its slots, and the gold SHOP button that closes it (ShopSlot),
-- a little wider than a slot while there is anything left to get. The row must stay one row wherever
-- it can (2026-10-04: the build menu was too big; only the SHOP button shows, so it all stays on
-- one row), so on a phone the slots narrow first, then the SHOP button narrows to one slot's width,
-- and only then does the tray take a second row.
--
-- Numbers only (no widgets): tests/tray_fit.luau.
local TrayFit = {}

--- A phone tray slot: its usual width, and the narrowest it gets.
TrayFit.SLOT_MAX = 60.0
TrayFit.SLOT_MIN = 54.0
--- Gap between slots: the usual one, and the one of a tight row.
TrayFit.SEP = 8.0
TrayFit.SEP_TIGHT = 5.0
--- What a row holds besides its slots: the divider before the nukes and the tray's padding.
TrayFit.CHROME = 33.0
--- The SHOP button's width while there is anything left to get (2026-10-12: one button, where it
--- held a card for each locked unit; it is wider than a slot so it stands out).
TrayFit.SHOP_W = 72.0

--- The width the SHOP button wants with `n` items left to get (0: none, a slot's width will do).
function TrayFit.shop_width(n: number): number
	return if n > 0 then TrayFit.SHOP_W else 0.0
end

--- The phone tray. `avail`: the width between the safe edges; `slots`: the build slots besides SHOP
--- (the ten everyone has and the unlocked Arsenal kinds); `locked`: the Arsenal items left to get.
--- Returns { slot_w, sep, shop_w, two_rows }.
function TrayFit.fit(avail: number, slots: number, locked: number): { [string]: any }
	local want = TrayFit.shop_width(locked)
	local function need(slot_w: number, sep: number, shop_w: number): number
		return slots * (slot_w + sep) + shop_w + sep + TrayFit.CHROME
	end
	local slot_w, sep = TrayFit.SLOT_MAX, TrayFit.SEP
	local shop_w = math.max(want, slot_w)
	if need(slot_w, sep, shop_w) <= avail then
		return { slot_w = slot_w, sep = sep, shop_w = shop_w, two_rows = false }
	end
	sep = TrayFit.SEP_TIGHT
	-- the slots narrow, a pixel at a time
	while slot_w > TrayFit.SLOT_MIN and need(slot_w, sep, math.max(want, slot_w)) > avail do
		slot_w -= 1
	end
	shop_w = math.max(want, slot_w)
	if need(slot_w, sep, shop_w) > avail then
		-- then the SHOP slot, to no less than a slot
		shop_w = math.max(slot_w, math.floor(avail - need(slot_w, sep, 0.0)))
	end
	if need(slot_w, sep, shop_w) > avail then
		-- builds over nukes: the second row has the room
		return {
			slot_w = TrayFit.SLOT_MAX,
			sep = TrayFit.SEP,
			shop_w = math.max(want, TrayFit.SLOT_MAX),
			two_rows = true,
		}
	end
	return { slot_w = slot_w, sep = sep, shop_w = shop_w, two_rows = false }
end

return TrayFit
