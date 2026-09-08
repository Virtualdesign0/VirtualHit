--!strict

local Workspace = game:GetService("Workspace")

local Types = require(script.Parent.Parent.Types)
local FilterClass = require(script.Parent.Parent.Collision.Filter)
local Shapes = require(script.Parent.Parent.Cast.Shapes)
local HitPolicy = require(script.Parent.Parent.Sweep.HitPolicy)
local SweepClass = require(script.Parent.Parent.Sweep.Sweep)
local DetailFieldClass = require(script.Parent.Parent.Detail.DetailField)
local Signal = require(script.Parent.Parent.Util.Signal)
local RuntimeClass = require(script.Parent.Parent.Melee.Runtime)
local RicochetClass = require(script.Parent.Ricochet)
local ImpactSolverClass = require(script.Parent.Parent.Impact.ImpactSolver)
local StopReason = require(script.Parent.StopReason)
local Errors = require(script.Parent.Parent.Util.Errors)
local Config = require(script.Parent.Parent.Config)

-- Live config section. Read through it so VirtualHit.configure() takes
-- effect without reloading the library.
local Tuning = Config.Projectile

-- A projectile is a Sweep with an integrator in front of it. Every substep
-- becomes one Sweep:Step between the previous and the next pose, so a flying
-- shape inherits compound members, deterministic ordering, hit policies,
-- HitResponse blockers and truncation diagnostics unchanged.

local DEFAULT_SHAPE = Shapes.Sphere(0.1)
local MIN_SPEED = 1e-4

export type ProjectileStopReason = StopReason.StopReason
export type RicochetOptions = RicochetClass.RicochetOptions
export type RicochetContext = RicochetClass.RicochetContext

export type ProjectileOptions = {
	Origin: Types.CastOrigin,
	-- Either a full Velocity, or a unit Direction with a Speed. Mixing range
	-- into the direction vector is rejected the same way cast() rejects it.
	Velocity: Vector3?,
	Direction: Vector3?,
	Speed: number?,

	Shape: Types.SweepShape?,
	Offset: CFrame?,
	-- Keeps the shape pointed along travel. A sphere does not care; a capsule
	-- or a Part-shaped dart does.
	Align: boolean?,

	Gravity: Vector3?,
	-- Linear drag: acceleration gains -Drag * velocity. Zero disables it.
	Drag: number?,

	Filter: FilterClass.Filter?,
	RaycastParams: RaycastParams?,
	OverlapParams: OverlapParams?,
	WorldRoot: WorldRoot?,
	EntityResolver: Types.EntityResolver?,
	ZoneResolver: Types.ZoneResolver?,
	HitPolicy: HitPolicy.Policy?,
	HitKey: SweepClass.HitKey?,
	Registry: SweepClass.HitRegistry?,
	HitResponse: SweepClass.HitResponder?,
	HitPriority: SweepClass.HitPriority?,
	ProbeFree: boolean?,
	-- Scales the step limits by distance to the nearest observer. See
	-- VirtualHit.detail().
	Detail: DetailFieldClass.DetailField?,
	-- Decides what a blocker does to this shot: through, off, or stop. Without
	-- one a blocker is terminal unless Ricochet turns it into a bounce.
	Impact: ImpactSolverClass.ImpactSolver?,
	Mass: number?,
	Caliber: number?,
	-- Surfaces one shot may cross. Zero makes every blocker terminal again.
	MaxPenetrations: number?,
	Sweep: SweepClass.SweepConfig?,

	MaxDistance: number?,
	MaxLifetime: number?,
	-- Caps how far the shape may travel in one integration substep, which is
	-- what keeps a fast projectile from tunnelling between frames.
	MaxSubstepDistance: number?,
	MaxSubstepsPerStep: number?,
	Ricochet: RicochetOptions?,
	Priority: number?,
}

export type ProjectileStats = {
	Substeps: number,
	RequiredSubsteps: number,
	Distance: number,
	Elapsed: number,
	Hits: number,
	Bounces: number,
	Penetrations: number,
	ShapeCasts: number,
	OverlapQueries: number,
	Truncated: boolean,
	TimeMs: number,
}

export type ProjectileTruncation = {
	Truncated: true,
	Reason: "MaxSubstepsPerStep",
	Certain: true,
	-- The substep budget ran out with frame time left over. The count is a
	-- lower bound because the unsimulated remainder may need more substeps
	-- than the one that was refused.
	RequiredAtLeast: number,
	Allowed: number,
	UnsimulatedTime: number,
}

local Projectile = {}
Projectile.__index = Projectile

export type ImpactLimit = "Penetrations" | "Bounces"

-- What the surface said, and what this body did about it.

-- Those are two different answers and reporting one of them as the other is a
-- lie either way round. The solver says a round went through a pane of glass;
-- the flight says this was its fourth pane and the budget is three. Firing the
-- solver's "Penetrate" would have a listener spawn an exit hole for a shot
-- that stopped, and firing a bare "Stop" would have it spawn the wrong decal
-- for a surface that offered no resistance at all.
export type ProjectileImpact = {
	-- The physics, untouched. Result.Action is what the surface did.
	read Result: ImpactSolverClass.ImpactResult,
	-- What the body actually did, once the flight's own budget has had a say.
	-- Equal to Result.Action unless Limit is set.
	read Action: ImpactSolverClass.Action,
	-- Which budget overruled the physics, when one did.
	read Limit: ImpactLimit?,
}

-- What the body is standing inside right now, if anything: the plate it just
-- crossed, which stops being a blocker until the body has left it. See the note
-- in the constructor.
type Crossing = {
	Instance: BasePart?,
	Seen: boolean,
}

export type Projectile = typeof(setmetatable(
	{} :: {
		Hit: Signal.Signal<Types.SweepHit>,
		Blocked: Signal.Signal<Types.SweepBlock>,
		Ricochet: Signal.Signal<RicochetContext, Vector3>,
		-- Fired for every resolved impact when an ImpactSolver is configured,
		-- whether the shot went through, glanced off or stopped. Ricochet still
		-- fires for the older bounce-or-stop path.
		Impact: Signal.Signal<ProjectileImpact>,
		Started: Signal.VoidSignal,
		Stopped: Signal.Signal<StopReason.StopReason>,
		Error: Signal.Signal<string>,
		_sweep: SweepClass.Sweep,
		_crossing: Crossing,
		_worldRoot: WorldRoot,
		_runtime: RuntimeClass.Runtime,
		_position: Vector3,
		_velocity: Vector3,
		_rotation: CFrame,
		_align: boolean,
		_gravity: Vector3,
		_drag: number,
		_maxDistance: number,
		_maxLifetime: number,
		_maxSubstepDistance: number,
		_maxSubsteps: number,
		_ricochet: RicochetClass.ResolvedRicochet,
		_priority: number,
		_distance: number,
		_elapsed: number,
		_bounces: number,
		_stats: ProjectileStats,
		_hasStats: boolean,
		_statsSnapshot: ProjectileStats?,
		_truncation: ProjectileTruncation?,
		_pendingShapeCasts: number,
		_pendingOverlapQueries: number,
		_hasPendingCost: boolean,
		_stepping: boolean,
		_generation: number,
		_active: boolean,
		_destroyed: boolean,
		_hitEvent: Signal.Emitter<Types.SweepHit>,
		_blockedEvent: Signal.Emitter<Types.SweepBlock>,
		_ricochetEvent: Signal.Emitter<RicochetContext, Vector3>,
		_impactEvent: Signal.Emitter<ProjectileImpact>,
		_impact: ImpactSolverClass.ImpactSolver?,
		_mass: number,
		_caliber: number,
		_penetrations: number,
		_maxPenetrations: number,
		_startedEvent: Signal.VoidEmitter,
		_stoppedEvent: Signal.Emitter<StopReason.StopReason>,
		_errorEvent: Signal.Emitter<string>,
		_runtimeStep: (deltaTime: number) -> (),
		_runtimeError: (message: string) -> (),
		_runtimeCost: RuntimeClass.CostReader,
	},
	Projectile
))

local function fail(message: string, code: string?): never
	return Errors.raise("VirtualHit.projectile", code or "InvalidArgument", message, 3)
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

-- How many surfaces one shot may cross before the game stops paying for it.
-- Zero keeps the old behaviour: every blocker is terminal unless it glances.
local function penetrationBudget(value: any): number
	if value == nil then
		return Tuning.MaxPenetrations
	end

	if type(value) ~= "number" or not isFiniteNumber(value) or value < 0 or value % 1 ~= 0 then
		fail("options.MaxPenetrations must be a non-negative integer")
	end

	return value
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

local function nonNegativeNumber(value: any, name: string, defaultValue: number): number
	if value == nil then
		return defaultValue
	end

	if type(value) ~= "number" or not isFiniteNumber(value) or value < 0 then
		fail(`options.{name} must be a non-negative number`)
	end

	return value
end

local function positiveInteger(value: any, name: string, defaultValue: number): number
	local resolved = positiveNumber(value, name, defaultValue)

	if resolved % 1 ~= 0 then
		fail(`options.{name} must be an integer`)
	end

	return resolved
end

local function resolveWorldRoot(worldRoot: WorldRoot?): WorldRoot
	if worldRoot == nil then
		return Workspace
	end

	if typeof(worldRoot) ~= "Instance" or not worldRoot:IsA("WorldRoot") then
		fail("options.WorldRoot must be a Workspace or WorldModel")
	end

	return worldRoot :: WorldRoot
end

local function resolveLaunch(options: ProjectileOptions): Vector3
	local velocity = options.Velocity

	if velocity ~= nil then
		if options.Direction ~= nil or options.Speed ~= nil then
			fail("options.Velocity cannot be combined with options.Direction or options.Speed")
		end

		if typeof(velocity) ~= "Vector3" or not isFiniteVector3(velocity) then
			fail("options.Velocity must be a finite Vector3")
		end

		if velocity.Magnitude <= MIN_SPEED then
			fail("options.Velocity must be non-zero")
		end

		return velocity
	end

	local direction = options.Direction

	if typeof(direction) ~= "Vector3" or not isFiniteVector3(direction) then
		return fail("options.Direction must be a finite Vector3, or use options.Velocity")
	end

	local magnitude = direction.Magnitude

	if magnitude <= MIN_SPEED then
		fail("options.Direction must be non-zero")
	end

	if math.abs(magnitude - 1) > 1e-4 then
		fail("options.Direction must be a unit vector; put muzzle velocity in options.Speed")
	end

	local speed = options.Speed

	if type(speed) ~= "number" or not isFiniteNumber(speed) or speed <= 0 then
		return fail("options.Speed must be a finite number greater than zero")
	end

	return direction / magnitude * speed
end

-- Keeps a degenerate lookAt basis from appearing when travel is near vertical.
local function alignedRotation(direction: Vector3): CFrame
	local up = Vector3.yAxis

	if math.abs(direction:Dot(up)) > 0.999 then
		up = Vector3.zAxis
	end

	return CFrame.lookAt(Vector3.zero, direction, up).Rotation
end

local function createStats(): ProjectileStats
	return {
		Substeps = 0,
		RequiredSubsteps = 0,
		Distance = 0,
		Elapsed = 0,
		Hits = 0,
		Bounces = 0,
		Penetrations = 0,
		ShapeCasts = 0,
		OverlapQueries = 0,
		Truncated = false,
		TimeMs = 0,
	}
end

local function resetStats(stats: ProjectileStats)
	stats.Substeps = 0
	stats.RequiredSubsteps = 0
	stats.Distance = 0
	stats.Elapsed = 0
	stats.Hits = 0
	stats.Bounces = 0
	stats.Penetrations = 0
	stats.ShapeCasts = 0
	stats.OverlapQueries = 0
	stats.Truncated = false
	stats.TimeMs = 0
end

function Projectile.new(
	options: ProjectileOptions,
	runtimeOverride: RuntimeClass.Runtime?
): Projectile
	if type(options) ~= "table" then
		fail("expected an options table")
	end

	local rawOrigin = options.Origin
	local position: Vector3
	local originRotation = CFrame.identity

	if typeof(rawOrigin) == "Vector3" then
		if not isFiniteVector3(rawOrigin) then
			fail("options.Origin must contain only finite values")
		end

		position = rawOrigin
	elseif typeof(rawOrigin) == "CFrame" then
		if not isFiniteCFrame(rawOrigin) then
			fail("options.Origin must contain only finite values")
		end

		position = rawOrigin.Position
		originRotation = rawOrigin.Rotation
	else
		return fail("options.Origin must be a Vector3 or CFrame")
	end

	local velocity = resolveLaunch(options)
	local shape = if options.Shape == nil then DEFAULT_SHAPE else options.Shape

	if type(shape) == "table" and (shape :: any).Type == "Ray" then
		fail(
			"a projectile needs a volume; use Shapes.Sphere with a small radius instead of Shapes.Ray"
		)
	end

	local gravity = if options.Gravity == nil then Vector3.zero else options.Gravity

	if typeof(gravity) ~= "Vector3" or not isFiniteVector3(gravity) then
		fail("options.Gravity must be a finite Vector3")
	end

	if options.Align ~= nil and type(options.Align) ~= "boolean" then
		fail("options.Align must be a boolean")
	end

	local priority = options.Priority

	if priority ~= nil and (type(priority) ~= "number" or not isFiniteNumber(priority)) then
		fail("options.Priority must be a finite number")
	end

	local worldRoot = resolveWorldRoot(options.WorldRoot)
	local config: SweepClass.SweepConfig = if options.Sweep == nil then {} else options.Sweep

	if type(config) ~= "table" then
		fail("options.Sweep must be a table")
	end

	--[[
		A round that has just gone through a plate is, for a moment, still
		standing in it.

		The solver resumes the contact point past the far face, but the body's
		trailing side is behind that face until the round has flown its own
		width. The next step meets the same plate from inside, finds no far face
		to leave by, and stops the round in a wall it had already crossed --
		which is what a 0.4 stud pane was doing to a rifle round.

		So the plate it just crossed is ignored while the body is still inside
		it, and only while: the flag is cleared by the first step that does not
		meet it any more, which is exactly when the body is clear. Nothing is
		teleported, so nothing behind the plate is skipped over.

		Held in its own table because the sweep is built before the projectile
		exists, and the responder below closes over it.
	]]
	local crossing: Crossing = { Instance = nil, Seen = false }
	local responder = options.HitResponse
	local hitResponse: SweepClass.HitResponder? = if responder == nil
		then nil
		else function(candidate)
			if crossing.Instance ~= nil and candidate.Instance == crossing.Instance then
				crossing.Seen = true
				return "Ignore"
			end

			return (responder :: SweepClass.HitResponder)(candidate)
		end

	local sweep = SweepClass.new({
		Shape = shape,
		Offset = options.Offset,
		Filter = options.Filter,
		RaycastParams = options.RaycastParams,
		OverlapParams = options.OverlapParams,
		WorldRoot = worldRoot,
		EntityResolver = options.EntityResolver,
		ZoneResolver = options.ZoneResolver,
		HitPolicy = options.HitPolicy,
		HitKey = options.HitKey,
		Registry = options.Registry,
		HitResponse = hitResponse,
		HitPriority = options.HitPriority,
		ProbeFree = options.ProbeFree,
		MaxLinearStep = config.MaxLinearStep,
		MaxAngularStep = config.MaxAngularStep,
		MaxSegments = config.MaxSegments,
		Detail = options.Detail,
		MaxHitsPerSegment = config.MaxHitsPerSegment,
	})

	if
		options.Impact ~= nil
		and (type(options.Impact) ~= "table" or type((options.Impact :: any).Resolve) ~= "function")
	then
		fail("options.Impact must come from VirtualHit.impactSolver()")
	end

	-- Mass and calibre only mean anything to a solver, but they are read here so
	-- a body carries them whether one is configured or not: a caller that adds a
	-- solver later should not also have to move its ammunition definition.
	local mass = positiveNumber(options.Mass, "Mass", Tuning.Mass)
	local caliber = positiveNumber(options.Caliber, "Caliber", Tuning.Caliber)
	local maxPenetrations = penetrationBudget(options.MaxPenetrations)
	local align = options.Align ~= false
	local hitEvent: Signal.Emitter<Types.SweepHit> = Signal.new()
	local blockedEvent: Signal.Emitter<Types.SweepBlock> = Signal.new()
	local ricochetEvent: Signal.Emitter<RicochetContext, Vector3> = Signal.new()
	local impactEvent: Signal.Emitter<ImpactSolverClass.ImpactResult> = Signal.new()
	local startedEvent: Signal.VoidEmitter = Signal.new()
	local stoppedEvent: Signal.Emitter<StopReason.StopReason> = Signal.new()
	local errorEvent: Signal.Emitter<string> = Signal.new()

	local projectile = (
		setmetatable({
			Hit = hitEvent,
			Blocked = blockedEvent,
			Ricochet = ricochetEvent,
			Impact = impactEvent,
			Started = startedEvent,
			Stopped = stoppedEvent,
			Error = errorEvent,
			_sweep = sweep,
			_crossing = crossing,
			_worldRoot = worldRoot,
			_runtime = runtimeOverride or RuntimeClass.Default,
			_position = position,
			_velocity = velocity,
			_rotation = if align then alignedRotation(velocity.Unit) else originRotation,
			_align = align,
			_gravity = gravity,
			_drag = nonNegativeNumber(options.Drag, "Drag", 0),
			_maxDistance = positiveNumber(options.MaxDistance, "MaxDistance", Tuning.MaxDistance),
			_maxLifetime = positiveNumber(options.MaxLifetime, "MaxLifetime", Tuning.MaxLifetime),
			_maxSubstepDistance = positiveNumber(
				options.MaxSubstepDistance,
				"MaxSubstepDistance",
				Tuning.MaxSubstepDistance
			),
			_maxSubsteps = positiveInteger(
				options.MaxSubstepsPerStep,
				"MaxSubstepsPerStep",
				Tuning.MaxSubsteps
			),
			_ricochet = RicochetClass.resolve(options.Ricochet),
			_priority = priority or 0,
			_distance = 0,
			_elapsed = 0,
			_bounces = 0,
			_impactEvent = impactEvent,
			_impact = options.Impact,
			_mass = mass,
			_caliber = caliber,
			_penetrations = 0,
			_maxPenetrations = maxPenetrations,
			_stats = createStats(),
			_hasStats = false,
			_statsSnapshot = nil,
			_truncation = nil,
			_pendingShapeCasts = 0,
			_pendingOverlapQueries = 0,
			_hasPendingCost = false,
			_stepping = false,
			_generation = 0,
			_active = false,
			_destroyed = false,
			_hitEvent = hitEvent,
			_blockedEvent = blockedEvent,
			_ricochetEvent = ricochetEvent,
			_startedEvent = startedEvent,
			_stoppedEvent = stoppedEvent,
			_errorEvent = errorEvent,
		}, Projectile) :: any
	) :: Projectile

	projectile._runtimeStep = function(deltaTime: number)
		projectile:Step(deltaTime)
	end
	projectile._runtimeError = function(message: string)
		projectile:_handleRuntimeError(message)
	end
	projectile._runtimeCost = function(): (number?, number?)
		return projectile:_consumeRuntimeCost()
	end

	return projectile
end

function Projectile._pose(self: Projectile, position: Vector3, velocity: Vector3): CFrame
	if self._align and velocity.Magnitude > MIN_SPEED then
		return CFrame.new(position) * alignedRotation(velocity.Unit)
	end

	return CFrame.new(position) * self._rotation
end

function Projectile._consumeRuntimeCost(self: Projectile): (number?, number?)
	if not self._hasPendingCost then
		return nil, nil
	end

	self._hasPendingCost = false
	local shapeCasts = self._pendingShapeCasts
	local overlapQueries = self._pendingOverlapQueries
	self._pendingShapeCasts = 0
	self._pendingOverlapQueries = 0

	return shapeCasts, overlapQueries
end

local function deactivate(self: Projectile): boolean
	if not self._active then
		return false
	end

	self._active = false
	self._generation += 1
	self._runtime:Remove(self)
	return true
end

local function stopWithReason(self: Projectile, reason: StopReason.StopReason)
	if not deactivate(self) then
		return
	end

	self._stoppedEvent:Fire(reason)
end

function Projectile._handleRuntimeError(self: Projectile, message: string)
	if not deactivate(self) then
		return
	end

	self._stoppedEvent:Fire(StopReason.RuntimeError)
	self._errorEvent:Fire(message)
	warn(`VirtualHit projectile stopped after a runtime error:\n{message}`)
end

-- Closed form, not a stepping scheme.

-- Semi-implicit Euler would put the shape at p + v*dt + a*dt^2 instead of the
-- true p + v*dt + a*dt^2/2, and that half-step error accumulates as
-- 0.5 * a * T * dt over a flight of length T. At Roblox gravity and 60 Hz that
-- is about 1.6 studs of drop after one second, which is a whole head. It would
-- also mean Ballistics could not describe the same curve the projectile flies.

-- Constant acceleration is exact. Linear drag has an exact solution too:
-- dv/dt = g - k*v settles towards the terminal velocity g/k, so both position
-- and velocity are analytic and the flight is frame-rate independent.
local function integrate(self: Projectile, dt: number): (Vector3, Vector3)
	local gravity = self._gravity
	local drag = self._drag
	local velocity = self._velocity

	if drag <= 0 then
		return self._position + velocity * dt + gravity * (0.5 * dt * dt), velocity + gravity * dt
	end

	local terminal = gravity / drag
	local offset = velocity - terminal
	local decay = math.exp(-drag * dt)

	return self._position + terminal * dt + offset * ((1 - decay) / drag), terminal + offset * decay
end

-- A strict upper bound on how far one substep can carry the shape. |v| grows by
-- at most |a| * dt over the step, so |v| * dt + |a| * dt^2 covers the real
-- displacement for any acceleration. Solving that for the limit gives the
-- largest dt that is guaranteed to stay inside it.
local function boundedSubstep(speed: number, acceleration: number, limit: number): number
	if limit <= 0 then
		return 0
	end

	if acceleration <= MIN_SPEED then
		if speed <= MIN_SPEED then
			return math.huge
		end

		return limit / speed
	end

	local root = math.sqrt(speed * speed + 4 * acceleration * limit)
	return (root - speed) / (2 * acceleration)
end

-- Reports how much of the block the flight can survive: nil stops it, a vector
-- is the outgoing velocity of a ricochet.
local function bounceVelocity(
	self: Projectile,
	block: Types.SweepBlock,
	velocity: Vector3
): (Vector3?, RicochetContext?)
	if self._ricochet.MaxBounces <= 0 then
		return nil, nil
	end

	-- An overlap block has no contact point and no surface normal, so there is
	-- nothing truthful to reflect about. Those always stop the projectile.
	if block.Kind ~= "Sweep" then
		return nil, nil
	end

	local result = block.Result
	local normal = result.Normal

	if normal.Magnitude <= 1e-6 then
		return nil, nil
	end

	local context: RicochetContext = table.freeze({
		Block = block,
		Bounce = self._bounces + 1,
		-- Where the body is, which for a Compound is not where the member that
		-- touched the surface is. Point is the surface contact.
		Position = block.RootPose.Position,
		Point = result.Position,
		Normal = normal,
		Velocity = velocity,
		Speed = velocity.Magnitude,
		Incidence = RicochetClass.incidence(velocity, normal),
	})

	local outgoing = RicochetClass.resolveBounce(self._ricochet, context)

	if outgoing == nil then
		return nil, context
	end

	return outgoing, context
end

-- pcall's type says the values after the boolean are the callee's own, and
-- _integrateStep returns none; on failure the second value is the error.
-- Naming the real shape once, here, is what lets it be bound at the call site.
local guardedIntegrate: ((Projectile, number, number) -> (), Projectile, number, number) -> (boolean, any) =
	pcall :: any

function Projectile.Step(self: Projectile, deltaTime: number)
	if self._destroyed then
		fail("cannot Step a destroyed projectile", "Destroyed")
	end

	if self._stepping then
		fail("Step cannot be called recursively on the same projectile", "Reentrant")
	end

	if type(deltaTime) ~= "number" or not isFiniteNumber(deltaTime) or deltaTime < 0 then
		fail("Step expects a non-negative delta time")
	end

	local startedAt = os.clock()
	self._stepping = true
	local stats = self._stats
	resetStats(stats)
	self._truncation = nil
	self._statsSnapshot = nil
	self._hasStats = true

	local generation = self._generation
	-- The method and its arguments are passed to pcall rather than captured in
	-- a closure. Thirty-two projectiles stepping every frame is thirty-two
	-- closures a frame, and this one carries no state a closure would be needed
	-- for. pcall's type says the values after the boolean are the callee's own,
	-- and this callee returns none, so the shape is named here to bind the error.
	local completed, message =
		guardedIntegrate(Projectile._integrateStep, self, deltaTime, generation)

	self._stepping = false
	stats.TimeMs = (os.clock() - startedAt) * 1_000

	if not completed then
		error(message, 0)
	end
end

function Projectile._integrateStep(self: Projectile, deltaTime: number, generation: number)
	local stats = self._stats
	local remaining = deltaTime

	while remaining > 0 do
		if self._generation ~= generation or self._destroyed then
			return
		end

		local speed = self._velocity.Magnitude
		-- Both caps are computed against a bound that includes acceleration.
		-- Using the current speed alone would let gravity or drag carry the
		-- shape past the tunnelling cap and past the range limit inside a
		-- single substep.
		local acceleration = (self._gravity - self._velocity * self._drag).Magnitude
		local substepTime = remaining
		local capped = boundedSubstep(speed, acceleration, self._maxSubstepDistance)

		if capped < substepTime then
			substepTime = capped
		end

		local remainingRange =
			boundedSubstep(speed, acceleration, self._maxDistance - self._distance)

		if remainingRange > 0 and remainingRange < substepTime then
			substepTime = remainingRange
		end

		local remainingLifetime = self._maxLifetime - self._elapsed

		if remainingLifetime > 0 and remainingLifetime < substepTime then
			substepTime = remainingLifetime
		end

		if substepTime <= 0 or not isFiniteNumber(substepTime) then
			return
		end

		stats.RequiredSubsteps += 1

		if stats.Substeps >= self._maxSubsteps then
			-- The remaining frame time is not simulated. Elapsed falls behind
			-- wall time, which is why this is reported rather than hidden.
			stats.Truncated = true
			local truncation: ProjectileTruncation = {
				Truncated = true,
				Reason = "MaxSubstepsPerStep",
				Certain = true,
				RequiredAtLeast = stats.RequiredSubsteps,
				Allowed = self._maxSubsteps,
				UnsimulatedTime = remaining,
			}
			self._truncation = table.freeze(truncation)
			return
		end

		local nextPosition, nextVelocity = integrate(self, substepTime)
		local previousPose = self:_pose(self._position, self._velocity)
		local nextPose = self:_pose(nextPosition, nextVelocity)
		local crossing = self._crossing
		crossing.Seen = false
		local hits, blockedBy = self._sweep:Step(previousPose, nextPose)

		if crossing.Instance ~= nil and not crossing.Seen then
			-- The body has left the plate it crossed. It is a blocker again.
			crossing.Instance = nil
		end
		local shapeCasts, overlapQueries = self._sweep:_getLastQueryCounts()

		if shapeCasts ~= nil and overlapQueries ~= nil then
			stats.ShapeCasts += shapeCasts
			stats.OverlapQueries += overlapQueries
			self._pendingShapeCasts += shapeCasts
			self._pendingOverlapQueries += overlapQueries
			self._hasPendingCost = true
		end

		local travelled = (nextPosition - self._position).Magnitude
		stats.Substeps += 1
		remaining -= substepTime

		local bounced: Vector3? = nil
		local context: RicochetContext? = nil
		local impact: ImpactSolverClass.ImpactResult? = nil
		local resolvedImpact: ProjectileImpact? = nil
		local resolvedAction: string? = nil
		-- How much of the substep was actually flown before the blocker stopped
		-- it, and the velocity at that instant rather than at the end of a
		-- substep the projectile never finished. With gravity or drag the two
		-- differ, and reflecting the wrong one bounces a grenade off a wall at a
		-- speed it never had there.
		local consumed = substepTime

		if blockedBy ~= nil then
			local block = blockedBy :: Types.SweepBlock
			consumed = substepTime * math.clamp(block.Alpha, 0, 1)
			local _, impactVelocity = integrate(self, consumed)
			local solver = self._impact

			if solver ~= nil then
				-- With a solver the blocker is a question rather than a verdict:
				-- through, off, or stop, decided from energy and angle. Without
				-- one the older rule stands, which is bounce or stop.
				impact = solver:Resolve({
					Block = block,
					Velocity = impactVelocity,
					Mass = self._mass,
					Caliber = self._caliber,
					WorldRoot = self._worldRoot,
				})
			else
				bounced, context = bounceVelocity(self, block, impactVelocity)
			end
		end

		if blockedBy == nil then
			self._position = nextPosition
			self._velocity = nextVelocity
			self._distance += travelled
			self._elapsed += substepTime
			stats.Distance += travelled
			stats.Elapsed += substepTime
		elseif impact ~= nil then
			local resolved = impact :: ImpactSolverClass.ImpactResult
			local block = blockedBy :: Types.SweepBlock
			-- RootPose, not Pose: Pose is where the member that touched the wall
			-- was, and for a Compound or an offset member that is not where the
			-- body is. Moving the body there teleports it by the offset.
			local contactRoot = block.RootPose.Position
			local contactTravel = (contactRoot - self._position).Magnitude
			local action = resolved.Action
			local limit: ImpactLimit? = nil

			if action == "Ricochet" and self._bounces >= self._ricochet.MaxBounces then
				-- The solver decides physics, the budget decides how long the
				-- game is willing to keep simulating it. Which of the two spoke
				-- is recorded, because a listener that cannot tell them apart
				-- draws a wall that absorbed the round when the round in fact
				-- went through and the simulation gave up on it.
				action = "Stop"
				limit = "Bounces"
			elseif action == "Penetrate" and self._penetrations >= self._maxPenetrations then
				action = "Stop"
				limit = "Penetrations"
			end

			-- The contact happened partway through the substep. Charging the
			-- whole substep would make every impact silently eat frame time, so
			-- only the part actually flown is consumed and the rest goes back
			-- into the frame for whatever is left of the shot to use.
			self._distance += contactTravel
			self._elapsed += consumed
			stats.Distance += contactTravel
			stats.Elapsed += consumed

			if action == "Stop" then
				self._position = contactRoot
				self._velocity = Vector3.zero
			else
				remaining += substepTime - consumed
				-- Resume is measured from the surface the solver examined, and
				-- the body sits at its own offset from that surface. Moving the
				-- body by the same vector keeps the two consistent for a
				-- Compound as well as for a bare sphere.
				self._position = contactRoot + (resolved.Resume :: Vector3 - resolved.Entry)
				self._velocity = resolved.VelocityAfter

				if action == "Ricochet" then
					self._bounces += 1
					stats.Bounces += 1

					if self._ricochet.ResetPolicy then
						self._sweep:ResetPolicy()
					end
				else
					self._penetrations += 1
					stats.Penetrations += 1
					self._crossing.Instance = resolved.Instance
				end
			end

			resolvedImpact = table.freeze({
				Result = resolved,
				Action = action :: ImpactSolverClass.Action,
				Limit = limit,
			})
			resolvedAction = action
		elseif bounced ~= nil then
			local block = blockedBy :: Types.SweepBlock
			local resolvedContext = context :: RicochetContext
			local contactRoot = block.RootPose.Position
			local contactTravel = (contactRoot - self._position).Magnitude
			remaining += substepTime - consumed
			self._position = contactRoot + resolvedContext.Normal * self._ricochet.SurfaceOffset
			self._velocity = bounced
			self._distance += contactTravel
			self._elapsed += consumed
			self._bounces += 1
			stats.Distance += contactTravel
			stats.Elapsed += consumed
			stats.Bounces += 1

			if self._ricochet.ResetPolicy then
				self._sweep:ResetPolicy()
			end
		else
			-- Terminal block: stop at the contact pose rather than past it, and
			-- charge only the time actually flown.
			local block = blockedBy :: Types.SweepBlock
			local contactRoot = block.RootPose.Position
			local contactTravel = (contactRoot - self._position).Magnitude
			self._position = contactRoot
			self._distance += contactTravel
			self._elapsed += consumed
			stats.Distance += contactTravel
			stats.Elapsed += consumed
		end

		if self._align and self._velocity.Magnitude > MIN_SPEED then
			self._rotation = alignedRotation(self._velocity.Unit)
		end

		stats.Hits += #hits

		for _, hit in hits do
			if self._generation ~= generation or self._destroyed then
				return
			end

			self._hitEvent:Fire(hit)
		end

		if blockedBy ~= nil then
			if self._generation ~= generation or self._destroyed then
				return
			end

			self._blockedEvent:Fire(blockedBy)

			-- A Blocked listener may have stopped or relaunched this body. Firing
			-- Ricochet after that would announce a bounce for a flight that is
			-- already over.
			if self._generation ~= generation or self._destroyed then
				return
			end

			if resolvedImpact ~= nil then
				self._impactEvent:Fire(resolvedImpact :: ProjectileImpact)

				if self._generation ~= generation or self._destroyed then
					return
				end

				if resolvedAction == "Stop" then
					-- Nothing left to carry forward. Continuing would put the
					-- body inside whatever absorbed it and block again on every
					-- substep from here.
					stopWithReason(self, StopReason.Blocked)
					return
				end
			elseif bounced ~= nil then
				self._ricochetEvent:Fire(context :: RicochetContext, bounced)
			else
				-- Without a solver a blocker is terminal unless it bounced.
				-- Crossing material is what an ImpactSolver decides, and what
				-- pierce() answers as a standalone query.
				stopWithReason(self, StopReason.Blocked)
				return
			end
		end

		if self._generation ~= generation or self._destroyed then
			return
		end

		if self._distance >= self._maxDistance then
			stopWithReason(self, StopReason.MaxDistance)
			return
		end

		if self._elapsed >= self._maxLifetime then
			stopWithReason(self, StopReason.MaxLifetime)
			return
		end
	end
end

export type LaunchOptions = {
	Origin: Types.CastOrigin,
	Velocity: Vector3?,
	Direction: Vector3?,
	Speed: number?,
}

-- Re-arms a spent projectile in place. The Sweep, its probes, its signals and
-- its runtime registration are all reused, which is what makes a pool worth
-- having: the expensive part of a projectile is its query geometry, not its
-- numbers. Every flight-local counter is cleared so the reused object cannot
-- inherit the previous shot's distance, lifetime or bounce budget.
function Projectile.Relaunch(self: Projectile, options: LaunchOptions)
	if self._destroyed then
		fail("cannot Relaunch a destroyed projectile", "Destroyed")
	end

	if self._stepping then
		fail("Relaunch cannot be called from inside a Step", "Reentrant")
	end

	if type(options) ~= "table" then
		fail("Relaunch expects an options table")
	end

	local rawOrigin = options.Origin
	local position: Vector3

	if typeof(rawOrigin) == "Vector3" then
		if not isFiniteVector3(rawOrigin) then
			fail("options.Origin must contain only finite values")
		end

		position = rawOrigin
		-- A Vector3 origin carries no orientation, and construction reads that as
		-- identity. A pooled body has to read it the same way: leaving the last
		-- flight's rotation in place would fire a Block or Part projectile with a
		-- collision orientation nobody asked for, and only after a reuse.
		self._rotation = CFrame.identity
	elseif typeof(rawOrigin) == "CFrame" then
		if not isFiniteCFrame(rawOrigin) then
			fail("options.Origin must contain only finite values")
		end

		position = rawOrigin.Position
		self._rotation = rawOrigin.Rotation
	else
		fail("options.Origin must be a Vector3 or CFrame")
	end

	local velocity = resolveLaunch(options :: any)
	local wasActive = self._active

	if wasActive then
		deactivate(self)
	end

	self._position = position
	self._velocity = velocity

	if self._align and velocity.Magnitude > MIN_SPEED then
		self._rotation = alignedRotation(velocity.Unit)
	end

	self._distance = 0
	self._elapsed = 0
	self._bounces = 0
	self._penetrations = 0
	self._truncation = nil
	self._hasStats = false
	self._statsSnapshot = nil
	self._pendingShapeCasts = 0
	self._pendingOverlapQueries = 0
	self._hasPendingCost = false
	resetStats(self._stats)
	self._sweep:Reset()
end

function Projectile.Start(self: Projectile)
	if self._destroyed then
		fail("cannot Start a destroyed projectile", "Destroyed")
	end

	if self._active then
		return
	end

	self._active = true
	local registered, message = pcall(function(): any
		self._runtime:Add(
			self,
			self._runtimeStep,
			self._runtimeError,
			self._priority,
			self._runtimeCost
		)
		return nil
	end)

	if not registered then
		self._active = false
		self._runtime:Remove(self)
		error(message, 0)
	end

	self._startedEvent:Fire()
end

function Projectile.Stop(self: Projectile)
	stopWithReason(self, StopReason.Manual)
end

function Projectile.GetPosition(self: Projectile): Vector3
	return self._position
end

function Projectile.GetVelocity(self: Projectile): Vector3
	return self._velocity
end

function Projectile.GetPose(self: Projectile): CFrame
	return self:_pose(self._position, self._velocity)
end

function Projectile.GetDistance(self: Projectile): number
	return self._distance
end

function Projectile.GetElapsed(self: Projectile): number
	return self._elapsed
end

function Projectile.GetBounceCount(self: Projectile): number
	return self._bounces
end

function Projectile.GetPenetrationCount(self: Projectile): number
	return self._penetrations
end

-- Kinetic energy as of the last resolved impact. Derived from mass and speed
-- rather than stored alongside them, so it cannot drift out of step with the
-- velocity that produced it.
function Projectile.GetEnergy(self: Projectile): number
	local speed = self._velocity.Magnitude

	return 0.5 * self._mass * speed * speed
end

function Projectile.GetMass(self: Projectile): number
	return self._mass
end

function Projectile.IsActive(self: Projectile): boolean
	return self._active
end

function Projectile.IsDestroyed(self: Projectile): boolean
	return self._destroyed
end

function Projectile.GetLastStats(self: Projectile): ProjectileStats?
	if not self._hasStats then
		return nil
	end

	local snapshot = self._statsSnapshot

	if snapshot == nil then
		snapshot = table.freeze(table.clone(self._stats))
		self._statsSnapshot = snapshot
	end

	return snapshot
end

function Projectile.GetLastTruncation(self: Projectile): ProjectileTruncation?
	return self._truncation
end

function Projectile.GetLastSweepStats(self: Projectile): SweepClass.SweepStats?
	return self._sweep:GetLastStats()
end

function Projectile.GetLastSweepTruncation(self: Projectile): SweepClass.SweepTruncation?
	return self._sweep:GetLastTruncation()
end

function Projectile.GetLastSamples(self: Projectile): { CFrame }
	return self._sweep:GetLastSamples()
end

function Projectile.GetLastSampleChains(self: Projectile): { { CFrame } }
	return self._sweep:GetLastSampleChains()
end

function Projectile.Destroy(self: Projectile)
	if self._destroyed then
		return
	end

	self._destroyed = true
	local wasActive = deactivate(self)

	if wasActive then
		self._stoppedEvent:Fire(StopReason.Destroyed)
	end

	self._sweep:Destroy()
	self._hitEvent:Destroy()
	self._blockedEvent:Destroy()
	self._ricochetEvent:Destroy()
	self._impactEvent:Destroy()
	self._startedEvent:Destroy()
	self._stoppedEvent:Destroy()
	self._errorEvent:Destroy()
end

return Projectile
