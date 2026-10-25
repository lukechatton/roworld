-- How much the interface asks the GPU to draw: for every visible GuiObject in PlayerGui, the screen
-- area it covers, summed by group and given as "screens" (1.0 = the whole viewport drawn once). A
-- GPU's cost for a 2D interface is the pixels blended, so 20 screens is twenty times the work of one
-- full-screen image, whatever the object count. Studio on a Mac reports no GPU time; this does not
-- need one. Run in a playtest's Client:
--   STUDIO_ID=<id> STUDIO_ALLOW_PUBLISHED=1 .venv/bin/python tools/studio.py luau Client tools/perf/overdraw.luau
-- What counts: a Frame's background, an image, a text's bounds, and a UIStroke's band (a stroke on a
-- TextLabel is drawn as copies of the text: its bounds once more per stroke pixel, up to 8).
local Players = game:GetService("Players")
local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
local vp = workspace.CurrentCamera.ViewportSize
local screen = vp.X * vp.Y

local function clipped(pos: Vector2, size: Vector2, clip: Rect?): number
	local x0, y0 = math.max(pos.X, 0), math.max(pos.Y, 0)
	local x1, y1 = math.min(pos.X + size.X, vp.X), math.min(pos.Y + size.Y, vp.Y)
	if clip ~= nil then
		x0, y0 = math.max(x0, clip.Min.X), math.max(y0, clip.Min.Y)
		x1, y1 = math.min(x1, clip.Max.X), math.min(y1, clip.Max.Y)
	end
	return math.max(x1 - x0, 0) * math.max(y1 - y0, 0)
end

local groups: { [string]: { area: number, n: number, kinds: { [string]: number } } } = {}
local function add(group: string, kind: string, area: number)
	if area <= 0 then
		return
	end
	local g = groups[group]
	if g == nil then
		g = { area = 0, n = 0, kinds = {} }
		groups[group] = g
	end
	g.area += area
	g.n += 1
	g.kinds[kind] = (g.kinds[kind] or 0) + area
end

local function walk(inst: Instance, group: string, depth: number, clip: Rect?)
	for _, c in inst:GetChildren() do
		if not c:IsA("GuiObject") then
			continue
		end
		local o = c :: GuiObject
		if not o.Visible then
			continue
		end
		local name = if depth <= 1 then group .. "/" .. o.Name else group
		local pos, size = o.AbsolutePosition, o.AbsoluteSize
		local stroke = o:FindFirstChildOfClass("UIStroke")
		if o.BackgroundTransparency < 0.99 then
			add(name, "fill", clipped(pos, size, clip))
		end
		if (o:IsA("ImageLabel") or o:IsA("ImageButton")) and (o :: any).Image ~= "" and (o :: any).ImageTransparency < 0.99 then
			add(name, "image", clipped(pos, size, clip))
		end
		if (o:IsA("TextLabel") or o:IsA("TextButton")) and (o :: any).Text ~= "" and (o :: any).TextTransparency < 0.99 then
			local tb = (o :: any).TextBounds
			local scale = 1.0
			local a: Instance? = o
			while a ~= nil and a ~= pg do
				local s = a:FindFirstChildOfClass("UIScale")
				if s ~= nil then
					scale *= s.Scale
				end
				a = a.Parent
			end
			local tsize = Vector2.new(math.min(tb.X * scale, size.X), math.min(tb.Y * scale, size.Y))
			local tpos = pos + (size - tsize) * 0.5
			local area = clipped(tpos, tsize, clip)
			add(name, "text", area)
			if stroke ~= nil and stroke.Enabled and stroke.Transparency < 0.99 then
				add(name, "text stroke", area * math.clamp(math.ceil(stroke.Thickness * scale), 1, 8))
			end
		elseif stroke ~= nil and stroke.Enabled and stroke.Transparency < 0.99 then
			local t = stroke.Thickness
			add(name, "stroke", clipped(pos - Vector2.new(t, t), size + Vector2.new(2 * t, 2 * t), clip) - clipped(pos, size, clip))
		end
		local next_clip = clip
		if o.ClipsDescendants then
			local r = Rect.new(pos.X, pos.Y, pos.X + size.X, pos.Y + size.Y)
			next_clip = if clip == nil
				then r
				else Rect.new(math.max(r.Min.X, clip.Min.X), math.max(r.Min.Y, clip.Min.Y), math.min(r.Max.X, clip.Max.X), math.min(r.Max.Y, clip.Max.Y))
		end
		walk(o, name, depth + 1, next_clip)
	end
end

for _, sg in pg:GetChildren() do
	if sg:IsA("ScreenGui") and sg.Enabled then
		walk(sg, sg.Name, 0, nil)
	end
end
local rows = {}
local total = 0
for name, g in groups do
	total += g.area
	table.insert(rows, { name, g })
end
table.sort(rows, function(a, b)
	return a[2].area > b[2].area
end)
local out = { ("viewport %dx%d: %.1f screens drawn in all"):format(vp.X, vp.Y, total / screen) }
for i = 1, math.min(22, #rows) do
	local name, g = rows[i][1], rows[i][2]
	local kinds = {}
	for k, a in g.kinds do
		table.insert(kinds, ("%s %.2f"):format(k, a / screen))
	end
	table.sort(kinds)
	table.insert(out, ("%6.2f screens  %-46s %5d objects  (%s)"):format(g.area / screen, name, g.n, table.concat(kinds, ", ")))
end
return table.concat(out, "\n")
