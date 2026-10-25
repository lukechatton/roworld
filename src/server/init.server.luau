-- Airfront server entry. Owned by the Session/Main agent (see PORT.md §Ownership).
-- Dev harness hook: workspace attribute AF_DEV runs src/server/Dev/<AF_DEV>.luau if it exists.
local dev = workspace:GetAttribute("AF_DEV")
if type(dev) == "string" and dev ~= "" then
	local mod = script:FindFirstChild("Dev") and script.Dev:FindFirstChild(dev)
	if mod then
		print("[RoWorld] server dev harness:", dev)
		require(mod)
		return
	end
end
local Server = script:FindFirstChild("ServerMain")
if Server then
	require(Server).start()
else
	print("[RoWorld] server boot (ServerMain not yet written)")
end
