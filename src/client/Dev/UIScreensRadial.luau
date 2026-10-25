-- ui-screens dev harness: the radial menu alone over a dark backdrop (Play mode).
-- workspace:SetAttribute("AF_DEV", "UIScreensRadial")
local Players = game:GetService("Players")
local UI = script.Parent.Parent:WaitForChild("UI")
local UITheme = require(UI.UITheme)
local UICtx = require(UI.UICtx)
local RadialMenu = require(UI.RadialMenu)
UITheme.init()
local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
local sg = Instance.new("ScreenGui")
sg.Name = "UIScreensRadial"
sg.IgnoreGuiInset = true
sg.ScreenInsets = Enum.ScreenInsets.None
sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
sg.Parent = pg
local bg = Instance.new("Frame")
bg.Size = UDim2.fromScale(1, 1)
bg.BackgroundColor3 = Color3.fromRGB(40, 60, 110)
bg.Parent = sg
local cam = workspace.CurrentCamera
local ctx = UICtx.new()
ctx.vp = cam.ViewportSize
ctx.airship_bar = Rect.new(0, 0, 0, 0)
ctx.reserved_top_left = Rect.new(0, 0, 0, 0)
local r = RadialMenu.new(ctx)
r.gui.Parent = sg
local items = {
	{ id = "attack", label = "Attack", icon = "attack", ok = false, reason = "No border or sea route" },
	{ id = "boat", label = "Boat", icon = "boat", ok = false, reason = "Target is not on a coast" },
	{ id = "retreat", label = "Retreat", icon = "retreat", ok = true },
	{
		id = "nuke",
		label = "Nuke",
		icon = "atom",
		ok = true,
		danger = true,
		sub = {
			{ id = "nuke:atom", label = "Atom", icon = "atom", ok = true, danger = true, cost = 750000 },
			{
				id = "nuke:hydrogen",
				label = "H-Bomb",
				icon = "hydrogen",
				ok = false,
				danger = true,
				reason = "Need 3.57M more gold",
				cost = 5000000,
			},
			{
				id = "nuke:mirv",
				label = "MIRV",
				icon = "mirv",
				ok = false,
				danger = true,
				reason = "Need 23.6M more gold",
				cost = 25000000,
			},
		},
	},
	{ id = "ally_request", label = "Ally", icon = "alliance", ok = true },
	{ id = "focus", label = "Focus", icon = "eye", ok = true },
	{ id = "info", label = "Info", icon = "info", ok = true },
}
local mode = workspace:GetAttribute("AF_RADIAL") or "root"
r:open_at(123, Vector2.new(780, 470), items, "Ukraine", UITheme.GREEN)
if mode == "sub" then
	r:_enter_sub(items[4])
	r._hover = 1
else
	r._hover = 0
end
game:GetService("RunService").RenderStepped:Connect(function(dt)
	r:update(dt)
end)
task.delay(0.6, function()
	r:_redraw()
	workspace:SetAttribute("AF_READY", true)
end)
return nil
