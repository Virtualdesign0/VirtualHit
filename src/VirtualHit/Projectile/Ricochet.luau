--!strict

local Types = require(script.Parent.Parent.Types)
local Errors = require(script.Parent.Parent.Util.Errors)
local Config = require(script.Parent.Parent.Config)

-- Live config section. Read through it so VirtualHit.configure() takes
-- effect without reloading the library.
local Tuning = Config.Ricochet

-- Ricochet is a decision about a blocker, not a separate query. It reads the
-- Block a Sweep already produced and answers one question: what velocity does
-- the projectile leave with, or does it stop here.

local Ricochet = {}

export type RicochetContext = {
	read Block: Types.SweepBlock,
	read Bounce: number,
	-- Where the shape origin sat at contact, and where the surface was touched.
	read Position: Vector3,
	read Point: Vector3,
	read Normal: Vector3,
	read Velocity: Vector3,
	read Speed: number,
	-- Angle between the incoming velocity and the surface plane. Grazing hits
	-- are near zero; a head-on hit is a right angle. Shallow angles ricochet.
	read Incidence: number,
}

export type RicochetOptions = {
	-- Zero disables ricochet entirely, which is the default.
	MaxBounces: number?,
	MaxIncidence: number?,
	SpeedRetained: number?,
	MinSpeed: number?,
	Spread: number?,
	-- Spread is the only nondeterministic element in the library. Supplying a
	-- seeded Random makes a whole flight reproducible.
	Random: Random?,
	SurfaceOffset: number?,
	-- Replaces the built-in angle and speed rule. Returns the outgoing velocity,
	-- or nil to let the block stop the projectile.
	Decide: ((context: RicochetContext) -> Vector3?)?,
	-- Re-arms hit acceptance after a bounce so a target already hit before the
	-- bounce can be hit again on the way back.
	ResetPolicy: boolean?,
}

export type ResolvedRicochet = {
	MaxBounces: number,
	MaxIncidence: number,
	SpeedRetained: number,
	MinSpeed: number,
	Spread: number,
	Random: Random,
	SurfaceOffset: number,
	Decide: ((context: RicochetContext) -> Vector3?)?,
	ResetPolicy: boolean,
}

local function fail(message: string, code: string?): never
	return Errors.raise("VirtualHit.projectile", code or "InvalidArgument", message, 4)
end

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function isFiniteVector3(value: Vector3): boolean
	return isFiniteNumber(value.X) and isFiniteNumber(value.Y) and isFiniteNumber(value.Z)
end

local function positiveOrZero(value: any, name: string, defaultValue: number): number
	if value == nil then
		return defaultValue
	end

	if type(value) ~= "number" or not isFiniteNumber(value) or value < 0 then
		fail(`options.Ricochet.{name} must be a non-negative number`)
	end

	return value
end

function Ricochet.resolve(options: RicochetOptions?): ResolvedRicochet
	local resolved: RicochetOptions = if options == nil then {} else options

	if type(resolved) ~= "table" then
		fail("options.Ricochet must be a table")
	end

	local maxBounces = positiveOrZero(resolved.MaxBounces, "MaxBounces", 0)

	if maxBounces % 1 ~= 0 then
		fail("options.Ricochet.MaxBounces must be an integer")
	end

	local speedRetained =
		positiveOrZero(resolved.SpeedRetained, "SpeedRetained", Tuning.SpeedRetained)

	if speedRetained > 1 then
		fail("options.Ricochet.SpeedRetained cannot exceed 1")
	end

	local maxIncidence = positiveOrZero(resolved.MaxIncidence, "MaxIncidence", Tuning.MaxIncidence)

	if maxIncidence > math.pi * 0.5 then
		fail("options.Ricochet.MaxIncidence cannot exceed a right angle")
	end

	local spread = positiveOrZero(resolved.Spread, "Spread", 0)

	if spread > math.pi * 0.5 then
		fail("options.Ricochet.Spread cannot exceed a right angle")
	end

	if resolved.Decide ~= nil and type(resolved.Decide) ~= "function" then
		fail("options.Ricochet.Decide must be a function")
	end

	if resolved.Random ~= nil and typeof(resolved.Random) ~= "Random" then
		fail("options.Ricochet.Random must be a Random")
	end

	if resolved.ResetPolicy ~= nil and type(resolved.ResetPolicy) ~= "boolean" then
		fail("options.Ricochet.ResetPolicy must be a boolean")
	end

	return {
		MaxBounces = maxBounces,
		MaxIncidence = maxIncidence,
		SpeedRetained = speedRetained,
		MinSpeed = positiveOrZero(resolved.MinSpeed, "MinSpeed", Tuning.MinSpeed),
		Spread = spread,
		Random = resolved.Random or Random.new(),
		SurfaceOffset = positiveOrZero(
			resolved.SurfaceOffset,
			"SurfaceOffset",
			Tuning.SurfaceOffset
		),
		Decide = resolved.Decide,
		ResetPolicy = resolved.ResetPolicy ~= false,
	}
end

-- Uniform sampling inside a cone of the given half-angle around a direction.
local function spreadDirection(direction: Vector3, spread: number, rng: Random): Vector3
	if spread <= 0 then
		return direction
	end

	local cosSpread = math.cos(spread)
	local angle = math.acos(1 - rng:NextNumber() * (1 - cosSpread))
	local azimuth = rng:NextNumber() * math.pi * 2
	local reference = if math.abs(direction.Y) > 0.999 then Vector3.xAxis else Vector3.yAxis
	local right = direction:Cross(reference)

	if right.Magnitude <= 1e-6 then
		return direction
	end

	right = right.Unit
	local up = right:Cross(direction)
	local offset = (right * math.cos(azimuth) + up * math.sin(azimuth)) * math.sin(angle)
	local result = direction * math.cos(angle) + offset

	if result.Magnitude <= 1e-6 then
		return direction
	end

	return result.Unit
end

-- Returns the outgoing velocity, or nil when the block should stop the flight.
function Ricochet.resolveBounce(config: ResolvedRicochet, context: RicochetContext): Vector3?
	if context.Bounce > config.MaxBounces then
		return nil
	end

	local decide = config.Decide

	if decide ~= nil then
		local velocity = decide(context)

		if velocity == nil then
			return nil
		end

		-- A NaN or infinite component would flow straight into the projectile's
		-- position and velocity and poison every later substep, with no sign of
		-- where it came from. The callback is a caller extension point, so it
		-- gets the same input checking every other option does.
		if typeof(velocity) ~= "Vector3" or not isFiniteVector3(velocity) then
			fail("options.Ricochet.Decide must return a finite Vector3 or nil", "CallbackContract")
		end

		if velocity.Magnitude <= 1e-6 then
			-- A zero outgoing velocity is not a bounce; it is a stop that would
			-- otherwise leave the projectile frozen against the surface.
			return nil
		end

		return velocity
	end

	if context.Incidence > config.MaxIncidence then
		return nil
	end

	local normal = context.Normal
	local velocity = context.Velocity
	local reflected = velocity - normal * (2 * velocity:Dot(normal))
	local speed = reflected.Magnitude * config.SpeedRetained

	if speed < config.MinSpeed or reflected.Magnitude <= 1e-6 then
		return nil
	end

	return spreadDirection(reflected.Unit, config.Spread, config.Random) * speed
end

-- Angle between the incoming velocity and the surface plane, in radians.
function Ricochet.incidence(velocity: Vector3, normal: Vector3): number
	local magnitude = velocity.Magnitude

	if magnitude <= 1e-6 then
		return math.pi * 0.5
	end

	local cosToNormal = math.clamp(-velocity.Unit:Dot(normal), -1, 1)
	return math.asin(math.clamp(math.abs(cosToNormal), 0, 1))
end

-- The same cone sampling a bounce uses, exported so the impact solver's
-- deflection through a material is that sampling and not a second
-- implementation of it. Two of these drift, and the one that drifts is always
-- the one without tests.
function Ricochet.spread(direction: Vector3, spread: number, rng: Random): Vector3
	if typeof(direction) ~= "Vector3" or direction.Magnitude <= 1e-6 then
		error("Ricochet.spread expects a non-zero direction", 2)
	end

	if type(spread) ~= "number" or spread ~= spread then
		error("Ricochet.spread expects a numeric spread", 2)
	end

	return spreadDirection(direction.Unit, spread, rng)
end

table.freeze(Ricochet)

return Ricochet
