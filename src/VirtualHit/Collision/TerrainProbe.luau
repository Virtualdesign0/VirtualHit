--!strict

local Workspace = game:GetService("Workspace")

local Errors = require(script.Parent.Parent.Util.Errors)
local Config = require(script.Parent.Parent.Config)

-- Live config section. Read through it so VirtualHit.configure() takes
-- effect without reloading the library.
local Tuning = Config.Terrain

-- Terrain is one Instance, so every query in this library has had to treat it as
-- a wall: you cannot exclude a single voxel to keep looking past it, and
-- GetPartsInPart never reports it at all. That made terrain opaque to pierce and
-- invisible to zones.

-- ReadVoxels sees what raycasts cannot: which material is where, and how solid
-- it is. That is enough to measure how much terrain a shot actually crossed and
-- to resume the cast on the far side.

-- Two things about the data are load-bearing. The grid is fixed at 4 studs, so
-- every thickness reported here is quantised to that; and occupancy is a
-- fraction, not a boolean, so "solid" is a threshold the caller can move.

local TerrainProbe = {}

local RESOLUTION = 4
-- Roblox refuses a ReadVoxels region beyond this many voxels. Failing here with
-- an explanation beats failing inside the engine with a number.
local MAX_VOXELS = 4_194_304

TerrainProbe.Resolution = RESOLUTION

export type TerrainSpan = {
	-- Where the solid run starts and, when it ends inside the searched
	-- distance, where it ends. A run that never ends leaves Exit and Thickness
	-- nil: too deep to measure, exactly as a part thicker than MaxThickness is.
	read Entry: Vector3,
	read Exit: Vector3?,
	read Thickness: number?,
	read EntryDistance: number,
	-- The material that occupied most of the run, and the mean occupancy of it.
	read Material: Enum.Material,
	read Occupancy: number,
	read Samples: number,
}

export type SampleOptions = {
	Terrain: Terrain?,
	-- Occupancy at or above which a voxel counts as solid.
	Threshold: number?,
	-- Distance between samples along the ray. Smaller is more precise and
	-- costs nothing extra in engine calls: the whole region is read once.
	Step: number?,
}

local function fail(message: string, code: string?): never
	return Errors.raise("VirtualHit.Terrain", code or "InvalidArgument", message, 3)
end

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function isFiniteVector3(value: Vector3): boolean
	return isFiniteNumber(value.X) and isFiniteNumber(value.Y) and isFiniteNumber(value.Z)
end

local function resolveTerrain(terrain: Terrain?): Terrain
	if terrain == nil then
		return Workspace.Terrain
	end

	if typeof(terrain) ~= "Instance" or not terrain:IsA("Terrain") then
		fail("options.Terrain must be a Terrain instance")
	end

	return terrain
end

local function positiveNumber(value: any, name: string, defaultValue: number): number
	if value == nil then
		return defaultValue
	end

	if type(value) ~= "number" or not isFiniteNumber(value) or value <= 0 then
		fail(`options.{name} must be a finite number greater than zero`)
	end

	return value
end

type VoxelGrid = {
	Materials: { { { Enum.Material } } },
	Occupancies: { { { number } } },
	Min: Vector3,
	Counts: Vector3,
}

-- One read for the whole region. Sampling many points along a ray then costs
-- table lookups rather than engine calls.
local function read(terrain: Terrain, region: Region3): VoxelGrid
	local aligned = region:ExpandToGrid(RESOLUTION)
	local size = aligned.Size
	local counts = Vector3.new(
		math.max(math.round(size.X / RESOLUTION), 1),
		math.max(math.round(size.Y / RESOLUTION), 1),
		math.max(math.round(size.Z / RESOLUTION), 1)
	)
	local volume = counts.X * counts.Y * counts.Z

	if volume > MAX_VOXELS then
		fail(
			`the requested terrain region is {math.floor(volume)} voxels, above the {MAX_VOXELS} the engine allows; shorten the distance or raise the step`,
			"RegionTooLarge"
		)
	end

	local materials, occupancies = terrain:ReadVoxels(aligned, RESOLUTION)

	return {
		Materials = materials :: any,
		Occupancies = occupancies :: any,
		Min = aligned.CFrame.Position - size * 0.5,
		Counts = counts,
	}
end

local function sampleAt(grid: VoxelGrid, position: Vector3): (Enum.Material, number)
	local offset = position - grid.Min
	local x = math.floor(offset.X / RESOLUTION) + 1
	local y = math.floor(offset.Y / RESOLUTION) + 1
	local z = math.floor(offset.Z / RESOLUTION) + 1

	if x < 1 or y < 1 or z < 1 or x > grid.Counts.X or y > grid.Counts.Y or z > grid.Counts.Z then
		return Enum.Material.Air, 0
	end

	local column = grid.Materials[x]
	local occupancyColumn = grid.Occupancies[x]

	if column == nil or occupancyColumn == nil then
		return Enum.Material.Air, 0
	end

	local row = column[y]
	local occupancyRow = occupancyColumn[y]

	if row == nil or occupancyRow == nil then
		return Enum.Material.Air, 0
	end

	return row[z] or Enum.Material.Air, occupancyRow[z] or 0
end

local function regionAround(from: Vector3, to: Vector3): Region3
	local minimum = Vector3.new(
		math.min(from.X, to.X),
		math.min(from.Y, to.Y),
		math.min(from.Z, to.Z)
	) - Vector3.one * RESOLUTION
	local maximum = Vector3.new(
		math.max(from.X, to.X),
		math.max(from.Y, to.Y),
		math.max(from.Z, to.Z)
	) + Vector3.one * RESOLUTION

	return Region3.new(minimum, maximum)
end

-- The material and occupancy at a single point.
function TerrainProbe.materialAt(position: Vector3, terrain: Terrain?): (Enum.Material, number)
	if typeof(position) ~= "Vector3" or not isFiniteVector3(position) then
		fail("position must be a finite Vector3")
	end

	local grid = read(resolveTerrain(terrain), regionAround(position, position))
	return sampleAt(grid, position)
end

-- How much of an axis-aligned box is solid terrain, and which material fills
-- most of it. A zone can use this to ask "am I underground" or "is this
-- underwater" without pretending terrain is an occupant.
function TerrainProbe.occupancyIn(
	centre: Vector3,
	size: Vector3,
	options: SampleOptions?
): (number, Enum.Material)
	local resolved: SampleOptions = if options == nil then {} else options

	if type(resolved) ~= "table" then
		fail("expected an options table")
	end

	if typeof(centre) ~= "Vector3" or not isFiniteVector3(centre) then
		fail("centre must be a finite Vector3")
	end

	if typeof(size) ~= "Vector3" or not isFiniteVector3(size) or size.Magnitude <= 0 then
		fail("size must be a finite non-zero Vector3")
	end

	local half = size * 0.5
	local grid = read(resolveTerrain(resolved.Terrain), Region3.new(centre - half, centre + half))
	local step = positiveNumber(resolved.Step, "Step", RESOLUTION)
	local total = 0
	local samples = 0
	local tally: { [Enum.Material]: number } = {}

	-- Sampled at the middle of each step cell rather than on a lattice from
	-- -half to +half. That lattice put its last plane on every axis exactly on
	-- the far face of the box, which is one voxel past the region that was
	-- read: those samples came back as air, and a box sitting inside solid rock
	-- reported itself under half full.
	local function offsets(halfExtent: number): { number }
		local points = {}
		local at = -halfExtent + step * 0.5

		while at < halfExtent do
			table.insert(points, at)
			at += step
		end

		if #points == 0 then
			-- A box thinner than one step still has a middle.
			table.insert(points, 0)
		end

		return points
	end

	for _, x in offsets(half.X) do
		for _, y in offsets(half.Y) do
			for _, z in offsets(half.Z) do
				local material, occupancy = sampleAt(grid, centre + Vector3.new(x, y, z))
				samples += 1
				total += occupancy

				if occupancy > 0 then
					tally[material] = (tally[material] or 0) + occupancy
				end
			end
		end
	end

	local dominant = Enum.Material.Air
	local best = 0

	for material, weight in tally do
		if weight > best then
			best = weight
			dominant = material
		end
	end

	return (if samples == 0 then 0 else total / samples), dominant
end

-- Walks a ray through terrain and reports the first solid run it meets. This is
-- what lets pierce cross terrain: it gives an exit point to resume from and a
-- thickness to charge, neither of which a raycast can produce for a single
-- Instance that cannot be excluded.
function TerrainProbe.sampleAlong(
	origin: Vector3,
	direction: Vector3,
	distance: number,
	options: SampleOptions?
): TerrainSpan?
	local resolved: SampleOptions = if options == nil then {} else options

	if type(resolved) ~= "table" then
		fail("expected an options table")
	end

	if typeof(origin) ~= "Vector3" or not isFiniteVector3(origin) then
		fail("origin must be a finite Vector3")
	end

	if typeof(direction) ~= "Vector3" or not isFiniteVector3(direction) then
		fail("direction must be a finite Vector3")
	end

	if direction.Magnitude <= 1e-4 then
		fail("direction must be non-zero")
	end

	if type(distance) ~= "number" or not isFiniteNumber(distance) or distance <= 0 then
		fail("distance must be a finite number greater than zero")
	end

	local unit = direction.Unit
	local threshold = positiveNumber(resolved.Threshold, "Threshold", Tuning.Threshold)
	local step = positiveNumber(resolved.Step, "Step", Tuning.Step)
	local terrain = resolveTerrain(resolved.Terrain)
	local grid = read(terrain, regionAround(origin, origin + unit * distance))

	local entryDistance: number? = nil
	local exitDistance: number? = nil
	local tally: { [Enum.Material]: number } = {}
	local occupancyTotal = 0
	local samples = 0
	local travelled = 0

	while travelled <= distance do
		local material, occupancy = sampleAt(grid, origin + unit * travelled)
		local solid = occupancy >= threshold

		if entryDistance == nil then
			if solid then
				entryDistance = travelled
				samples = 1
				occupancyTotal = occupancy
				tally[material] = occupancy
			end
		elseif solid then
			samples += 1
			occupancyTotal += occupancy
			tally[material] = (tally[material] or 0) + occupancy
		else
			-- The run ended. Everything past here is somebody else's problem.
			exitDistance = travelled
			break
		end

		travelled += step
	end

	-- Guarded through a fresh local rather than on `entryDistance` itself: the
	-- loop above assigns to it, so a refinement on it does not survive to the
	-- literal below, and EntryDistance would stay optional there.
	local entryAt = entryDistance

	if entryAt == nil then
		return nil
	end

	local dominant = Enum.Material.Air
	local best = 0

	for material, weight in tally do
		if weight > best then
			best = weight
			dominant = material
		end
	end

	local entry = origin + unit * entryAt
	local exit: Vector3? = nil
	local thickness: number? = nil

	if exitDistance ~= nil then
		exit = origin + unit * exitDistance
		thickness = exitDistance - entryAt
	end

	return table.freeze({
		Entry = entry,
		Exit = exit,
		Thickness = thickness,
		EntryDistance = entryAt,
		Material = dominant,
		Occupancy = if samples == 0 then 0 else occupancyTotal / samples,
		Samples = samples,
	})
end

table.freeze(TerrainProbe)

return TerrainProbe
