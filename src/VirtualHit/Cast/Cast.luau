--!strict

local Workspace = game:GetService("Workspace")

local Types = require(script.Parent.Parent.Types)
local FilterClass = require(script.Parent.Parent.Collision.Filter)
local InternalExclusions = require(script.Parent.Parent.Collision.InternalExclusions)
local Params = require(script.Parent.Parent.Collision.Params)
local ShapeProbe = require(script.Parent.Parent.Collision.ShapeProbe)
local Shapes = require(script.Parent.Shapes)
local Errors = require(script.Parent.Parent.Util.Errors)
local Config = require(script.Parent.Parent.Config)

-- Live config sections. Read through them so VirtualHit.configure()
-- takes effect without reloading the library.
local Limits = Config.Limits

local MIN_DIRECTION_MAGNITUDE = 1e-4
local UNIT_DIRECTION_TOLERANCE = 1e-4

local Cast = {}

export type CastOptions = {
	Origin: Types.CastOrigin,
	Direction: Vector3,
	Distance: number,

	Shape: Types.CastShape?,
	Filter: FilterClass.Filter?,
	Params: RaycastParams?,
	WorldRoot: WorldRoot?,

	EntityResolver: Types.EntityResolver?,
	ZoneResolver: Types.ZoneResolver?,
}

export type PreparedCast = {
	Origin: Vector3,
	OriginCFrame: CFrame?,
	Direction: Vector3,
	Distance: number,
	Vector: Vector3,
	Shape: Types.CastShape,
	Params: RaycastParams?,
	WorldRoot: WorldRoot,
	Predicate: Types.Predicate?,
	MaxPredicateRetries: number,
}

-- Read-only because it is handed out frozen: `cast` builds it, freezes it and
-- returns it, and nothing on either side of that has a reason to write to it.
export type PredicateRetriesTruncation = {
	read Truncated: true,
	read Reason: "PredicateRetries",
	read Certain: false,
	read Rejected: number,
	read Allowed: number,
}

export type CastTruncation = PredicateRetriesTruncation

local DEFAULT_SHAPE = Shapes.Ray()
-- Enough for a predicate casting from inside a cast, and small enough that a
-- burst of concurrent casts cannot pin memory.
local MAX_IDLE_DESCRIPTORS = 8
-- Enough to clear the surface just struck without skipping anything behind it.
local SURFACE_MARGIN = 1e-3

local function fail(message: string, code: string?): never
	return Errors.raise("VirtualHit.cast", code or "InvalidArgument", message, 4)
end

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function isFiniteVector3(value: Vector3): boolean
	return isFiniteNumber(value.X) and isFiniteNumber(value.Y) and isFiniteNumber(value.Z)
end

-- Reads the twelve components into locals rather than packing them into a
-- table. The table was the only allocation on Step's validation path, and Step
-- is the hot one: two per call, per sweep, per frame.
local function isFiniteCFrame(value: CFrame): boolean
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = value:GetComponents()

	return isFiniteNumber(x)
		and isFiniteNumber(y)
		and isFiniteNumber(z)
		and isFiniteNumber(r00)
		and isFiniteNumber(r01)
		and isFiniteNumber(r02)
		and isFiniteNumber(r10)
		and isFiniteNumber(r11)
		and isFiniteNumber(r12)
		and isFiniteNumber(r20)
		and isFiniteNumber(r21)
		and isFiniteNumber(r22)
end

function Cast.alignedCFrame(position: Vector3, direction: Vector3): CFrame
	local up = Vector3.yAxis

	-- Avoid a degenerate lookAt basis when the cast is almost vertical.
	if math.abs(direction:Dot(up)) > 0.999 then
		up = Vector3.zAxis
	end

	return CFrame.lookAt(position, position + direction, up)
end

local function validateShape(shape: Types.CastShape)
	if type(shape) ~= "table" then
		fail("options.Shape must come from VirtualHit.Shapes")
	end

	if shape.Type == "Ray" then
		return
	elseif shape.Type == "Sphere" then
		local radius = shape.Radius

		if type(radius) ~= "number" or not isFiniteNumber(radius) then
			fail("Sphere shape Radius must be a finite number")
		end

		if radius < (Limits.MinPhysicalAxis * 0.5) then
			fail(`Sphere shape Radius must be at least {(Limits.MinPhysicalAxis * 0.5)} studs`)
		end

		if radius > Limits.MaxSphereRadius then
			fail(`Sphere shape Radius cannot exceed {Limits.MaxSphereRadius} studs`)
		end
	elseif shape.Type == "Block" then
		local size = shape.Size

		if typeof(size) ~= "Vector3" or not isFiniteVector3(size) then
			fail("Block shape Size must be a finite Vector3")
		end

		if
			size.X < Limits.MinPhysicalAxis
			or size.Y < Limits.MinPhysicalAxis
			or size.Z < Limits.MinPhysicalAxis
		then
			fail(`every Block shape Size axis must be at least {Limits.MinPhysicalAxis} studs`)
		end

		if
			size.X > Limits.MaxBlockAxis
			or size.Y > Limits.MaxBlockAxis
			or size.Z > Limits.MaxBlockAxis
		then
			fail(`no Block shape Size axis can exceed {Limits.MaxBlockAxis} studs`)
		end
	elseif shape.Type == "Part" then
		local part = shape.Part

		if typeof(part) ~= "Instance" or not part:IsA("BasePart") or part:IsA("Terrain") then
			fail("Part shape must contain a non-Terrain BasePart")
		end

		if typeof(shape.Offset) ~= "CFrame" or not isFiniteCFrame(shape.Offset) then
			fail("Part shape Offset must be a finite CFrame")
		end
	else
		fail(`unsupported Shape type {tostring((shape :: any).Type)}`)
	end
end

local function resolveParams(options: CastOptions): RaycastParams?
	if options.Filter ~= nil and options.Params ~= nil then
		fail("options.Filter and options.Params are mutually exclusive")
	end

	if options.Params ~= nil then
		if typeof(options.Params) ~= "RaycastParams" then
			fail("options.Params must be a RaycastParams")
		end

		return options.Params
	end

	local filter = options.Filter

	if filter ~= nil then
		if type(filter) ~= "table" or type((filter :: any)._leaseRaycastParams) ~= "function" then
			fail("options.Filter must be created with VirtualHit.Filter.new()")
		end

		-- Leased, not built: the same weapon firing every frame gets the same
		-- params object back until the filter itself changes. Nothing here mutates
		-- it; every path that adds exclusions clones first.
		local params = filter:_leaseRaycastParams()

		if typeof(params) ~= "RaycastParams" then
			fail("options.Filter must produce a RaycastParams")
		end

		return params
	end

	return nil
end

-- `into` is for the pool below: given a table, the ten fields are written into
-- it rather than into a new one. Callers outside this file always get a fresh
-- descriptor, because they keep the one they are given.
function Cast.prepare(options: CastOptions, into: PreparedCast?): PreparedCast
	if type(options) ~= "table" then
		fail("expected an options table")
	end

	local rawOrigin = options.Origin
	local origin: Vector3
	local providedCFrame: CFrame? = nil

	if typeof(rawOrigin) == "Vector3" then
		if not isFiniteVector3(rawOrigin) then
			fail("options.Origin must contain only finite values")
		end

		origin = rawOrigin
	elseif typeof(rawOrigin) == "CFrame" then
		if not isFiniteCFrame(rawOrigin) then
			fail("options.Origin must contain only finite values")
		end

		origin = rawOrigin.Position
		providedCFrame = rawOrigin
	else
		fail("options.Origin must be a Vector3 or CFrame")
	end

	local rawDirection = options.Direction

	if typeof(rawDirection) ~= "Vector3" or not isFiniteVector3(rawDirection) then
		fail("options.Direction must be a finite Vector3")
	end

	local magnitude = rawDirection.Magnitude

	if not isFiniteNumber(magnitude) or magnitude <= MIN_DIRECTION_MAGNITUDE then
		fail("options.Direction must be non-zero")
	end

	if math.abs(magnitude - 1) > UNIT_DIRECTION_TOLERANCE then
		fail("options.Direction must be a unit vector; put cast range in options.Distance")
	end

	local direction = rawDirection / magnitude
	local distance = options.Distance

	if type(distance) ~= "number" or not isFiniteNumber(distance) then
		fail("options.Distance must be a finite number")
	end

	if distance <= 0 then
		fail("options.Distance must be greater than zero")
	end

	local shape = options.Shape or DEFAULT_SHAPE
	validateShape(shape)

	local maxDistance = if shape.Type == "Ray"
		then Limits.MaxRayDistance
		else Limits.MaxShapecastDistance

	if distance > maxDistance then
		fail(`options.Distance cannot exceed {maxDistance} studs for a {shape.Type} cast`)
	end

	if options.EntityResolver ~= nil and type(options.EntityResolver) ~= "function" then
		fail("options.EntityResolver must be a function")
	end

	if options.ZoneResolver ~= nil and type(options.ZoneResolver) ~= "function" then
		fail("options.ZoneResolver must be a function")
	end

	local worldRoot = options.WorldRoot

	if worldRoot == nil then
		worldRoot = Workspace
	elseif typeof(worldRoot) ~= "Instance" or not worldRoot:IsA("WorldRoot") then
		fail("options.WorldRoot must be a Workspace or WorldModel")
	end

	local originCFrame: CFrame? = nil

	if shape.Type == "Block" then
		-- A CFrame origin preserves the caller's full block orientation. Vector3
		-- keeps the compact API and derives a stable orientation from travel.
		originCFrame = providedCFrame or Cast.alignedCFrame(origin, direction)
	elseif shape.Type == "Part" then
		originCFrame = ShapeProbe.cframeForOrigin(shape.Part, rawOrigin, shape.Offset)
	end

	local predicate: Types.Predicate? = nil
	local maxPredicateRetries = 0
	local filter = options.Filter

	if filter ~= nil then
		predicate = filter:GetPredicate()
		maxPredicateRetries = filter:GetMaxPredicateRetries()
	end

	if into == nil then
		return {
			Origin = origin,
			OriginCFrame = originCFrame,
			Direction = direction,
			Distance = distance,
			Vector = direction * distance,
			Shape = shape,
			Params = resolveParams(options),
			WorldRoot = worldRoot :: WorldRoot,
			Predicate = predicate,
			MaxPredicateRetries = maxPredicateRetries,
		}
	end

	-- Same ten fields, written into a table that already has room for them.
	-- Listed twice rather than built once and copied: a copy would allocate the
	-- thing this exists to avoid.
	into.Origin = origin
	into.OriginCFrame = originCFrame
	into.Direction = direction
	into.Distance = distance
	into.Vector = direction * distance
	into.Shape = shape
	into.Params = resolveParams(options)
	into.WorldRoot = worldRoot :: WorldRoot
	into.Predicate = predicate
	into.MaxPredicateRetries = maxPredicateRetries

	return into
end

--[[
	One descriptor per cast was the only allocation left on this path, and a
	cast is the hottest call the library has.

	The list hands the same tables back instead of building one per shot.
	`perform` is the only borrower and returns what it took before it returns to
	its caller, so nothing outside this file ever sees a pooled descriptor. A
	predicate that casts from inside a cast simply takes the next one, which is
	why this is a list and not a single scratch record.
]]
local descriptors: { PreparedCast } = {}
local idleDescriptors = 0

local function acquireDescriptor(options: CastOptions): PreparedCast
	if idleDescriptors == 0 then
		return Cast.prepare(options)
	end

	local record = descriptors[idleDescriptors]
	descriptors[idleDescriptors] = nil
	idleDescriptors -= 1

	return Cast.prepare(options, record)
end

local function releaseDescriptor(record: PreparedCast)
	if idleDescriptors >= MAX_IDLE_DESCRIPTORS then
		return
	end

	idleDescriptors += 1
	descriptors[idleDescriptors] = record
end

-- Exposed so pierce() can drive the same shape dispatch without duplicating it.
function Cast.query(prepared: PreparedCast, params: RaycastParams?): RaycastResult?
	local shape = prepared.Shape
	local worldRoot = prepared.WorldRoot
	local includeTagged = params ~= nil and params.BruteForceAllSlow

	if shape.Type == "Ray" then
		if params then
			return worldRoot:Raycast(prepared.Origin, prepared.Vector, params)
		end

		return worldRoot:Raycast(prepared.Origin, prepared.Vector)
	elseif shape.Type == "Sphere" then
		if params then
			return worldRoot:Spherecast(prepared.Origin, shape.Radius, prepared.Vector, params)
		end

		return worldRoot:Spherecast(prepared.Origin, shape.Radius, prepared.Vector)
	elseif shape.Type == "Block" then
		local originCFrame = prepared.OriginCFrame
		assert(originCFrame ~= nil, "Block casts must have an origin CFrame")

		if params then
			return worldRoot:Blockcast(originCFrame, shape.Size, prepared.Vector, params)
		end

		return worldRoot:Blockcast(originCFrame, shape.Size, prepared.Vector)
	elseif shape.Type == "Part" then
		local originCFrame = prepared.OriginCFrame
		assert(originCFrame ~= nil, "Part casts must have an origin CFrame")

		local probe = ShapeProbe.create(shape.Part, worldRoot, originCFrame)
		local success, result = pcall(function()
			local exclusions = InternalExclusions.Acquire(worldRoot, includeTagged)
			table.insert(exclusions, shape.Part)
			local partParams = Params.withRaycastExclusions(params, exclusions)
			InternalExclusions.Release(exclusions)
			return worldRoot:Shapecast(probe, prepared.Vector, partParams)
		end)
		probe:Destroy()

		if not success then
			error(result, 0)
		end

		return result
	else
		return fail(`unhandled prepared Shape type {tostring((shape :: any).Type)}`)
	end
end

-- Re-aims a prepared cast further along its own direction. Some queries cannot
-- leave a part behind by excluding it — an allowlist has nothing to add to, and
-- Terrain is one Instance — so they resume from beyond it instead.
function Cast.advanced(prepared: PreparedCast, offset: number): PreparedCast
	if offset <= 0 then
		return prepared
	end

	local distance = prepared.Distance - offset
	local originCFrame = prepared.OriginCFrame

	return {
		Origin = prepared.Origin + prepared.Direction * offset,
		OriginCFrame = if originCFrame == nil
			then nil
			else originCFrame + prepared.Direction * offset,
		Direction = prepared.Direction,
		Distance = distance,
		Vector = prepared.Direction * distance,
		Shape = prepared.Shape,
		Params = prepared.Params,
		WorldRoot = prepared.WorldRoot,
		Predicate = prepared.Predicate,
		MaxPredicateRetries = prepared.MaxPredicateRetries,
	}
end

-- Reports as a value pack rather than a record: the caller reads all five and
-- keeps none of them, and a record per cast is a record per shot fired. The
-- last value is how far the cast origin had been advanced when the result was
-- found -- zero unless an allowlist forced the retry loop to resume past a
-- rejected part instead of excluding it.
function Cast.perform(options: CastOptions): (RaycastResult?, number, number, boolean, number)
	local prepared = acquireDescriptor(options)
	local worldRoot = prepared.WorldRoot
	local params = prepared.Params
	local includeTagged = params ~= nil and params.BruteForceAllSlow
	local probes, probeCount = InternalExclusions.Acquire(worldRoot, includeTagged)

	if probeCount > 0 then
		params = Params.withRaycastExclusions(params, probes)
	end

	InternalExclusions.Release(probes)

	local predicate = prepared.Predicate

	if predicate == nil then
		local result = Cast.query(prepared, params)
		releaseDescriptor(prepared)

		return result, 0, 0, false, 0
	end

	-- A rejected part is left behind and the cast is repeated, so the caller gets
	-- the first hit the predicate accepts rather than a silent miss. Each retry
	-- is a full extra engine query; the retry budget lives on the Filter.
	--
	-- An allowlist has nothing to add to, so there the cast resumes past the
	-- rejected contact rather than excluding it.
	local rejected = 0
	local allowed = prepared.MaxPredicateRetries
	local allowlist = params ~= nil and params.FilterType == Enum.RaycastFilterType.Include
	local travelled = 0

	while true do
		local segment = if travelled > 0 then Cast.advanced(prepared, travelled) else prepared

		if segment.Distance <= 0 then
			releaseDescriptor(prepared)

			return nil, rejected, allowed, false, travelled
		end

		local result = Cast.query(segment, params)

		if result == nil then
			releaseDescriptor(prepared)

			return nil, rejected, allowed, false, travelled
		end

		local accepted = predicate(result.Instance)

		if type(accepted) ~= "boolean" then
			fail("Filter predicate must return a boolean", "CallbackContract")
		end

		if accepted then
			releaseDescriptor(prepared)

			return result, rejected, allowed, false, travelled
		end

		rejected += 1

		if rejected > allowed then
			-- The budget ran out with a rejected part still in front. There may
			-- be an acceptable hit behind it, so this is reported as an
			-- uncertain truncation instead of a clean miss.
			releaseDescriptor(prepared)

			return nil, rejected, allowed, true, travelled
		end

		if allowlist then
			travelled += result.Distance + SURFACE_MARGIN
		else
			params = Params.withRaycastExclusions(params, { result.Instance })
		end
	end
end

return Cast
