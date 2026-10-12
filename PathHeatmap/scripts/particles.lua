local mod = ...

-- Particle assets for the overlay: one soft white dot texture and one particle
-- system per distance band, tinted by StartColor. Modelled on the Mithril
-- example's smoke system (the only documented PARTICLE_SYSTEM definition).

mod:registerAssetId("textures/dot.png", "PATHHEAT_DOT_TEXTURE")

mod:registerAsset({
	DataType = "MATERIAL",
	Id = "PATHHEAT_DOT_MATERIAL",
	BackFaceVisible = true,
	AlbedoTexture = "PATHHEAT_DOT_TEXTURE",
})

-- XZ lies flat on the ground; camera-facing quads cut into the terrain and show
-- hard diagonal edges.
local BILLBOARD = PARTICLE_BILLBOARD_BEHAVIOR.XZ

-- One system per band, width class and aspect class, ids
-- PATHHEAT_PS_<NAME>_<width>_<aspect>. StartSize is the short side and
-- AspectRatio multiplies it to give the long side (confirmed in game: using the
-- long side as StartSize stretched strips to about 80 m). The overlay picks the
-- class from the shape of the walked area.
local BANDS = {
	{ name = "NEAR", color = { 0.2, 0.9, 0.3 } }, -- <= 50 m
	{ name = "MID",  color = { 1.0, 0.8, 0.1 } }, -- <= 100 m
	{ name = "FAR",  color = { 0.95, 0.25, 0.2 } }, -- <= 150 m
}

for _, band in ipairs(BANDS) do
	local r, g, b = band.color[1], band.color[2], band.color[3]
	for wi, radius in ipairs(PathHeatmap.RADII) do
		for ai, aspect in ipairs(PathHeatmap.ASPECTS) do
			local size = radius * PathHeatmap.SIZE_PER_RADIUS
			mod:registerAsset({
				DataType = "PARTICLE_SYSTEM",
				Id = "PATHHEAT_PS_" .. band.name .. "_" .. wi .. "_" .. ai,
				Material = "PATHHEAT_DOT_MATERIAL",
				BillboardBehavior = BILLBOARD,
				AspectRatio = PathHeatmap.ASPECT_FLIP and (1 / aspect) or aspect,
				Duration = 4,
				Looping = true,
				Delay = { 0, 0 },
				LifeTime = 4,
				StartSpeed = { 0, 0 },
				StartSize = { size, size },
				StartRotation = { 0, 0 },
				StartColor = { r, g, b, 0.22 },
				GravityModifier = 0,
				RateOverTime = 3,
				BurstList = {},
				Shape = {
					DataType = "PARTICLE_EMITTER_SHAPE_CONE",
					Angle = 0,
					Radius = 0.0001,
				},
				LinearVelocity = {
					DataType = "PARTICLE_FLOAT3_VALUE_CONSTANT_RANDOM",
					ValueA = { 0, 0, 0 },
					ValueB = { 0, 0, 0 },
				},
				ColorOverLifeTime = {
					DataType = "GRADIENT",
					ColorList = {
						{ T = 0, Color = { r, g, b, 1 } },
						{ T = 1, Color = { r, g, b, 1 } },
					},
					AlphaList = {
						{ T = 0, Alpha = 0 },
						{ T = 0.15, Alpha = 100 },
						{ T = 0.85, Alpha = 100 },
						{ T = 1, Alpha = 0 },
					},
				},
				SizeOverLifetime = {
					{ T = 0, Value = 1 },
					{ T = 1, Value = 1 },
				},
				RotationOverLifetime = { 0, 0 },
			})
		end
	end
end
