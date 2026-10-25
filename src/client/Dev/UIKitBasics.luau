--!nonstrict
-- ui-kit dev harness: design-system smoke test (glass panels, labels, buttons, spacing, fonts).
local Players = game:GetService("Players")
local UI = script.Parent.Parent:WaitForChild("UI")
local T = require(UI:WaitForChild("UITheme"))
local W = require(UI:WaitForChild("Widgets"))
local GlassPanel = require(UI:WaitForChild("GlassPanel"))

T.init()

local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
local sg = Instance.new("ScreenGui")
sg.Name = "UIKitBasics"
sg.IgnoreGuiInset = true
sg.ScreenInsets = Enum.ScreenInsets.None
sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
sg.ResetOnSpawn = false
sg.Parent = pg

local bg = Instance.new("Frame")
bg.Size = UDim2.fromScale(1, 1)
bg.BackgroundColor3 = Color3.fromRGB(14, 18, 52)
bg.BorderSizePixel = 0
bg.ZIndex = 0
bg.Parent = sg
-- a few coloured blocks behind the panels to judge translucency
for i, c in ipairs({ Color3.fromRGB(31, 175, 130), Color3.fromRGB(230, 90, 200), Color3.fromRGB(240, 180, 40) }) do
	local f = Instance.new("Frame")
	f.BackgroundColor3 = c
	f.BorderSizePixel = 0
	f.Size = UDim2.fromOffset(260, 900)
	f.Position = UDim2.fromOffset(120 + (i - 1) * 420, 0)
	f.Parent = bg
end

local root = W.Root.new(sg, { scale = 1.0 })

local p = GlassPanel.new(18, 12, T.R_LG, true, 22)
p:set_anchors_and_offsets_preset(W.PRESET_TOP_LEFT)
p:set_offsets(40, 40, 40, 40)
root:add_child(p)
local v = T.vbox(8)
p:add_child(v)
v:add_child(T.caption("Troops"))
local row = T.hbox(6)
row:add_child(T.icon_rect("troops", 12, T.TEXT_3))
row:add_child(T.caption("World control"))
local sp = W.Control.new()
sp.size_flags_horizontal = W.EXPAND_FILL
sp:set_mouse_filter(W.MOUSE_IGNORE)
row:add_child(sp)
row:add_child(T.caption("Goal 80%", 11, T.GOLD))
row:set_min_size(Vector2.new(300, 0))
v:add_child(row)
local big = T.label("186K", 20, 700)
v:add_child(big)
local tab = T.label("1.43M", 20, 700, T.GOLD)
T.fix_width(tab, T.text_width("8888.8M", 20, 700) + 2, W.ALIGN_LEFT)
v:add_child(tab)
v:add_child(T.label("Sends 65.4K troops", 11, 500, T.TEXT_3))
v:add_child(T.label("LEADERBOARD", 12, 800, T.TEXT, 2))
local btns = T.hbox(8)
local a = T.button("Accept", "PrimaryButton", "", 34)
a:set_font_size(13)
a.size_flags_horizontal = W.EXPAND_FILL
local d = T.button("Decline", "GlassButton", "", 34)
d:set_font_size(13)
d.size_flags_horizontal = W.EXPAND_FILL
btns:add_child(a)
btns:add_child(d)
v:add_child(btns)
local c2 = T.button("Cancel", "GlassButton", "close", 44)
c2:set_font_size(13)
c2:add_theme_constant_override("icon_max_width", 12)
v:add_child(c2)
v:add_child(T.swatch(T.AMBER, 14, 4))

-- toast-like card with accent
local card = GlassPanel.new(12, 9, T.R_MD, true, 12)
card:set_accent(T.RED)
card:set_offsets(420, 40, 420, 40)
root:add_child(card)
local r2 = T.hbox(10)
card:add_child(r2)
r2:add_child(T.icon_rect("target", 14, T.RED))
local tl = T.label("Belarus (11.4K) is attacking you!", 13, 500)
r2:add_child(tl)

-- pill
local pill = GlassPanel.new(16, 9, 999, true, 18)
pill:set_offsets(420, 140, 420, 140)
root:add_child(pill)
pill:add_child(T.label("Deploying a new world…", 14, 700, T.TEXT, 1))

-- glyph-mode rendering check: plain vs per-glyph (spacing ~0) must look identical
local cmp = GlassPanel.new(16, 9, T.R_MD, true, 12)
cmp:set_offsets(420, 240, 420, 240)
root:add_child(cmp)
local cv = T.vbox(2)
cmp:add_child(cv)
cv:add_child(T.label("Deploying a new world… Wave AV Toy 123", 14, 700))
cv:add_child(T.label("Deploying a new world… Wave AV Toy 123", 14, 700, T.TEXT, 0.0001))
cv:add_child(T.label("Deploying a new world… Wave AV Toy 123", 14, 700, T.TEXT, 1))
local tabl = T.label("1,111.1K 888.8K", 20, 700)
tabl:set_tabular(true)
cv:add_child(tabl)
cv:add_child(T.label("1,111.1K 888.8K", 20, 700))

W.flush()
print("[UIKitBasics] panel rect", p:get_global_rect(), "min", p:get_combined_minimum_size(), "scale", T.scale)
task.delay(0.5, function()
	W.pop_in(card, 0.0, 0.94, 0.32)
end)
return nil
