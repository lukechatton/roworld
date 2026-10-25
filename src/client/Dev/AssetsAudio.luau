-- Assets agent dev harness: verifies every Audio manifest entry loads and plays (AF_DEV = "AssetsAudio").
-- Silent: Sounds play at Volume 0; loudness is measured with AudioPlayer -> AudioAnalyzer (not wired
-- to any output). Prints "[AssetsAudio] result {json}" and shows a table on screen.
--   fetch    ContentProvider:PreloadAsync status
--   loaded   Sound.IsLoaded, TimeLength vs manifest length
--   plays    TimePosition advances after :Play()
--   loop     music only: Looped sound started 0.4 s before the end wraps to ~0.4 s (DidLoop fired)
--   peak     max AudioAnalyzer.PeakLevel while playing (compare with the source WAV's sample peak)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")
local SoundService = game:GetService("SoundService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Audio = require(ReplicatedStorage:WaitForChild("Airfront"):WaitForChild("Assets"):WaitForChild("Audio"))

local entries = {}
for k, e in Audio.music do
	table.insert(entries, { key = "music." .. k, id = e.id, length = e.length, music = true })
end
for k, e in Audio.sfx do
	table.insert(entries, {
		key = "sfx." .. k,
		id = e.id or e.sprite,
		length = e.length,
		region = e.sprite and NumberRange.new(e.start, e.stop) or nil,
	})
end
table.sort(entries, function(a, b)
	return a.key < b.key
end)

-- UI
local gui = Instance.new("ScreenGui")
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
local bg = Instance.new("Frame")
bg.Size = UDim2.fromScale(1, 1)
bg.BackgroundColor3 = Color3.fromRGB(13, 19, 38)
bg.BorderSizePixel = 0
bg.Parent = gui
local list = Instance.new("TextLabel")
list.BackgroundTransparency = 1
list.Position = UDim2.fromOffset(16, 12)
list.Size = UDim2.new(1, -32, 1, -24)
list.FontFace = Font.fromId(12187365977, Enum.FontWeight.Medium)
list.TextSize = 12
list.RichText = true
list.TextXAlignment = Enum.TextXAlignment.Left
list.TextYAlignment = Enum.TextYAlignment.Top
list.TextColor3 = Color3.fromRGB(230, 236, 255)
list.Text = "loading…"
list.Parent = bg
gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

-- 1) preload
local sounds, fetch = {}, {}
for _, e in entries do
	local s = Instance.new("Sound")
	s.Name = e.key
	s.SoundId = e.id
	s.Volume = 0
	if e.region then
		s.PlaybackRegionsEnabled = true
		s.PlaybackRegion = e.region
	end
	s.Parent = SoundService
	sounds[e.key] = s
end
local list_ = {}
for _, s in sounds do
	table.insert(list_, s)
end
local t0 = os.clock()
ContentProvider:PreloadAsync(list_, function(contentId, status)
	fetch[contentId] = status.Name
end)
local deadline = os.clock() + 30
for _, e in entries do
	local s = sounds[e.key]
	while not s.IsLoaded and os.clock() < deadline do
		task.wait(0.1)
	end
end
local preload_s = os.clock() - t0

-- 2) loudness probes (AudioPlayer -> AudioAnalyzer, silent) for every entry, all in parallel
local probes = {}
for _, e in entries do
	local p = Instance.new("AudioPlayer")
	p.Asset = e.id
	p.Volume = 1
	if e.region then
		p.PlaybackRegion = e.region
	end
	local a = Instance.new("AudioAnalyzer")
	local w = Instance.new("Wire")
	p.Parent = SoundService
	a.Parent = p
	w.SourceInstance = p
	w.TargetInstance = a
	w.Parent = a
	probes[e.key] = { player = p, analyzer = a, peak = 0, rms = 0 }
end
for _, pr in probes do
	pcall(function()
		pr.player:Play()
	end)
end

-- 3) play test (silent) + loop test for music
local plays, loops = {}, {}
for _, e in entries do
	local s = sounds[e.key]
	if s.IsLoaded then
		if e.music then
			local looped = false
			s.Looped = true
			local conn = s.DidLoop:Connect(function()
				looped = true
			end)
			s.TimePosition = math.max(0, s.TimeLength - 0.4)
			s:Play()
			task.delay(0.8, function()
				loops[e.key] = { didloop = looped, pos = s.TimePosition }
				conn:Disconnect()
				s:Stop()
			end)
		else
			s:Play()
			task.delay(math.min(0.05, e.length * 0.5), function()
				plays[e.key] = { playing = s.IsPlaying or s.TimePosition > 0, pos = s.TimePosition }
			end)
		end
	end
end
local music_probe_s = 6.0
local t1 = os.clock()
local conn = RunService.Heartbeat:Connect(function()
	for key, pr in probes do
		if key:sub(1, 6) ~= "music." or os.clock() - t1 <= music_probe_s then
			local pk, rm = pr.analyzer.PeakLevel, pr.analyzer.RmsLevel
			if pk > pr.peak then
				pr.peak = pk
			end
			if rm > pr.rms then
				pr.rms = rm
			end
		end
	end
end)
task.wait(12.5)
conn:Disconnect()
for _, s in sounds do
	s:Stop()
end
for key, e in entries do
	local s = sounds[e.key]
	if e.music then
		-- music plays test: started from 0 at volume 0
		s.Looped = false
		s.TimePosition = 0
		s:Play()
		task.wait(0.3)
		plays[e.key] = { playing = s.IsPlaying and s.TimePosition > 0.1, pos = s.TimePosition }
		s:Stop()
	end
end

-- 4) report
local rows, out, fails = {}, {}, 0
for _, e in entries do
	local s = sounds[e.key]
	local pr = probes[e.key]
	local r = {
		id = e.id,
		fetch = fetch[e.id] or "?",
		loaded = s.IsLoaded,
		time_length = s.TimeLength,
		manifest_length = e.length,
		plays = plays[e.key] and plays[e.key].playing or false,
		peak = pr.peak,
		rms = pr.rms,
		player_loaded = pr.player.IsReady,
	}
	if loops[e.key] then
		r.loop_ok = loops[e.key].didloop and loops[e.key].pos > 0.1 and loops[e.key].pos < 0.9
		r.loop_pos = loops[e.key].pos
	end
	local len_ok = e.region ~= nil or math.abs(s.TimeLength - e.length) < 0.03
	local ok = r.loaded and r.plays and len_ok and (r.loop_ok ~= false)
	if not ok then
		fails += 1
	end
	out[e.key] = r
	table.insert(
		rows,
		string.format(
			'<font color="%s">%-24s</font>  %s  fetch=%s  loaded=%s  len=%.3f (manifest %.3f)  plays=%s  peak=%.3f%s',
			ok and "#5ee39a" or "#ff5463",
			e.key,
			e.id,
			r.fetch,
			tostring(r.loaded),
			s.TimeLength,
			e.length,
			tostring(r.plays),
			pr.peak,
			r.loop_ok ~= nil and ("  loop=" .. tostring(r.loop_ok) .. string.format(" (%.2fs)", r.loop_pos)) or ""
		)
	)
end
list.Text = string.format(
	"<b>RoWorld audio check</b> — %d entries, %d failing, preload %.1fs\n\n%s",
	#entries,
	fails,
	preload_s,
	table.concat(rows, "\n")
)
print(string.format("[AssetsAudio] %d entries, %d failing", #entries, fails))
print("[AssetsAudio] result " .. HttpService:JSONEncode(out))
return nil
