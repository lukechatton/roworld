-- polish-fixer: round-2 polish logic that runs headless (UITheme kerning + glyph pens, UIRules copy).
-- Run: .bin/lune run tests/polishfix_ui.luau
require("./prelude")
local T = require("../src/client/UI/UITheme")
local UIRules = require("../src/client/UI/UIRules")
local Rules = require("../src/shared/Core/Rules")

local failures = 0
local function check(cond: boolean, what: string)
	if cond then
		print("  ok   " .. what)
	else
		failures += 1
		print("FAIL " .. what)
	end
end
local function near(a: number, b: number, eps: number?): boolean
	return math.abs(a - b) <= (eps or 1e-6)
end

-- 1. Rubik pair kerning (tools/uikit/make_kern.py): letter-spaced text is shaped like HarfBuzz did it
check(T.kern(string.byte("L"), string.byte("T"), 800) == -102, "kern L|T at 800 = -102 em/1000")
check(T.kern(string.byte("A"), string.byte("Y"), 800) < -50, "kern A|Y at 800 is strongly negative")
check(T.kern(string.byte("l"), string.byte("a"), 600) == 0, "no kern l|a (the Relaxed gap was pixel snapping)")
check(T.kern(string.byte("L"), string.byte("T"), 820) == -102, "weights snap to the nearest 100")
check(T.kern(0x2022, string.byte("T"), 800) == 0, "non-ASCII pairs: no kerning")
do
	local ts = 100
	local em = ts / T.LINE_EM
	local xs, total = T.glyph_positions("LT", ts, 800)
	local adv_l = T.char_adv_px("L", ts, 800, false)
	local adv_t = T.char_adv_px("T", ts, 800, false)
	check(near(xs[1], 0), "pen of L at 0")
	check(near(xs[2], adv_l - 0.102 * em, 1e-4), "pen of T pulled in by the L|T pair")
	check(near(total, adv_l + adv_t - 0.102 * em, 1e-4), "total advance includes the kerning")
	local xs2 = T.glyph_positions("Relaxed", 18, 600)
	local mono = true
	for i = 2, #xs2 do
		mono = mono and xs2[i] > xs2[i - 1]
	end
	check(mono and #xs2 == 7, "pens increase monotonically, one per glyph")
	check(xs2[4] ~= math.floor(xs2[4]), "pens stay fractional (the renderer places them exactly)")
end
do
	-- letter-spaced measure = advances + kerning + spacing after every glyph (what the renderer draws)
	local w_kern = T.measure_text("MULTIPLAYER", 15, 800, 2)
	local em15 = 15 / 1000
	local adv = 0
	for _, cp in utf8.codes("MULTIPLAYER") do
		adv += T.char_adv_px(utf8.char(cp), 100, 800, false) * T.LINE_EM / 100 * 1000
	end
	local plain = adv * em15 + 2 * 11
	check(w_kern < plain, string.format("MULTIPLAYER measures %d < %.2f without kerning", w_kern, plain))
	check(T.text_width("TROOPS", 11, 700) == 45, "tabular templates keep their widths (no kerning)")
end

-- 2. MIRV copy: the cap, not a promise (review R2-7)
check(
	UIRules.blast_text("mirv") == string.format("Up to %d warheads across the target nation", Rules.MIRV_WARHEADS),
	"MIRV aim row: " .. UIRules.blast_text("mirv")
)
local desc = UIRules.blurb("mirv")
check(string.find(desc, "up to " .. Rules.MIRV_WARHEADS, 1, true) ~= nil, "MIRV blurb says up to: " .. desc)

-- 3. victory copy uses the victory metric (review R2-4)
check(UIRules.win_phrase(0.774, 0.774, 0, " of all land") == "77.4% of all land", "no fallout: the original copy")
check(
	UIRules.win_phrase(0.801, 0.774, 12000, " of all land") == "80.1% of the land outside fallout",
	"fallout: the metric the goal uses, said so"
)
check(UIRules.win_phrase(0.8, 0.8, 3, "") == "80.0%", "fallout too small to show: plain number")

-- 4. result clock (review R2-6)
check(
	UIRules.result_seconds("result", { duration_s = 143, match_s = 720 }) == 720,
	"result after elimination: match length"
)
check(UIRules.result_seconds("eliminated", { duration_s = 143, match_s = 720 }) == 143, "ELIMINATED: when you fell")
check(UIRules.result_seconds("victory", { duration_s = 1161 }) == 1161, "no match_s recorded: duration_s")

if failures > 0 then
	error(string.format("%d check(s) failed", failures))
end
print("polishfix_ui: all checks passed")
