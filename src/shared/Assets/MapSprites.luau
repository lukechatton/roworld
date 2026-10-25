-- The map's sprite atlases (CC BY-SA 4.0: `attribution`), uploaded with tools/upload.py; *_masks derived
-- by tools/assets/make_map_sprites.py (white masks the client tints per owner).
return {
	attribution = "OpenFront (CC BY-SA 4.0)",
	--- 6 white glyphs of 64 x 64: City, Port, Factory, Defense Post, SAM Launcher, Missile Silo
	icons = { id = "rbxassetid://119754841267076", cell = 64, cols = 6 },
	--- structure plates: 6 columns (same order) x 2 rows (0 whole shape -> border colour, 1 inset
	--- shape -> fill colour), 128 px cells
	shapes = { id = "rbxassetid://78283026129541", cell = 128, cols = 6 },
	--- unit sprites 13 x 13, 12 columns: Transport, Trade Ship, Warship, Atom Bomb, Hydrogen Bomb,
	--- MIRV, SAM Missile, Shell, MIRV Warhead, Train Engine, Train Carriage, Train Carriage (loaded)
	units_raw = { id = "rbxassetid://91864093199764", cell = 13, cols = 12 },
	--- the same split into row 0 (territory colour) and row 1 (border colour)
	units = { id = "rbxassetid://115026547473670", cell = 13, cols = 12 },
	--- `shapes` and `units` with their two rows in ONE image each (the fill's pixels white, the
	--- border's a grey: one tint gives both), for a sprite of one ImageLabel instead of two
	--- (tools/assets/make_map_sprites.py; Map/UnitLayer and Map/StructureLayer use them once
	--- they have loaded, and the two-row atlases until then)
	shapes_one = { id = "rbxassetid://81848484360750", cell = 128, cols = 6 },
	units_one = { id = "rbxassetid://132385586892836", cell = 13, cols = 12 },
	--- status icons 256 px cells (pad 16), 3 columns: crown, traitor, disconnected, alliance,
	--- allianceRequest, target, embargo, nukeRed, nukeWhite, allianceFaded, doomsdayClock, verified
	status = { id = "rbxassetid://111810811608235", cell = 256, cols = 3, pad = 16 },
	fx = { id = "rbxassetid://128595038659937" },
}
