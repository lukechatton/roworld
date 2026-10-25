-- Assets agent dev harness: contact sheet of every UiIcons / Branding image (AF_DEV = "AssetsIcons").
-- Deterministic layout (tools/assets/contact_sheet.py crops the Studio capture by these offsets):
--   cells of CELL_W x CELL_H from (ORIGIN_X, ORIGIN_Y), COLS per row, sorted keys; per cell a 48 px
--   white icon at (8, 8), 24 px AMBER at (64, 8), 14 px CYAN at (64, 40), name at the bottom.
-- Also reads every uploaded image back (EditableImage) and prints per-image channel sums as JSON so
-- the generator's PNGs can be compared byte-for-byte ("[AssetsIcons] readback {...}").
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AssetService = game:GetService("AssetService")
local HttpService = game:GetService("HttpService")

local Assets = ReplicatedStorage:WaitForChild("Airfront"):WaitForChild("Assets")
local UiIcons = require(Assets:WaitForChild("UiIcons"))
local Branding = require(Assets:WaitForChild("Branding"))

local ORIGIN_X, ORIGIN_Y = 16, 16
local CELL_W, CELL_H, COLS = 104, 92, 9
local RUBIK = Font.fromId(12187365977, Enum.FontWeight.SemiBold)
local AMBER = Color3.new(1.0, 0.71, 0.278)
local CYAN = Color3.new(0.31, 0.82, 1.0)

local gui = Instance.new("ScreenGui")
gui.Name = "AssetsIcons"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.ScreenInsets = Enum.ScreenInsets.None
local bg = Instance.new("Frame")
bg.Size = UDim2.fromScale(1, 1)
bg.BackgroundColor3 = Color3.fromRGB(13, 19, 38)
bg.BorderSizePixel = 0
bg.Parent = gui

local function image(parent, id, x, y, px, tint)
	local l = Instance.new("ImageLabel")
	l.BackgroundTransparency = 1
	l.Image = id
	l.ScaleType = Enum.ScaleType.Fit
	l.Position = UDim2.fromOffset(x, y)
	l.Size = UDim2.fromOffset(px, px)
	l.ImageColor3 = tint or Color3.new(1, 1, 1)
	l.Parent = parent
	return l
end

local function text(parent, s, x, y, w, h, size, color)
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.FontFace = RUBIK
	t.Text = s
	t.TextSize = size
	t.TextColor3 = color or Color3.new(0.68, 0.73, 0.86)
	t.Position = UDim2.fromOffset(x, y)
	t.Size = UDim2.fromOffset(w, h)
	t.TextXAlignment = Enum.TextXAlignment.Left
	t.Parent = parent
	return t
end

local keys = {}
for k in UiIcons do
	if k ~= "app_icon" then
		table.insert(keys, k)
	end
end
table.sort(keys)

for i, k in keys do
	local col, row = (i - 1) % COLS, (i - 1) // COLS
	local cell = Instance.new("Frame")
	cell.Name = k
	cell.BackgroundColor3 = Color3.fromRGB(26, 33, 61)
	cell.BorderSizePixel = 0
	cell.Position = UDim2.fromOffset(ORIGIN_X + col * CELL_W, ORIGIN_Y + row * CELL_H)
	cell.Size = UDim2.fromOffset(CELL_W - 6, CELL_H - 6)
	cell.Parent = bg
	image(cell, UiIcons[k], 8, 8, 48)
	image(cell, UiIcons[k], 64, 8, 24, AMBER)
	image(cell, UiIcons[k], 64, 40, 14, CYAN)
	text(cell, k, 6, CELL_H - 26, CELL_W - 10, 16, 11)
end

-- Branding: logo mark at the title-emblem sizes (76 / 44) and the rotate card size (72).
local bx = ORIGIN_X + COLS * CELL_W + 16
image(bg, Branding.logo_mark, bx, ORIGIN_Y, 128)
image(bg, Branding.logo_mark, bx, ORIGIN_Y + 140, 76)
image(bg, UiIcons.app_icon, bx + 84, ORIGIN_Y + 140, 44)
text(bg, "logo_mark 128 / 76 / 44", bx, ORIGIN_Y + 222, 200, 16, 11)

gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
task.wait(0.5)
print("[AssetsIcons] viewport", workspace.CurrentCamera.ViewportSize, "gui abs", bg.AbsoluteSize)

-- Pixel readback of every uploaded image.
local out = {}
local all = table.clone(keys)
table.insert(all, "app_icon")
for _, k in all do
	local ok, img = pcall(function()
		return AssetService:CreateEditableImageAsync(Content.fromUri(UiIcons[k]))
	end)
	if ok and img then
		local sz = img.Size
		local buf = img:ReadPixelsBuffer(Vector2.zero, sz)
		local s = { 0, 0, 0, 0 }
		for p = 0, sz.X * sz.Y - 1 do
			local o = p * 4
			s[1] += buffer.readu8(buf, o)
			s[2] += buffer.readu8(buf, o + 1)
			s[3] += buffer.readu8(buf, o + 2)
			s[4] += buffer.readu8(buf, o + 3)
		end
		out[k] = { w = sz.X, h = sz.Y, sums = s }
		img:Destroy()
	else
		out[k] = { err = tostring(img) }
	end
end
print("[AssetsIcons] readback " .. HttpService:JSONEncode(out))
return nil
