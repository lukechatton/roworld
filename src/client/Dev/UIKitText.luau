--!nonstrict
-- ui-kit dev harness: text rendering at several UI scales (letter spacing, tabular digits, plain,
-- buttons). Cycles the UI scale 0.6 -> 0.8 -> 1.0 -> 1.2 -> 1.4 every 3 s (the current scale is
-- printed and shown top-left); capture each step with studio.py shot.
local Players = game:GetService("Players")
local UI = script.Parent.Parent:WaitForChild("UI")
local T = require(UI:WaitForChild("UITheme"))
local W = require(UI:WaitForChild("Widgets"))
local GlassPanel = require(UI:WaitForChild("GlassPanel"))
local CountLabel = require(UI:WaitForChild("CountLabel"))

-- Deliberately NOT calling T.init(): the kit must cope (approximate metrics, then a re-layout
-- once Rubik has loaded) -- this is what the session agent's full game hit.
local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
local sg = Instance.new("ScreenGui")
sg.Name = "UIKitText"
sg.IgnoreGuiInset = true
sg.ScreenInsets = Enum.ScreenInsets.None
sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
sg.ResetOnSpawn = false
sg.Parent = pg
local bg = Instance.new("Frame")
bg.Size = UDim2.fromScale(1, 1)
bg.BackgroundColor3 = Color3.fromRGB(10, 13, 34)
bg.BorderSizePixel = 0
bg.Parent = sg

local root = W.Root.new(sg, { scale = 1.0 })
local panel = GlassPanel.new(18, 14, T.R_LG, true, 18)
panel:set_offsets(24, 24, 24, 24)
root:add_child(panel)
local v = T.vbox(8)
panel:add_child(v)
local scale_l = T.label("scale", 12, 700, T.AMBER)
v:add_child(scale_l)
v:add_child(T.label("GAME MENU", 20, 900, T.TEXT, 3))
for _, s in ipairs({
	"How to play",
	"Restart match",
	"Show tips again",
	"Return to title",
	"Map data Natural Earth",
	"Select before attacking",
}) do
	local b = T.button(s, "GlassButton", "help", 44)
	v:add_child(b)
end
v:add_child(T.button("RESUME", "PrimaryButton", "play", 44))
v:add_child(T.caption("Troops · Gold · Attack · World control"))
v:add_child(T.label("LEADERBOARD  ATTACKS  INCOMING NUKE", 12, 800, T.TEXT, 2))
local row = T.hbox(12)
local c1 = CountLabel.new(20, 700, T.TEXT, T.fmt_num)
T.fix_width(c1, T.text_width("888.8M", 20, 700) + 2, W.ALIGN_RIGHT)
row:add_child(c1)
local c2 = CountLabel.new(20, 700, T.GOLD, T.fmt_num)
T.fix_width(c2, T.text_width("8888.8M", 20, 700) + 2, W.ALIGN_LEFT)
row:add_child(c2)
local plain = T.label("151K 1.11M 11:11", 13, 700, T.TEXT_2)
row:add_child(plain)
v:add_child(row)
c1:set_value(151100, false)
c2:set_value(1110000, false)

local scales = { 0.6, 0.8, 1.0, 1.2, 1.4 }
local fixed = workspace:GetAttribute("UIKIT_SCALE")
if type(fixed) == "number" and fixed > 0 then
	scales = { fixed }
end
task.spawn(function()
	local i = 0
	while true do
		i = i % #scales + 1
		local s = scales[i]
		root:set_scale_override(s)
		scale_l:set_text(string.format("scale %.1f  fonts_ready=%s", s, tostring(T.fonts_ready())))
		print("[UIKitText] scale", s, "fonts_ready", T.fonts_ready())
		c1:set_value(if i % 2 == 0 then 151100 else 118800)
		task.wait(3)
	end
end)
return nil
