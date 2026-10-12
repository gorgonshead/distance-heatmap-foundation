local mod = ...

-- Particle assets for the overlay: a soft white dot texture and one particle
-- system per band, width and stretch, with ids PATHHEAT_PS_<band>_<width>_<stretch>.
--
-- Each emitter shows one particle at a time: a burst of one at the start of
-- every loop, living one second longer than the loop so the next one fades in
-- as it fades out. (Emitting at a steady rate kept about twelve stacked
-- translucent quads alive per marker, which is a lot of blending for the GPU.)

local cfg = PathHeatmap.cfg

mod:registerAssetId("textures/dot.png", "PATHHEAT_DOT_TEXTURE")

mod:registerAsset({
	DataType = "MATERIAL",
	Id = "PATHHEAT_DOT_MATERIAL",
	BackFaceVisible = true,
	AlbedoTexture = "PATHHEAT_DOT_TEXTURE",
})

local LOOP = cfg.PARTICLE_LOOP
local LIFE = LOOP + 1
local FADE = 1 / LIFE -- one second, as a share of the lifetime

for bi, color in ipairs(cfg.BAND_COLORS) do
	local r, g, b = color[1], color[2], color[3]
	for wi, radius in ipairs(cfg.RADII) do
		for ai, aspect in ipairs(cfg.ASPECTS) do
			local size = radius * cfg.SIZE_PER_RADIUS
			mod:registerAsset({
				DataType = "PARTICLE_SYSTEM",
				Id = "PATHHEAT_PS_" .. bi .. "_" .. wi .. "_" .. ai,
				Material = "PATHHEAT_DOT_MATERIAL",
				-- XZ lies flat; camera-facing quads cut into the terrain.
				BillboardBehavior = PARTICLE_BILLBOARD_BEHAVIOR.XZ,
				-- StartSize is the short side; AspectRatio stretches the other.
				StartSize = { size, size },
				AspectRatio = aspect,
				-- Shown at every particle quality setting, and animated in real
				-- time so the overlay appears while the game is paused.
				MinimumQuality = PARTICLE_QUALITY.LOW,
				TimeScaleType = PARTICLE_TIME_SCALE_TYPE.UNSCALED,
				Duration = LOOP,
				Looping = true,
				Delay = { 0, 0 },
				LifeTime = LIFE,
				RateOverTime = 0,
				BurstList = {
					{ Time = 0, Count = 1, Cycles = 1, Interval = 0.1 },
				},
				StartSpeed = { 0, 0 },
				StartRotation = { 0, 0 },
				StartColor = { r, g, b, cfg.OVERLAY_ALPHA },
				GravityModifier = 0,
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
					-- Alpha keys go to 255 (the example peaks at 100 on an
					-- unconfirmed scale); OVERLAY_ALPHA sets the actual opacity.
					AlphaList = {
						{ T = 0, Alpha = 0 },
						{ T = FADE, Alpha = 255 },
						{ T = 1 - FADE, Alpha = 255 },
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
