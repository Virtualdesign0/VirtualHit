--!strict

local Types = require(script.Parent.Parent.Types)
local Cast = require(script.Parent.Cast)
local FilterClass = require(script.Parent.Parent.Collision.Filter)
local InternalExclusions = require(script.Parent.Parent.Collision.InternalExclusions)
local Params = require(script.Parent.Parent.Collision.Params)
local Resolver = require(script.Parent.Parent.Collision.Resolver)
local TerrainProbe = require(script.Parent.Parent.Collision.TerrainProbe)
local Errors = require(script.Parent.Parent.Util.Errors)
local Config = require(script.Parent.Parent.Config)

-- Live config section. Read through it so VirtualHit.configure() takes effect
-- without reloading the library.
local Tuning = Config.Pierce

-- Penetration is the predicate retry loop with a budget: hit a part, measure
-- how much material the shot crossed, spend that from the remaining power,
-- exclude the part, cast again. It stops when the budget runs out, when
-- nothing is left in front, or when it meets something it cannot exclude.

local Pierce = {}

-- Enough to clear the surface just struck without skipping anything behind it.
local SURFACE_MARGIN = 1e-3

export type PierceStopReason = "Exhausted" | "Clear" | "MaxHits" | "Terrain" | "Rejected"

export type PierceContact = {
	Instance: BasePart,
	Entity: Instance?,
	Zone: string?,
	Position: Vector3,
	Normal: Vector3,
	Material: Enum.Material,
	Distance: number,
	-- Exit and Thickness are nil when measurement is off, or when the part is
	-- deeper than MaxThickness so the back probe never reached its far face.
	Exit: Vector3?,
	Thickness: number?,
	Index: number,
	PowerBefore: number,
}

export type PierceHit = {
	Instance: BasePart,
	Entity: Instance?,
	Zone: string?,
	Position: Vector3,
	Normal: Vector3,
	Material: Enum.Material,
	Distance: number,
	Exit: Vector3?,
	Thickness: number?,
	Index: number,
	PowerBefore: number,
	Cost: number,
	PowerAfter: number,
}

export type PierceStats = {
	Raycasts: number,
	ThicknessProbes: number,
	-- Terrain runs measured through voxels, and the ReadVoxels calls they cost.
	TerrainSpans: number,
	VoxelReads: number,
	Contacts: number,
	Hits: number,
	PowerUsed: number,
	PowerRemaining: number,
	Stopped: PierceStopReason,
	TimeMs: number,
}

export type PierceOptions = {
	Origin: Types.CastOrigin,
	Direction: Vector3,
	Distance: number,
	Shape: Types.CastShape?,
	Filter: FilterClass.Filter?,
	Params: RaycastParams?,
	WorldRoot: WorldRoot?,
	EntityResolver: Types.EntityResolver?,
	ZoneResolver: Types.ZoneResolver?,
	-- Budget spent on every contact. With the default cost function it is
	-- measured in studs of material crossed.
	Power: number,
	-- Returns what this contact costs. Unmeasured thickness falls back to the
	-- full remaining power, so an unknown wall stops the shot rather than
	-- letting it through for free.
	Cost: ((contact: PierceContact) -> number)?,
	MaxHits: number?,
	MeasureThickness: boolean?,
	MaxThickness: number?,
	-- Terrain is one Instance, so it cannot be excluded to look past it. Reading
	-- its voxels gives a thickness to charge and an exit to resume from, which
	-- is the only way a shot can cross it. Off, terrain stays terminal.
	PierceTerrain: boolean?,
	Terrain: TerrainProbe.SampleOptions?,
}

local function fail(message: string, code: string?): never
	return Errors.raise("VirtualHit.pierce", code or "InvalidArgument", message, 3)
end

-- `table.freeze` returns a read-only view of its argument. That is the truth
-- about the value the caller gets, but not about the record the query filled in
-- field by field on the way here, whose type has to stay writable. This freezes
-- at runtime and hands the declared type back: the same table either way, with
-- one cast in one place instead of one at every return.
local function frozen<T>(value: T): T
	return (table.freeze(value :: any) :: any) :: T
end

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function positiveInteger(value: any, name: string, defaultValue: number): number
	if value == nil then
		return defaultValue
	end

	if type(value) ~= "number" or not isFiniteNumber(value) or value <= 0 or value % 1 ~= 0 then
		fail(`options.{name} must be a positive integer`)
	end

	return value
end

-- Measures how deep the contact went by casting back through the part from a
-- point beyond it. A ray never registers the part it starts inside, so a probe
-- that begins inside a part deeper than MaxThickness simply returns nothing --
-- which is exactly the "too thick to measure" answer.
-- How far a shot travels inside one part, measured by casting back at it from
-- beyond its far face. Exported because the impact solver asks the same
-- question, and two implementations of "how thick is this" would drift.
function Pierce.measureThickness(
	worldRoot: WorldRoot,
	part: BasePart,
	entry: Vector3,
	direction: Vector3,
	maxThickness: number
): (Vector3?, number?)
	local probeParams = RaycastParams.new()
	probeParams.FilterType = Enum.RaycastFilterType.Include
	probeParams.FilterDescendantsInstances = { part }
	probeParams.RespectCanCollide = false
	probeParams.IgnoreWater = true

	local backOrigin = entry + direction * maxThickness
	local result = worldRoot:Raycast(backOrigin, -direction * maxThickness, probeParams)

	if result == nil or result.Instance ~= part then
		return nil, nil
	end

	local exit = result.Position
	local thickness = (exit - entry).Magnitude

	if thickness < 0 or not isFiniteNumber(thickness) then
		return nil, nil
	end

	return exit, thickness
end

function Pierce.perform(options: PierceOptions): ({ PierceHit }, PierceStats)
	if type(options) ~= "table" then
		fail("expected an options table")
	end

	local power = options.Power

	if type(power) ~= "number" or not isFiniteNumber(power) or power <= 0 then
		fail("options.Power must be a finite number greater than zero")
	end

	if options.Cost ~= nil and type(options.Cost) ~= "function" then
		fail("options.Cost must be a function")
	end

	if options.MeasureThickness ~= nil and type(options.MeasureThickness) ~= "boolean" then
		fail("options.MeasureThickness must be a boolean")
	end

	local startedAt = os.clock()
	local maxHits = positiveInteger(options.MaxHits, "MaxHits", Tuning.MaxHits)
	local maxThickness: number = Tuning.MaxThickness
	local suppliedThickness = options.MaxThickness

	if suppliedThickness ~= nil then
		if
			type(suppliedThickness) ~= "number"
			or not isFiniteNumber(suppliedThickness)
			or suppliedThickness <= 0
		then
			fail("options.MaxThickness must be a finite number greater than zero")
		end

		maxThickness = suppliedThickness
	end

	local measure = options.MeasureThickness ~= false
	local costOf = options.Cost

	-- Cast.prepare does every shape, direction and range check, and resolves the
	-- Filter into params and a predicate exactly as a single cast would.
	local prepared = Cast.prepare({
		Origin = options.Origin,
		Direction = options.Direction,
		Distance = options.Distance,
		Shape = options.Shape,
		Filter = options.Filter,
		Params = options.Params,
		WorldRoot = options.WorldRoot,
		EntityResolver = options.EntityResolver,
		ZoneResolver = options.ZoneResolver,
	})

	local worldRoot = prepared.WorldRoot
	local direction = prepared.Direction
	local predicate = prepared.Predicate
	local params = prepared.Params
	local includeTagged = params ~= nil and params.BruteForceAllSlow
	local probes, probeCount = InternalExclusions.Acquire(worldRoot, includeTagged)

	if probeCount > 0 then
		params = Params.withRaycastExclusions(params, probes)
	end

	InternalExclusions.Release(probes)

	local hits: { PierceHit } = {}
	local stats: PierceStats = {
		Raycasts = 0,
		ThicknessProbes = 0,
		TerrainSpans = 0,
		VoxelReads = 0,
		Contacts = 0,
		Hits = 0,
		PowerUsed = 0,
		PowerRemaining = power,
		Stopped = "Clear",
		TimeMs = 0,
	}

	local remainingPower = power
	-- How far the cast origin has already been pushed forward. Parts are left
	-- behind by excluding them, but terrain cannot be excluded without removing
	-- all of it, so crossing terrain means moving the origin past its far face.
	local travelled = 0

	if options.PierceTerrain ~= nil and type(options.PierceTerrain) ~= "boolean" then
		fail("options.PierceTerrain must be a boolean")
	end

	local pierceTerrain = options.PierceTerrain == true
	-- An allowlist names the only things the shot may hit, so parts cannot be
	-- taken out of it to look past them. The cast origin moves instead.
	--
	-- No params at all is a query against everything, which is a blocklist with
	-- nothing on it rather than an allowlist. Reading FilterType off nothing was
	-- a crash on the one call shape that names no filter: pierce with neither a
	-- Filter nor Params.
	local allowlist = params ~= nil and params.FilterType == Enum.RaycastFilterType.Include

	while true do
		local reach = prepared.Distance - travelled

		if reach <= 0 then
			stats.Stopped = "Clear"
			break
		end

		local segment = Cast.advanced(prepared, travelled)
		stats.Raycasts += 1
		local result = Cast.query(segment, params)

		if result == nil then
			stats.Stopped = "Clear"
			break
		end

		stats.Contacts += 1
		local part = result.Instance

		if predicate ~= nil then
			local accepted = predicate(part)

			if type(accepted) ~= "boolean" then
				fail("Filter predicate must return a boolean", "CallbackContract")
			end

			if not accepted then
				if part:IsA("Terrain") then
					-- Terrain is one Instance; excluding it would remove all of
					-- it from the query, so a rejected Terrain contact ends here.
					stats.Stopped = "Rejected"
					break
				end

				if allowlist then
					travelled = math.max(
						travelled + result.Distance + SURFACE_MARGIN,
						travelled + SURFACE_MARGIN
					)
				else
					params = Params.withRaycastExclusions(params, { part })
				end

				continue
			end
		end

		local exit: Vector3? = nil
		local thickness: number? = nil
		local material = result.Material
		local isTerrain = part:IsA("Terrain")

		if isTerrain then
			if pierceTerrain then
				stats.TerrainSpans += 1
				stats.VoxelReads += 1
				local span = TerrainProbe.sampleAlong(
					result.Position,
					direction,
					maxThickness,
					options.Terrain
				)

				if span ~= nil then
					exit = span.Exit
					thickness = span.Thickness
					-- The voxel material is the truthful one for a run: a
					-- raycast reports the surface it touched, not what fills
					-- the volume behind it.
					material = span.Material
				end
			end
		elseif measure then
			stats.ThicknessProbes += 1
			stats.Raycasts += 1
			exit, thickness =
				Pierce.measureThickness(worldRoot, part, result.Position, direction, maxThickness)
		end

		local contact: PierceContact = frozen({
			Instance = part,
			Entity = Resolver.resolve(part, options.EntityResolver),
			Zone = Resolver.resolveZone(part, options.ZoneResolver),
			Position = result.Position,
			Normal = result.Normal,
			Material = material,
			Distance = travelled + result.Distance,
			Exit = exit,
			Thickness = thickness,
			Index = #hits + 1,
			PowerBefore = remainingPower,
		})

		local cost: number

		if costOf ~= nil then
			cost = costOf(contact)

			if type(cost) ~= "number" or not isFiniteNumber(cost) or cost < 0 then
				fail("options.Cost must return a non-negative finite number", "CallbackContract")
			end
		elseif thickness ~= nil then
			cost = thickness
		else
			-- Unmeasured material is treated as impassable rather than free.
			cost = remainingPower
		end

		remainingPower -= cost
		stats.PowerUsed += math.min(cost, contact.PowerBefore)
		stats.PowerRemaining = math.max(remainingPower, 0)

		table.insert(hits, {
			Instance = contact.Instance,
			Entity = contact.Entity,
			Zone = contact.Zone,
			Position = contact.Position,
			Normal = contact.Normal,
			Material = contact.Material,
			Distance = contact.Distance,
			Exit = contact.Exit,
			Thickness = contact.Thickness,
			Index = contact.Index,
			PowerBefore = contact.PowerBefore,
			Cost = cost,
			PowerAfter = remainingPower,
		})
		stats.Hits += 1

		if isTerrain and exit == nil then
			-- Terrain cannot be excluded, so without a measured far face there is
			-- nowhere to resume from. That is a wall, and saying so is more use
			-- than reporting the budget the wall happened to consume.
			stats.Stopped = "Terrain"
			break
		end

		if remainingPower <= 0 then
			stats.Stopped = "Exhausted"
			break
		end

		if #hits >= maxHits then
			-- The budget survived but the hit cap did not, so there may still be
			-- material in front of the shot that was never examined.
			stats.Stopped = "MaxHits"
			break
		end

		if isTerrain then
			-- Step just past the far face so the next cast starts outside the
			-- run rather than immediately inside it again.
			local farFace = exit :: Vector3
			travelled = (farFace - prepared.Origin):Dot(direction) + Tuning.TerrainExitMargin
		elseif allowlist then
			-- An allowlist cannot be added to, so the only way past a part is
			-- to resume beyond it. Its far face when it was measured, and a
			-- hair past the near face when it was not.
			-- Read back through a fresh optional binding: the terrain guard
			-- above proves a far face exists only when this is terrain, and it
			-- is not.
			local farFace: Vector3? = exit
			local resume = if farFace == nil
				then travelled + result.Distance + SURFACE_MARGIN
				else (farFace - prepared.Origin):Dot(direction) + SURFACE_MARGIN

			travelled = math.max(resume, travelled + SURFACE_MARGIN)
		else
			params = Params.withRaycastExclusions(params, { part })
		end
	end

	stats.TimeMs = (os.clock() - startedAt) * 1_000
	return hits, frozen(stats)
end

return Pierce
