--!strict

local Types = require(script.Parent.Parent.Types)
local Pierce = require(script.Parent.Parent.Cast.Pierce)
local RicochetClass = require(script.Parent.Parent.Projectile.Ricochet)
local MaterialProfileClass = require(script.Parent.MaterialProfile)
local Errors = require(script.Parent.Parent.Util.Errors)
local Config = require(script.Parent.Parent.Config)

-- Live config section. Read through it so VirtualHit.configure() takes
-- effect without reloading the library.
local Tuning = Config.Impact

-- What happens to a shot when it reaches something, and what is left of it.

-- Until this existed the library could answer two separate questions well and
-- the question between them not at all. A projectile that met a blocker either
-- bounced or stopped; passing through was pierce(), which is a different query
-- with a different budget and no memory of the flight that led to it. So a
-- round could cross glass, or it could ricochet off steel, but it could not
-- cross glass at 780 studs a second, lose most of that in a plank, and then
-- glance off a steel beam with what was left. That is one bullet, and it has to
-- be one state.

-- The model is deliberately small and game-tuned:

--   * A shot carries mass, velocity and calibre. Energy is derived, never
--     stored, so it cannot drift out of step with the velocity that produced it.
--   * A surface met at an angle is thicker than it measures. The material a
--     shot actually crosses is thickness / sin(incidence), which is what makes
--     the same plate stop a glancing round and pass a square one.
--   * Penetration is tried first, and ricochet is what happens when it fails at
--     a shallow enough angle. That ordering is the physical one: a steel plate
--     hit square is hard to get through, and hit at ten degrees is impossible,
--     which is exactly when a round skips off it instead.

-- Nothing here decides damage, and nothing here knows what it hit. An impact is
-- a fact about geometry and energy; who was standing there is somebody else's
-- question.

local ImpactSolver = {}
ImpactSolver.__index = ImpactSolver

-- Calibre is scaled against this, so a shot at the reference width pays exactly
-- the material's resistance per stud.
local REFERENCE_CALIBER = 0.3

-- A grazing hit would divide by something arbitrarily close to zero. Past this
-- the material is effectively unbounded, and the shot is not getting through
-- whatever the arithmetic says.
local MIN_INCIDENCE_SINE = 1e-3

export type Action = "Stop" | "Penetrate" | "Ricochet"

export type ImpactRequest = {
	-- The blocker the sweep stopped on. Only a Sweep-kind block carries a
	-- surface to reason about; an overlap block has no contact point or normal
	-- and always stops.
	Block: Types.SweepBlock,
	-- Velocity at the moment of contact, not at the end of the substep that
	-- contained it.
	Velocity: Vector3,
	Mass: number?,
	Caliber: number?,
	WorldRoot: WorldRoot?,
	-- How deep the far-face probe looks. Material deeper than this is not
	-- unmeasured, it is impassable: an unknown thickness stops the shot.
	MaxThickness: number?,
	-- Below this the shot has nothing left worth simulating.
	MinSpeed: number?,
}

export type ImpactResult = {
	-- What actually happened.
	read Action: Action,
	-- What Decide asked for, when a Decide was supplied and answered. Equal to
	-- Action except in the two cases the physics cannot express: a forced
	-- penetration with no far face to come out of, and any outcome that left
	-- the shot below MinSpeed. Comparing the two is how a caller sees that its
	-- override did not land.
	read Requested: Action?,
	read Instance: BasePart,
	read Entry: Vector3,
	read Exit: Vector3?,
	read Normal: Vector3,
	read Material: Enum.Material,
	read Thickness: number?,
	-- What the shot would actually have to cross at this angle, which is what
	-- the energy was spent against.
	read EffectiveThickness: number?,
	-- Angle from the surface plane. Grazing is near zero, square is a right
	-- angle -- the same convention Ricochet uses.
	read Incidence: number,
	read VelocityBefore: Vector3,
	read VelocityAfter: Vector3,
	read EnergyBefore: number,
	read EnergyAfter: number,
	read EnergyTransferred: number,
	-- Where a body should be placed to continue. Nil when it stopped.
	read Resume: Vector3?,
}

export type ImpactSolverOptions = {
	Profiles: MaterialProfileClass.MaterialProfileTable?,
	Mass: number?,
	Caliber: number?,
	MaxThickness: number?,
	MinSpeed: number?,
	-- Joules per unit of Resistance per stud. The material table is shared with
	-- pierce, which measures in its own budget rather than in energy, so this is
	-- what makes the same table mean something here. See Tuning.EnergyScale.
	Scale: number?,
	-- Clearance past the surface a resuming shot is placed at, so the next cast
	-- does not start inside what it just left.
	ExitMargin: number?,
	-- Deflection is the only nondeterministic element here, and it is off in
	-- every default profile. Supplying a seeded Random makes a flight that uses
	-- it reproducible, the same way Ricochet.Random does.
	Random: Random?,
	-- Replaces the built-in rule entirely, and is asked exactly once per
	-- impact -- so a callback that counts, or draws from its own generator, is
	-- safe here. Returning nil falls back to the built-in rule.

	-- The answer is an override, not a preference: "Penetrate" goes through a
	-- plate it could never have afforded, leaving at MinSpeed rather than at a
	-- negative speed, and "Ricochet" glances off a material whose profile never
	-- glances. The two things it cannot do are conjure a far face that the
	-- thickness probe did not find and keep a shot alive below MinSpeed; both
	-- come back as a Stop carrying Requested.
	Decide: ((request: ImpactRequest, profile: MaterialProfileClass.Profile) -> Action?)?,
}

export type ImpactSolver = typeof(setmetatable(
	{} :: {
		_profiles: MaterialProfileClass.MaterialProfileTable,
		_mass: number,
		_caliber: number,
		_maxThickness: number,
		_minSpeed: number,
		_scale: number,
		_exitMargin: number,
		_random: Random,
		_decide: ((request: ImpactRequest, profile: MaterialProfileClass.Profile) -> Action?)?,
	},
	ImpactSolver
))

local function fail(message: string, code: string?): never
	return Errors.raise("VirtualHit.impactSolver", code or "InvalidArgument", message, 3)
end

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function isFiniteVector3(value: Vector3): boolean
	return isFiniteNumber(value.X) and isFiniteNumber(value.Y) and isFiniteNumber(value.Z)
end

local function positiveNumber(value: any, name: string, defaultValue: number): number
	if value == nil then
		return defaultValue
	end

	if type(value) ~= "number" or not isFiniteNumber(value) or value <= 0 then
		fail(`{name} must be a finite number greater than zero`)
	end

	return value
end

-- Derived, never stored. A stored energy and a stored velocity are two claims
-- about the same thing, and they drift.
local function energyOf(mass: number, speed: number): number
	return 0.5 * mass * speed * speed
end

local function speedFor(mass: number, energy: number): number
	if energy <= 0 or mass <= 0 then
		return 0
	end

	return math.sqrt(2 * energy / mass)
end

function ImpactSolver.new(options: ImpactSolverOptions?): ImpactSolver
	local resolved: ImpactSolverOptions = if options == nil then {} else options

	if type(resolved) ~= "table" then
		fail("expected an options table")
	end

	local profiles = resolved.Profiles

	if
		profiles ~= nil and (type(profiles) ~= "table" or type((profiles :: any).Get) ~= "function")
	then
		fail("options.Profiles must come from VirtualHit.materialProfile()")
	end

	if resolved.Random ~= nil and typeof(resolved.Random) ~= "Random" then
		fail("options.Random must be a Random")
	end

	if resolved.Decide ~= nil and type(resolved.Decide) ~= "function" then
		fail("options.Decide must be a function")
	end

	local exitMargin = resolved.ExitMargin

	if
		exitMargin ~= nil
		and (type(exitMargin) ~= "number" or not isFiniteNumber(exitMargin) or exitMargin < 0)
	then
		fail("options.ExitMargin must be a non-negative finite number")
	end

	return (
		setmetatable({
			_profiles = profiles or MaterialProfileClass.new(),
			_mass = positiveNumber(resolved.Mass, "options.Mass", Tuning.Mass),
			_caliber = positiveNumber(resolved.Caliber, "options.Caliber", Tuning.Caliber),
			_maxThickness = positiveNumber(
				resolved.MaxThickness,
				"options.MaxThickness",
				Tuning.MaxThickness
			),
			_minSpeed = positiveNumber(resolved.MinSpeed, "options.MinSpeed", Tuning.MinSpeed),
			_scale = positiveNumber(resolved.Scale, "options.Scale", Tuning.EnergyScale),
			_exitMargin = if exitMargin == nil then Tuning.ExitMargin else exitMargin,
			_random = resolved.Random or Random.new(),
			_decide = resolved.Decide,
		}, ImpactSolver) :: any
	) :: ImpactSolver
end

local function stopped(
	block: Types.SweepBlock,
	entry: Vector3,
	normal: Vector3,
	material: Enum.Material,
	incidence: number,
	velocity: Vector3,
	energy: number,
	thickness: number?,
	effective: number?,
	requested: Action?
): ImpactResult
	return table.freeze({
		Action = "Stop" :: Action,
		Requested = requested,
		Instance = block.Instance,
		Entry = entry,
		Exit = nil,
		Normal = normal,
		Material = material,
		Thickness = thickness,
		EffectiveThickness = effective,
		Incidence = incidence,
		VelocityBefore = velocity,
		VelocityAfter = Vector3.zero,
		EnergyBefore = energy,
		EnergyAfter = 0,
		-- Everything it had went into whatever it hit. That is what stopping is.
		EnergyTransferred = energy,
		Resume = nil,
	})
end

-- What becomes of a shot that reached this surface.
--
-- Penetration first, then ricochet, then stop. The order is the physical one:
-- an angle steep enough to get through is an angle too steep to skip off, and a
-- shot that failed to get through at ten degrees failed precisely because the
-- material it faced was effectively enormous -- which is the same fact that
-- makes it glance.
function ImpactSolver.Resolve(self: ImpactSolver, request: ImpactRequest): ImpactResult
	if type(request) ~= "table" then
		fail("Resolve expects a request table")
	end

	local block = request.Block

	if type(block) ~= "table" or typeof(block.Instance) ~= "Instance" then
		fail("request.Block must be a SweepBlock")
	end

	local velocity = request.Velocity

	if typeof(velocity) ~= "Vector3" or not isFiniteVector3(velocity) then
		fail("request.Velocity must be a finite Vector3")
	end

	local mass = positiveNumber(request.Mass, "request.Mass", self._mass)
	local caliber = positiveNumber(request.Caliber, "request.Caliber", self._caliber)
	local minSpeed = positiveNumber(request.MinSpeed, "request.MinSpeed", self._minSpeed)
	local maxThickness =
		positiveNumber(request.MaxThickness, "request.MaxThickness", self._maxThickness)
	local speed = velocity.Magnitude
	local energy = energyOf(mass, speed)

	-- An overlap block has no contact point and no surface normal, so there is
	-- nothing here to reason about. Those always stop.
	if block.Kind ~= "Sweep" or speed <= 1e-4 then
		return stopped(
			block,
			block.RootPose.Position,
			Vector3.zero,
			Enum.Material.Air,
			0,
			velocity,
			energy,
			nil,
			nil,
			nil
		)
	end

	local result = block.Result
	local normal = result.Normal
	local entry = result.Position
	local material = result.Material
	local direction = velocity.Unit
	local incidence = RicochetClass.incidence(velocity, normal)
	local profile = self._profiles:For(block.Instance, material)

	-- Asked once, and once only. A callback is allowed to be stateful -- to
	-- count how many rounds a wall has taken, or to draw from its own generator
	-- -- and asking the same question twice about one impact would give two
	-- answers for one event and use the second. Whatever it says here is what
	-- this impact is.
	local override = self._decide
	local requested: Action? = nil

	if override ~= nil then
		local chosen = override(request, profile)

		-- Narrowed by comparing against the literals rather than by ruling the
		-- others out: the callback is a caller's, so its answer arrives as a
		-- plain string and this is what turns it back into an ImpactAction.
		if chosen == nil then
			requested = nil
		elseif chosen == "Penetrate" or chosen == "Ricochet" or chosen == "Stop" then
			requested = chosen
		else
			return fail("Decide must return Penetrate, Ricochet, Stop or nil", "CallbackContract")
		end
	end

	if requested == "Stop" then
		return stopped(
			block,
			entry,
			normal,
			material,
			incidence,
			velocity,
			energy,
			nil,
			nil,
			requested
		)
	end

	local worldRoot = request.WorldRoot or block.Instance:FindFirstAncestorWhichIsA("WorldRoot")
	local exit: Vector3? = nil
	local thickness: number? = nil

	if worldRoot ~= nil then
		exit, thickness =
			Pierce.measureThickness(worldRoot, block.Instance, entry, direction, maxThickness)
	end

	-- The material actually in the way, not the material as measured. A plate
	-- met at twenty degrees is nearly three times its own thickness.
	local sine = math.max(math.sin(incidence), MIN_INCIDENCE_SINE)
	local effective: number? = if thickness == nil then nil else thickness / sine
	local caliberFactor = caliber / REFERENCE_CALIBER
	local required = if effective == nil
		then math.huge
		else profile.Resistance * effective * caliberFactor * self._scale

	-- Penetration first, then ricochet, then stop. The order is the physical
	-- one: an angle steep enough to get through is an angle too steep to skip
	-- off, and a shot that failed to get through at ten degrees failed
	-- precisely because the material it faced was effectively enormous -- which
	-- is the same fact that makes it glance.
	local forcedPenetrate = requested == "Penetrate"
	local tryPenetrate = exit ~= nil and (forcedPenetrate or energy > required)

	if tryPenetrate then
		-- A forced penetration still pays. What it does not do is fail for
		-- lack of funds: the caller said this round goes through, so it leaves
		-- at the simulation floor rather than at a speed the arithmetic says
		-- is negative.

		-- The floor is capped by what arrived, because a wall handing a round
		-- more energy than it came in with is not an override, it is a bug --
		-- and it would come out as a negative EnergyTransferred. A shot that
		-- was already under the floor stays under it and falls through to a
		-- stop below, carrying Requested to say what was asked for.
		local floorEnergy = math.min(energyOf(mass, minSpeed), energy)
		local remaining = if forcedPenetrate
			then math.max(energy - required, floorEnergy)
			else energy - required
		local outgoingSpeed = speedFor(mass, remaining)

		if outgoingSpeed >= minSpeed then
			local outgoing = RicochetClass.spread(direction, profile.Deflection, self._random)
				* outgoingSpeed

			return table.freeze({
				Action = "Penetrate" :: Action,
				Requested = requested,
				Instance = block.Instance,
				Entry = entry,
				Exit = exit,
				Normal = normal,
				Material = material,
				Thickness = thickness,
				EffectiveThickness = effective,
				Incidence = incidence,
				VelocityBefore = velocity,
				VelocityAfter = outgoing,
				EnergyBefore = energy,
				EnergyAfter = remaining,
				EnergyTransferred = energy - remaining,
				Resume = (exit :: Vector3) + direction * self._exitMargin,
			})
		end
	end

	-- It did not get through, or was told not to. A shallow enough angle
	-- against a material that glances is what turns that into a bounce rather
	-- than a stop.
	local glances = if requested == "Ricochet"
		then true
		else requested == nil and profile.RicochetBelow > 0 and incidence <= profile.RicochetBelow

	if glances then
		local retained = energy * profile.Retention
		local outgoingSpeed = speedFor(mass, retained)

		if outgoingSpeed >= minSpeed then
			local reflected = (direction - normal * (2 * direction:Dot(normal))).Unit

			return table.freeze({
				Action = "Ricochet" :: Action,
				Requested = requested,
				Instance = block.Instance,
				Entry = entry,
				Exit = nil,
				Normal = normal,
				Material = material,
				Thickness = thickness,
				EffectiveThickness = effective,
				Incidence = incidence,
				VelocityBefore = velocity,
				VelocityAfter = reflected * outgoingSpeed,
				EnergyBefore = energy,
				EnergyAfter = retained,
				EnergyTransferred = energy - retained,
				Resume = entry + normal * self._exitMargin,
			})
		end
	end

	-- Two things an override cannot conjure: a far face that is not there, and
	-- a shot still moving after the floor has taken it. Both land here, and
	-- Requested is how a caller sees that its answer could not be expressed.
	return stopped(
		block,
		entry,
		normal,
		material,
		incidence,
		velocity,
		energy,
		thickness,
		effective,
		requested
	)
end

function ImpactSolver.GetProfiles(self: ImpactSolver): MaterialProfileClass.MaterialProfileTable
	return self._profiles
end

return ImpactSolver
