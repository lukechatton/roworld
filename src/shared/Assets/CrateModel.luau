-- The cosmetic crate's 3D chest (CrateOpening.luau): BedWars' voxel block chest, the studio's own game
-- (in use since 2026-09-29, in place of the earlier chest), taken from Tribes'
-- drop reveal data (tribes/src/.../UI/DropModels.luau "Drop", normalised there by tools/build/ui/drops.luau).
-- Built at runtime as Parts + SpecialMesh (FileMesh) inside a ViewportFrame.
--   pivot at the bottom centre, front = -Z, lid closed; `hinge` = the lid's hinge point (the lid opens
--   with a positive rotation about X there); sizes in studs. The lid is the top half of the block: it
--   flips far back (Tribes: 140 degrees) so it stays low.
-- The meshes and texture are 2022 user uploads (bryan3838): legacy user uploads load in any experience
-- (Tribes ships the same ids live).
return {
	size = { 5, 4.6666, 5 },
	hinge = { 0, 1.6667, 2.5 },
	-- the open chest's mouth (the card comes out here) and the lid's front seam (light leaks there)
	mouth = { 0, 2.1, 0 },
	seam = { 0, 1.6667, -2.5 },
	lid_open = 140,
	parts = {
		{
			name = "Lid",
			lid = true,
			mesh = "rbxassetid://8562367045",
			tex = "rbxassetid://8562367073",
			size = { 5, 3, 5 },
			scale = { 1.7012, 1.7012, 1.7012 },
			cf = { 0, 3.1666, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 },
			material = "Plastic",
		},
		{
			name = "Bottom",
			lid = false,
			mesh = "rbxassetid://8562367050",
			tex = "rbxassetid://8562367073",
			size = { 4.6666, 2.3333, 4.6666 },
			scale = { 1.7012, 1.7012, 1.7012 },
			cf = { 0, 1.1667, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 },
			material = "Plastic",
		},
	},
}
