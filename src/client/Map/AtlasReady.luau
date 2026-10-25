--!strict
-- Tells a map layer when an image it would like to switch to can be drawn.
--
-- A layer that swaps two stacked images for one combined atlas (Sprites.units_one, Sprites.shapes_one) must not
-- do so before that atlas loads for this player: an image Roblox has not approved yet, or refuses,
-- draws nothing, and every unit or plate on the map would be gone. So the layer starts on the atlases
-- it has always used and asks here.
--
-- ContentProvider:PreloadAsync answers truthfully only for an instance: given the content id as a
-- string it reported Failure for atlases that were on screen (Studio, 2026-10-08), and Success /
-- Failure correctly for an ImageLabel holding it.
local ContentProvider = game:GetService("ContentProvider")

local AtlasReady = {}

--- Seconds between tries while the image does not load (it may still be in moderation), and how many.
AtlasReady.RETRY_S = 45
AtlasReady.TRIES = 8

--- Calls `on_ready` once, when `id` has loaded. Never, if it does not load in TRIES tries.
function AtlasReady.watch(id: string, on_ready: () -> ())
	task.spawn(function()
		for try = 1, AtlasReady.TRIES do
			local probe = Instance.new("ImageLabel")
			probe.Image = id
			local loaded = false
			pcall(function()
				ContentProvider:PreloadAsync({ probe }, function(_content: string, status: Enum.AssetFetchStatus)
					if status == Enum.AssetFetchStatus.Success then
						loaded = true
					end
				end)
			end)
			probe:Destroy()
			if loaded then
				on_ready()
				return
			end
			if try < AtlasReady.TRIES then
				task.wait(AtlasReady.RETRY_S)
			end
		end
	end)
end

return AtlasReady
