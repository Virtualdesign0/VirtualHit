--!strict

-- Pure geometry: given a launch speed and a gravity vector, which direction
-- reaches a point. This is the inverse of the projectile integrator and belongs
-- to the same layer, but it queries nothing and touches no Instance.

-- Everything here works with an arbitrary gravity vector rather than assuming
-- -Y, so it is equally correct on a wall-walking level or with sideways wind
-- modelled as constant acceleration.

-- solve() and lead() are drag-free: they answer for constant acceleration, and
-- a projectile carrying Drag will fall short of the point they aim at. The
-- projectile integrator uses the same closed form for the drag-free case, so
-- with Drag = 0 these two agree exactly; positionAt() models drag as well and
-- can trace either curve.

local Errors = require(script.Parent.Parent.Util.Errors)
local Config = require(script.Parent.Parent.Config)

-- Live config section. Read through it so VirtualHit.configure() takes
-- effect without reloading the library.
local Tuning = Config.Ballistics

local Ballistics = {}

local MIN_MAGNITUDE = 1e-6

-- A bracket has to start somewhere when the first guess is already tiny.
local MIN_LEAD_BRACKET = 1e-2

export type Solution = {
	read Direction: Vector3,
	read Velocity: Vector3,
	read Time: number,
	-- The flat, fast arc and the lofted, slow one. A mortar wants High; a rifle
	-- wants Low.
	read Arc: "Low" | "High",
}

local function fail(message: string, code: string?): never
	return Errors.raise("VirtualHit.Ballistics", code or "InvalidArgument", message, 3)
end

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function isFiniteVector3(value: Vector3): boolean
	return isFiniteNumber(value.X) and isFiniteNumber(value.Y) and isFiniteNumber(value.Z)
end

local function validate(origin: Vector3, target: Vector3, speed: number, gravity: Vector3)
	if typeof(origin) ~= "Vector3" or not isFiniteVector3(origin) then
		fail("origin must be a finite Vector3")
	end

	if typeof(target) ~= "Vector3" or not isFiniteVector3(target) then
		fail("target must be a finite Vector3")
	end

	if type(speed) ~= "number" or not isFiniteNumber(speed) or speed <= 0 then
		fail("speed must be a finite number greater than zero")
	end

	if typeof(gravity) ~= "Vector3" or not isFiniteVector3(gravity) then
		fail("gravity must be a finite Vector3")
	end
end

local function solution(
	direction: Vector3,
	speed: number,
	time: number,
	arc: "Low" | "High"
): Solution
	return table.freeze({
		Direction = direction,
		Velocity = direction * speed,
		Time = time,
		Arc = arc,
	})
end

-- Returns the flat solution first and the lofted one second, or nil when the
-- point is out of range for that speed. Both are nil-checked separately: a
-- target exactly at maximum range yields one solution twice.
function Ballistics.solve(
	origin: Vector3,
	target: Vector3,
	speed: number,
	gravity: Vector3?
): (Solution?, Solution?)
	local pull = if gravity == nil then Vector3.zero else gravity
	validate(origin, target, speed, pull)

	local displacement = target - origin
	local g = pull.Magnitude

	-- Without gravity the answer is a straight line, and there is only one arc.
	if g <= MIN_MAGNITUDE then
		local distance = displacement.Magnitude

		if distance <= MIN_MAGNITUDE then
			return nil, nil
		end

		local direction = displacement.Unit
		return solution(direction, speed, distance / speed, "Low"), nil
	end

	-- Work in the plane the shot actually lives in: one axis along the launch
	-- plane's horizontal, one straight against gravity.
	local up = -pull.Unit
	local vertical = displacement:Dot(up)
	local horizontalVector = displacement - up * vertical
	local horizontal = horizontalVector.Magnitude

	if horizontal <= MIN_MAGNITUDE then
		-- Straight up or straight down. The two cases are different quadratics
		-- and have to be solved separately: launching downward flips the sign
		-- of the initial vertical velocity, which moves the positive root to
		-- the other side of the discriminant.
		if math.abs(vertical) <= MIN_MAGNITUDE then
			-- The target is the launch point.
			return nil, nil
		end

		local discriminant = speed * speed - 2 * g * vertical

		if discriminant < 0 then
			return nil, nil
		end

		local root = math.sqrt(discriminant)

		if vertical > 0 then
			-- Fired up: y = speed*t - g*t^2/2. The smaller root is the shot
			-- passing the height on the way up, the larger one on the way down.
			local rising = (speed - root) / g
			local falling = (speed + root) / g

			return (if rising > 0 then solution(up, speed, rising, "Low") else nil),
				(if falling > rising then solution(up, speed, falling, "High") else nil)
		end

		-- Fired down: y = -speed*t - g*t^2/2, which has exactly one positive
		-- root. The other is negative and describes a shot that never happened.
		local time = (root - speed) / g

		if time <= 0 or not isFiniteNumber(time) then
			return nil, nil
		end

		return solution(-up, speed, time, "Low"), nil
	end

	local flat = horizontalVector / horizontal
	local speedSquared = speed * speed

	-- Standard ballistic range equation, kept in the tangent form so a near
	-- vertical launch does not lose precision through an arcsine.
	local discriminant = speedSquared * speedSquared
		- g * (g * horizontal * horizontal + 2 * vertical * speedSquared)

	if discriminant < 0 then
		return nil, nil
	end

	local root = math.sqrt(discriminant)
	local denominator = g * horizontal

	local function build(tangent: number, arc: "Low" | "High"): Solution?
		local angle = math.atan(tangent)
		local direction = flat * math.cos(angle) + up * math.sin(angle)

		if direction.Magnitude <= MIN_MAGNITUDE then
			return nil
		end

		direction = direction.Unit
		local horizontalSpeed = speed * math.cos(angle)

		if horizontalSpeed <= MIN_MAGNITUDE then
			return nil
		end

		local time = horizontal / horizontalSpeed

		if time <= 0 or not isFiniteNumber(time) then
			return nil
		end

		return solution(direction, speed, time, arc)
	end

	return build((speedSquared - root) / denominator, "Low"),
		build((speedSquared + root) / denominator, "High")
end

export type LeadOptions = {
	Gravity: Vector3?,
	-- Target acceleration, if the game models one. Zero is the common case.
	TargetAcceleration: Vector3?,
	Arc: ("Low" | "High")?,
	-- How hard to work at pinning down the flight time. Each step halves the
	-- bracket, so the default resolves it to about a millionth of the range it
	-- started from.
	Iterations: number?,
	-- How close the returned intercept has to be to where the target actually
	-- is at the returned time. A solution outside this is not returned at all.
	Tolerance: number?,
}

-- Where to aim at a moving target. Returns the solution and the intercept point
-- it was computed for, or nil when no arc reaches the target in time.

-- The intercept point depends on the flight time and the flight time depends on
-- the intercept point, so this is a root find rather than a formula. Feeding
-- each guess back into the next -- the obvious approach -- converges quickly
-- when the projectile badly outruns the target and barely converges at all when
-- it does not: a shot at 100 studs/s chasing a target fleeing at 99 really does
-- intercept, a hundred seconds out, and six passes land nowhere near it while
-- still producing a confident-looking answer.

-- So the flight time is bracketed and bisected instead. `g(t)` is how long the
-- shot would take to reach where the target will be at `t`, minus `t`: positive
-- while the shot is still behind, negative once it overshoots, and a root is an
-- honest intercept. If the bracket cannot be found the target is uncatchable
-- and this returns nil rather than a guess.
function Ballistics.lead(
	origin: Vector3,
	targetPosition: Vector3,
	targetVelocity: Vector3,
	speed: number,
	options: LeadOptions?
): (Solution?, Vector3?)
	local resolved: LeadOptions = if options == nil then {} else options

	if type(resolved) ~= "table" then
		fail("options must be a table")
	end

	if typeof(targetVelocity) ~= "Vector3" or not isFiniteVector3(targetVelocity) then
		fail("targetVelocity must be a finite Vector3")
	end

	local acceleration = if resolved.TargetAcceleration == nil
		then Vector3.zero
		else resolved.TargetAcceleration

	if typeof(acceleration) ~= "Vector3" or not isFiniteVector3(acceleration) then
		fail("options.TargetAcceleration must be a finite Vector3")
	end

	-- Requested and resolved are separate names so the resolved one is a plain
	-- number from here down. The guards still run: these arrive from a caller.
	local requestedIterations = resolved.Iterations
	local iterations: number

	if requestedIterations == nil then
		iterations = Tuning.LeadIterations
	elseif
		type(requestedIterations) ~= "number"
		or not isFiniteNumber(requestedIterations)
		or requestedIterations < 1
		or requestedIterations % 1 ~= 0
	then
		fail("options.Iterations must be a positive integer")
	else
		iterations = requestedIterations
	end

	local requestedTolerance = resolved.Tolerance
	local tolerance: number

	if requestedTolerance == nil then
		tolerance = Tuning.LeadTolerance
	elseif
		type(requestedTolerance) ~= "number"
		or not isFiniteNumber(requestedTolerance)
		or requestedTolerance <= 0
	then
		fail("options.Tolerance must be a finite number greater than zero")
	else
		tolerance = requestedTolerance
	end

	local wantHigh = resolved.Arc == "High"

	local function targetAt(time: number): Vector3
		return targetPosition + targetVelocity * time + acceleration * (0.5 * time * time)
	end

	local function solveAt(time: number): Solution?
		local low, high = Ballistics.solve(origin, targetAt(time), speed, resolved.Gravity)
		return if wantHigh then high or low else low or high
	end

	-- How much longer the shot takes than the guess it was given. Nil when no
	-- arc reaches that point at all, which ends the search in that direction.
	local function residual(time: number): number?
		local candidate = solveAt(time)
		return if candidate == nil then nil else candidate.Time - time
	end

	local atZero = residual(0)

	if atZero == nil then
		return nil, nil
	end

	if atZero <= 0 then
		-- Zero flight time: the target is already where the shot starts, so
		-- there is no lead to compute.
		local immediate = solveAt(0)

		if immediate == nil then
			return nil, nil
		end

		return immediate, targetAt(0)
	end

	-- Walk forward until the shot stops being behind. Doubling keeps this at a
	-- few dozen closed-form solves even for a chase measured in minutes.
	local lower = 0
	local upper = math.max(atZero, MIN_LEAD_BRACKET)
	local bracketed = false

	for _ = 1, Tuning.MaxLeadExpansions do
		local value = residual(upper)

		if value == nil then
			-- No arc reaches the target this far out. Refusing here rather than
			-- searching past the gap is the conservative answer: a nil solution
			-- costs a shot, a wrong one misses and says it did not.
			break
		end

		if value <= 0 then
			bracketed = true
			break
		end

		lower = upper
		upper *= 2
	end

	if not bracketed then
		return nil, nil
	end

	for _ = 1, iterations do
		local middle = (lower + upper) * 0.5
		local value = residual(middle)

		if value == nil or value > 0 then
			lower = middle
		else
			upper = middle
		end
	end

	local time = (lower + upper) * 0.5
	local intercept = targetAt(time)
	local final = solveAt(time)

	if final == nil then
		return nil, nil
	end

	-- The last word. A bracket that closed on a point the shot does not
	-- actually reach at the time it reports is not a solution, and saying so is
	-- the whole reason this is a root find.
	if math.abs(final.Time - time) > tolerance then
		return nil, nil
	end

	return final, intercept
end

-- The greatest horizontal distance this speed can reach on level ground.
function Ballistics.maxRange(speed: number, gravity: Vector3?): number
	local pull = if gravity == nil then Vector3.zero else gravity

	if type(speed) ~= "number" or not isFiniteNumber(speed) or speed <= 0 then
		fail("speed must be a finite number greater than zero")
	end

	if typeof(pull) ~= "Vector3" or not isFiniteVector3(pull) then
		fail("gravity must be a finite Vector3")
	end

	local g = pull.Magnitude

	if g <= MIN_MAGNITUDE then
		return math.huge
	end

	return speed * speed / g
end

-- Where a shot fired with this velocity is after the given time, ignoring
-- collision. This is the same closed form the projectile integrator flies, drag
-- included, so a predicted arc drawn from here matches where the shape actually
-- goes rather than approximating it.
function Ballistics.positionAt(
	origin: Vector3,
	velocity: Vector3,
	time: number,
	gravity: Vector3?,
	drag: number?
): Vector3
	local pull = if gravity == nil then Vector3.zero else gravity
	local resistance = if drag == nil then 0 else drag

	if typeof(origin) ~= "Vector3" or not isFiniteVector3(origin) then
		fail("origin must be a finite Vector3")
	end

	if typeof(velocity) ~= "Vector3" or not isFiniteVector3(velocity) then
		fail("velocity must be a finite Vector3")
	end

	if type(time) ~= "number" or not isFiniteNumber(time) or time < 0 then
		fail("time must be a non-negative finite number")
	end

	if type(resistance) ~= "number" or not isFiniteNumber(resistance) or resistance < 0 then
		fail("drag must be a non-negative finite number")
	end

	if resistance <= 0 then
		return origin + velocity * time + pull * (0.5 * time * time)
	end

	local terminal = pull / resistance
	local offset = velocity - terminal

	return origin + terminal * time + offset * ((1 - math.exp(-resistance * time)) / resistance)
end

table.freeze(Ballistics)

return Ballistics
