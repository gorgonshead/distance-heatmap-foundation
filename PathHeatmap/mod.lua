local mod = foundation.createMod()

mod:log("PathHeatmap: loading")

-- Shared sampling state, read by the sampler component and (later) the overlay.
-- Globals survive Ctrl+Shift+R, so reset on every load or one-shot flags (such
-- as the spike's) stay set from the previous run.
PathHeatmap = {}

-- Per-selection and periodic log lines (entrances, distance fields, timing,
-- sample counts). Off by default; set to true to trace behaviour in the mod log.
PathHeatmap.DEBUG = false
function PathHeatmap.debug(message)
	if PathHeatmap.DEBUG then mod:log(message) end
end

-- Overlay ellipse sizes. RADII are semi-minor radii in metres and ASPECTS the
-- stretch classes (semi-major = radius x aspect). SIZE_PER_RADIUS scales the
-- particle quad past the ellipse, since the dot texture fades out at its edge.
PathHeatmap.RADII = { 3, 5, 8 }
PathHeatmap.ASPECTS = { 1, 2.2, 3.5 }
PathHeatmap.MAX_MAJOR = 16
PathHeatmap.SIZE_PER_RADIUS = 2.4

-- Two conventions that are not documented, to flip after looking at the result:
-- ASPECT_FLIP: AspectRatio shrinks the quad's other side instead of stretching it
-- (it stretches, so false). STRIP_ALONG_FORWARD: the strip's long axis is the
-- emitter's forward axis, not its side axis (strips ran along paths with false).
PathHeatmap.ASPECT_FLIP = false
PathHeatmap.STRIP_ALONG_FORWARD = false

-- Particles are optional: if their assets fail to register, the overlay falls
-- back to prefab markers instead of the whole mod failing to load.
local particlesOk, particlesErr = pcall(function() mod:dofile("scripts/particles.lua", mod) end)
if not particlesOk then mod:logError("particles.lua failed: " .. tostring(particlesErr)) end
mod:dofile("scripts/grid.lua", mod)
mod:dofile("scripts/overlay.lua", mod)
mod:dofile("scripts/COMP_PATH_SAMPLER.lua")
