--!nonstrict
-- ui-screens dev harness: the real Session + AudioDirector + UIRoot over the WorldView (or a flat
-- stand-in world until the globe lands), exactly wired like Main. Exposes _G.UIS for scripted
-- checks from `studio.py luau Client`:
--   _G.UIS.ui, .session, .world, .audio, .W (Widgets)
--   workspace:SetAttribute("AF_DEV", "UIScreensGame")   (optional: AF_UIS_REAL_WORLD = true)
local Players = game:GetService("Players")
local client = script.Parent.Parent
local UI = client:WaitForChild("UI")

local Session = require(client.Session)
local AudioDirector = require(client.Audio.AudioDirector)
local UIRoot = require(UI.UIRoot)
local W = require(UI.Widgets)
local Stubs = require(script.Parent.UIScreensStubs)
Stubs.install(UIRoot)

-- Same CoreGui setup as Main (the number keys are free once the backpack is off).
task.spawn(function()
	for _ = 1, 50 do
		local ok = pcall(function()
			local SG = game:GetService("StarterGui")
			SG:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
			SG:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
			SG:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
			SG:SetCoreGuiEnabled(Enum.CoreGuiType.EmotesMenu, false)
		end)
		if ok then
			return
		end
		task.wait(0.2)
	end
end)

local player = Players.LocalPlayer
local pg = player:WaitForChild("PlayerGui")

local session = Session.new()
local audio = AudioDirector.new("menu")
pcall(function()
	audio:bind_settings(session)
end)

local world = nil
local View = client:FindFirstChild("View")
if workspace:GetAttribute("AF_UIS_REAL_WORLD") == true and View and View:FindFirstChild("WorldView") then
	local ok, w = pcall(function()
		return require(View.WorldView).new()
	end)
	if ok then
		world = w
	else
		warn("[UIScreensGame] WorldView.new failed: " .. tostring(w))
	end
end
if world == nil then
	world = require(script.Parent.UIScreensWorld).new(pg)
end

local ui = UIRoot.new()
ui:setup(session, world, audio)
session.state_ready:Connect(function(state)
	world:bind_state(state)
	if world.set_attract_mode then
		world:set_attract_mode(ui:screen() == "title")
	end
end)
ui.screen_changed:Connect(function(scr)
	if world.set_attract_mode then
		world:set_attract_mode(scr == "title")
	end
end)
session:bind()
session:start_title()

_G.UIS = { ui = ui, session = session, world = world, audio = audio, W = W }

-- Bridge for `studio.py luau Client` (its VM does not share _G): a BindableFunction that runs a
-- named scene from Dev/UIScreensScenes with this harness' objects, or resolves a dotted path.
local bridge = Instance.new("BindableFunction")
bridge.Name = "UIScreensBridge"
local Scenes = require(script.Parent.UIScreensScenes)
bridge.OnInvoke = function(cmd: string, ...)
	local ok, res = pcall(function(...)
		if cmd == "get" then
			local path = ...
			local v: any = _G.UIS
			for part in string.gmatch(path, "[^%.]+") do
				v = v[part]
			end
			return tostring(v)
		end
		local f = Scenes[cmd]
		if f == nil then
			return "no scene " .. cmd
		end
		return f(_G.UIS, ...)
	end, ...)
	return if ok then res else ("ERROR " .. tostring(res))
end
bridge.Parent = pg
print("[UIScreensGame] ready")
return nil
