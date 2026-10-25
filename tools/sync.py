#!/usr/bin/env python3
"""Push the Rojo tree (default.project.json) into an open Studio place over StudioMCP.

A Rojo-live-sync substitute that needs no UI clicks. Studio must be in EDIT mode (stop play first).

Usage:
  STUDIO_MATCH=<name>.rbxl .venv/bin/python tools/sync.py [--full]

Rules (same as Rojo): a directory is a Folder unless it contains init(.server|.client).luau, in which
case the directory itself becomes that script; `x.server.luau` -> Script, `x.client.luau` ->
LocalScript, `x.luau` -> ModuleScript. `*.json` files in src become ModuleScripts returning the
decoded table (HttpService:JSONDecode). Unchanged files are skipped using a per-studio hash cache
unless --full is given (a full sync deletes and rebuilds every mapped root).
"""
import hashlib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import studio  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE_DIR = os.path.join(ROOT, "build", ".synccache")
MAX_CALL_BYTES = 350_000


def lua_long(s: str) -> str:
    eq = 0
    while ("]" + "=" * eq + "]") in s:
        eq += 1
    return "[" + "=" * eq + "[\n" + s + "]" + "=" * eq + "]"


def script_kind(fname):
    if fname.endswith(".server.luau") or fname.endswith(".server.lua"):
        return "Script", fname.rsplit(".server.", 1)[0]
    if fname.endswith(".client.luau") or fname.endswith(".client.lua"):
        return "LocalScript", fname.rsplit(".client.", 1)[0]
    if fname.endswith(".luau") or fname.endswith(".lua"):
        return "ModuleScript", fname.rsplit(".", 1)[0]
    return None, None


def collect(fs_path, inst_path, out):
    """Append (inst_path_list, class, source|None) entries. Folders have source None."""
    if os.path.isfile(fs_path):
        cls, name = script_kind(os.path.basename(fs_path))
        if cls:
            out.append((inst_path, cls, open(fs_path).read()))
        return
    names = sorted(os.listdir(fs_path))
    init = None
    for n in names:
        if n.split(".")[0] == "init":
            cls, _ = script_kind(n)
            if cls:
                init = (n, cls)
    if init:
        out.append((inst_path, init[1], open(os.path.join(fs_path, init[0])).read()))
    else:
        out.append((inst_path, "Folder", None))
    for n in names:
        if n.startswith(".") or (init and n == init[0]):
            continue
        p = os.path.join(fs_path, n)
        if os.path.isdir(p):
            collect(p, inst_path + [n], out)
        else:
            cls, name = script_kind(n)
            if cls:
                out.append((inst_path + [name], cls, open(p).read()))
            elif n.endswith(".json") and not n.endswith(".meta.json"):
                src = "return game:GetService('HttpService'):JSONDecode(" + lua_long(open(p).read()) + ")"
                out.append((inst_path + [n[:-5]], "ModuleScript", src))


def walk_tree(node, inst_path, roots):
    for key, child in node.items():
        if key.startswith("$"):
            continue
        p = inst_path + [key]
        if "$path" in child:
            roots.append((p, os.path.join(ROOT, child["$path"])))
        walk_tree(child, p, roots)


LUA_PRELUDE = r"""
local function resolve(path, create)
	local cur = game
	for i, name in ipairs(path) do
		local nxt
		if i == 1 then
			nxt = game:GetService(name)
		else
			nxt = cur:FindFirstChild(name)
		end
		if not nxt then
			if not create then return nil end
			nxt = Instance.new("Folder")
			nxt.Name = name
			nxt.Parent = cur
		end
		cur = nxt
	end
	return cur
end
local function put(path, cls, src)
	local parent = resolve({table.unpack(path, 1, #path - 1)}, true)
	local name = path[#path]
	local inst = parent:FindFirstChild(name)
	if inst and inst.ClassName ~= cls then
		local kids = inst:GetChildren()
		local n = Instance.new(cls)
		n.Name = name
		for _, k in ipairs(kids) do k.Parent = n end
		inst:Destroy()
		n.Parent = parent
		inst = n
	elseif not inst then
		inst = Instance.new(cls)
		inst.Name = name
		inst.Parent = parent
	end
	if src then
		if #src >= 199000 then
			-- Script.Source assignment is capped at 200k chars; the editor service has no cap.
			game:GetService("ScriptEditorService"):UpdateSourceAsync(inst, function() return src end)
		else
			inst.Source = src
		end
	end
end
"""


def main():
    full = "--full" in sys.argv
    proj = json.load(open(os.path.join(ROOT, "default.project.json")))
    roots = []
    walk_tree(proj["tree"], [], roots)
    entries = []
    for inst_path, fs in roots:
        collect(fs, inst_path, entries)

    c = studio.Client()
    try:
        sid = studio.pick_studio(c)
        os.makedirs(CACHE_DIR, exist_ok=True)
        cache_file = os.path.join(CACHE_DIR, sid + ".json")
        cache = {} if full or not os.path.exists(cache_file) else json.load(open(cache_file))

        def run(code):
            res = c.call("execute_luau", {"code": code, "datamodel_type": "Edit", "studio_id": sid})
            txt = studio.text_of(res)
            if res.get("isError") or "error" in txt.lower()[:200] and "ok" not in txt[:10]:
                print(txt)
            return txt

        state = run("return tostring(game:GetService('RunService'):IsRunning())")
        if "true" in state:
            print("Studio is in play mode; stop it first (studio.py call start_stop_play '{\"is_start\":false}')")
            sys.exit(2)

        if full:
            dels = "\n".join(
                "do local r = resolve(%s, false) if r then r:Destroy() end end" % json.dumps(p).replace("[", "{").replace("]", "}")
                for p, _ in roots)
            run(LUA_PRELUDE + dels + "\nreturn 'ok'")

        # Remove instances under each root that no longer exist on disk.
        wanted = {tuple(p) for p, _, _ in entries}
        listing = run(LUA_PRELUDE + """
local out = {}
local roots = %s
for _, rp in ipairs(roots) do
	local r = resolve(rp, false)
	if r then
		for _, d in ipairs(r:GetDescendants()) do
			if d:IsA("LuaSourceContainer") or d:IsA("Folder") then
				local parts = {}
				local cur = d
				while cur and cur ~= game do table.insert(parts, 1, cur.Name) cur = cur.Parent end
				parts[1] = cur and game:GetService(parts[1]).ClassName or parts[1]
				table.insert(out, table.concat(parts, "\\1"))
			end
		end
	end
end
return table.concat(out, "\\2")
""" % json.dumps([p for p, _ in roots]).replace("[", "{").replace("]", "}"))
        stale = []
        for item in listing.split("\x02"):
            if not item.strip():
                continue
            parts = tuple(item.strip().split("\x01"))
            # stale = not on disk and not an ancestor folder of something on disk
            if parts not in wanted and not any(w[:len(parts)] == parts for w in wanted):
                stale.append(list(parts))
        if stale:
            run(LUA_PRELUDE + "\n".join(
                "do local r = resolve(%s, false) if r then r:Destroy() end end" % json.dumps(p).replace("[", "{").replace("]", "}")
                for p in stale) + "\nreturn 'ok'")
            for p in stale:
                cache.pop("/".join(p), None)
            print("removed", len(stale), "stale instances")

        batch, size, pushed = [], 0, 0

        def flush():
            nonlocal batch, size
            if batch:
                run(LUA_PRELUDE + "\n".join(batch) + "\nreturn 'ok'")
            batch, size = [], 0

        for path, cls, src in entries:
            key = "/".join(path)
            h = hashlib.sha1(((src or "") + cls).encode()).hexdigest()
            if cache.get(key) == h:
                continue
            stmt = "put(%s, %s, %s)" % (
                json.dumps(path).replace("[", "{").replace("]", "}"), json.dumps(cls),
                lua_long(src) if src is not None else "nil")
            if size + len(stmt) > MAX_CALL_BYTES:
                flush()
            batch.append(stmt)
            size += len(stmt)
            cache[key] = h
            pushed += 1
        flush()
        json.dump(cache, open(cache_file, "w"))
        print(f"synced {pushed} changed / {len(entries)} total instances to studio {sid}")
    finally:
        c.close()


if __name__ == "__main__":
    main()
