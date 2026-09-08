--!strict

local RewindWorld = require(script.Parent.RewindWorld)
local Errors = require(script.Parent.Parent.Util.Errors)
local Config = require(script.Parent.Parent.Config)

-- Live config section. Read through it so VirtualHit.configure() takes
-- effect without reloading the library.
local Tuning = Config.Validator

-- Everything a client sends about a shot is untrusted: when it happened, where
-- it started, where it pointed. The Validator does not decide whether a shot
-- hit; it decides whether the claim is plausible enough to be worth replaying
-- against the server's own history, and hands back the rewound WorldModel to
-- replay it in.

-- Passing validation is not proof. It only means the claim survived the bounds
-- the game chose. The geometry query that follows is still the authority.

local Validator = {}
Validator.__index = Validator

export type Rejection =
	"Malformed"
	| "Stale"
	| "Future"
	| "RateLimited"
	| "OutsideHistory"
	| "OriginTooFar"
	| "DirectionTooFar"
	| "DistanceTooFar"
	| "NoHistory"
	| "StaleHistory"
	| "NoSourceHistory"

-- Everything in a claim comes from the client and is therefore untrusted. The
-- rate-limit identity is deliberately NOT in here: it is a separate argument to
-- Validate that the server supplies, so a client cannot rotate or blank it to
-- escape its own budget.
export type Claim = {
	read Timestamp: number,
	read Origin: Vector3,
	read Direction: Vector3,
	read Distance: number?,
}

-- What the server itself believes about the shooter. The claim is measured
-- against this, never the other way round.

-- Origin is where the server has the shooter now. That is the wrong thing to
-- compare a claim against on its own: across a 200 ms round trip a running
-- player has moved several studs, and a strict MaxOriginError then rejects
-- honest shots. Passing Source -- the shooter's own tracked part -- makes the
-- comparison against where it actually was at the claimed moment instead, which
-- is the only comparison lag compensation can defend.
export type ServerPose = {
	read Origin: Vector3,
	read Direction: Vector3?,
	read Source: BasePart?,
	-- Where the muzzle sits relative to Source, in Source space.
	read Offset: CFrame?,
}

-- The shot the server is willing to simulate, which is not the one the client
-- described. Origin is the server's own belief about where the shooter was;
-- Direction is the client's aim, normalised, after it survived the discrepancy
-- bound. Nothing downstream should reach back for the raw claim: it was the
-- evidence, and this is what replaced it.
export type ValidatedShot = {
	read Timestamp: number,
	read Origin: Vector3,
	read Direction: Vector3,
	read Distance: number,
	read Latency: number,
}

export type Verdict = {
	read Accepted: boolean,
	read Reason: Rejection?,
	read Timestamp: number,
	read Latency: number,
	read OriginError: number,
	read DirectionError: number,
	read Distance: number,
	read WorldRoot: WorldModel?,
	read Info: RewindWorld.RewindInfo?,
	-- True when OriginError was measured against the shooter's recorded pose at
	-- the claimed moment rather than against its position now.
	read OriginFromHistory: boolean,
	-- Present only on an accepted verdict. Use it instead of the claim.
	read Shot: ValidatedShot?,
}

export type ValidatorOptions = {
	World: RewindWorld.RewindWorld,
	MaxLatency: number?,
	MinLatency: number?,
	-- Accepted claims per second per actor, as a token bucket.
	MaxRate: number?,
	MaxOriginError: number?,
	MaxDirectionError: number?,
	MaxDistance: number?,
	-- How old the newest snapshot may be. Zero disables the check.
	MaxHistoryAge: number?,
	-- With a ServerPose.Source given but no recorded pose for it at the claimed
	-- moment, the origin check falls back to where the shooter stands now. That
	-- is a sensible default and a real hole in a high-security mode: a shooter
	-- who was not being tracked then gets measured against its position now, and
	-- the claim can still pass. Setting this rejects instead.
	RequireHistoricalOrigin: boolean?,
	Clock: (() -> number)?,
}

type Bucket = {
	Tokens: number,
	Last: number,
}

export type Validator = typeof(setmetatable(
	{} :: {
		_world: RewindWorld.RewindWorld,
		_maxLatency: number,
		_minLatency: number,
		_maxRate: number,
		_maxOriginError: number,
		_maxDirectionError: number,
		_maxDistance: number,
		_maxHistoryAge: number,
		_requireHistoricalOrigin: boolean,
		_clock: () -> number,
		_buckets: { [any]: Bucket },
	},
	Validator
))

-- A rejected claim never runs the query, so there is no `T...` to hand back
-- beside the verdict -- and Luau has no way to spell an empty generic pack.
-- Going through a value typed as the whole pack returns the verdict alone,
-- which is what it returned before the pack existed.
local rejectOnly = function(verdict: Verdict)
	return verdict
end :: any

local function fail(message: string, code: string?): never
	return Errors.raise("VirtualHit.rewind validator", code or "InvalidArgument", message, 3)
end

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function isFiniteVector3(value: Vector3): boolean
	return isFiniteNumber(value.X) and isFiniteNumber(value.Y) and isFiniteNumber(value.Z)
end

local function nonNegative(value: any, name: string, defaultValue: number): number
	if value == nil then
		return defaultValue
	end

	if type(value) ~= "number" or not isFiniteNumber(value) or value < 0 then
		fail(`options.{name} must be a non-negative number`)
	end

	return value
end

function Validator.new(options: ValidatorOptions): Validator
	if type(options) ~= "table" then
		fail("expected an options table")
	end

	local world = options.World

	if type(world) ~= "table" or type((world :: any).RewindTo) ~= "function" then
		fail("options.World must come from VirtualHit.rewind()")
	end

	if options.Clock ~= nil and type(options.Clock) ~= "function" then
		fail("options.Clock must be a function")
	end

	local maxLatency = nonNegative(options.MaxLatency, "MaxLatency", Tuning.MaxLatency)
	local minLatency = nonNegative(options.MinLatency, "MinLatency", Tuning.MinLatency)

	if minLatency > maxLatency then
		fail("options.MinLatency cannot exceed options.MaxLatency")
	end

	return (
		setmetatable({
			_world = world,
			_maxLatency = maxLatency,
			_minLatency = minLatency,
			_maxRate = nonNegative(options.MaxRate, "MaxRate", Tuning.MaxRate),
			_maxOriginError = nonNegative(
				options.MaxOriginError,
				"MaxOriginError",
				Tuning.MaxOriginError
			),
			_maxDirectionError = nonNegative(
				options.MaxDirectionError,
				"MaxDirectionError",
				Tuning.MaxDirectionError
			),
			_maxDistance = nonNegative(options.MaxDistance, "MaxDistance", Tuning.MaxDistance),
			_maxHistoryAge = nonNegative(
				options.MaxHistoryAge,
				"MaxHistoryAge",
				Tuning.MaxHistoryAge
			),
			_requireHistoricalOrigin = options.RequireHistoricalOrigin == true,
			-- Weak keys so a Player leaving does not keep its bucket alive.
			_buckets = setmetatable({}, { __mode = "k" }) :: any,
			-- Must be the same clock domain the rewind world records in, and the
			-- same one the client stamps its claims with.
			_clock = options.Clock or RewindWorld.DefaultClock,
		}, Validator) :: any
	) :: Validator
end

local function rejection(
	reason: Rejection,
	timestamp: number,
	latency: number,
	originError: number,
	directionError: number,
	distance: number,
	originFromHistory: boolean?
): Verdict
	return table.freeze({
		Accepted = false,
		Reason = reason,
		Timestamp = timestamp,
		Latency = latency,
		OriginError = originError,
		DirectionError = directionError,
		Distance = distance,
		WorldRoot = nil,
		Info = nil,
		OriginFromHistory = originFromHistory == true,
		Shot = nil,
	})
end

-- Token bucket: MaxRate tokens per second, capped at MaxRate. A zero rate
-- disables limiting entirely.
function Validator._consumeToken(self: Validator, actor: any, now: number): boolean
	if self._maxRate <= 0 or actor == nil then
		return true
	end

	local bucket = self._buckets[actor]

	if bucket == nil then
		self._buckets[actor] = {
			Tokens = self._maxRate - 1,
			Last = now,
		}
		return true
	end

	local elapsed = math.max(now - bucket.Last, 0)
	bucket.Last = now
	bucket.Tokens = math.min(bucket.Tokens + elapsed * self._maxRate, self._maxRate)

	if bucket.Tokens < 1 then
		return false
	end

	bucket.Tokens -= 1
	return true
end

-- The actor is the first argument on purpose. It is the server's own identity
-- for the shooter, and keeping it out of the claim table makes it impossible
-- for a client payload to change or erase the key its rate limit is charged to.
-- Everything except the rewind. Split out so ValidateAndQuery can hold the
-- rewind inside a lease rather than handing one out, and so the two entry
-- points cannot drift apart.
function Validator._check(
	self: Validator,
	actor: any,
	claim: Claim,
	serverPose: ServerPose
): (Verdict?, ValidatedShot?, number, number, boolean)
	if type(claim) ~= "table" or type(serverPose) ~= "table" then
		fail("Validate expects an actor, a claim table and a server pose table")
	end

	if actor == nil and self._maxRate > 0 then
		fail("Validate requires a server-owned actor while rate limiting is enabled")
	end

	local now = self._clock()
	local timestamp = claim.Timestamp
	local origin = claim.Origin
	local direction = claim.Direction
	local serverOrigin = serverPose.Origin

	if
		type(timestamp) ~= "number"
		or not isFiniteNumber(timestamp)
		or typeof(origin) ~= "Vector3"
		or not isFiniteVector3(origin)
		or typeof(direction) ~= "Vector3"
		or not isFiniteVector3(direction)
		or direction.Magnitude <= 1e-4
		or typeof(serverOrigin) ~= "Vector3"
		or not isFiniteVector3(serverOrigin)
	then
		return rejection("Malformed", now, 0, 0, 0, 0), nil, 0, 0, false
	end

	-- Normalised here rather than demanded of the client. A claim carrying a
	-- 500 stud direction vector is not an attack, it is a caller that scaled by
	-- range -- and the aim comparison below reads .Unit anyway, so it would sail
	-- through and then blow up inside cast(), several layers from the cause.
	local unitDirection = direction.Unit

	if not isFiniteVector3(unitDirection) then
		return rejection("Malformed", now, 0, 0, 0, 0), nil, 0, 0, false
	end

	-- The claimed value and the validated one are separate names on purpose.
	-- Distance arrives from a client, so every runtime guard below still has to
	-- run; keeping them apart is what lets the validated one be a plain number
	-- from here down, in the type system as well as in fact.
	local claimedDistance = claim.Distance
	local distance: number

	if claimedDistance == nil then
		distance = 0
	elseif
		type(claimedDistance) ~= "number"
		or not isFiniteNumber(claimedDistance)
		or claimedDistance < 0
	then
		return rejection("Malformed", now, 0, 0, 0, 0), nil, 0, 0, false
	else
		distance = claimedDistance
	end

	local latency = now - timestamp
	-- Where the shooter was when it says it fired, when the world was recording
	-- it. Comparing a claim to where the shooter stands now measures the round
	-- trip, not the claim.
	local reference = serverOrigin
	local originFromHistory = false
	local source = serverPose.Source

	if source ~= nil then
		if typeof(source) ~= "Instance" or not source:IsA("BasePart") then
			return rejection("Malformed", now, 0, 0, 0, 0), nil, 0, 0, false
		end

		local offset = serverPose.Offset

		if offset ~= nil and typeof(offset) ~= "CFrame" then
			return rejection("Malformed", now, 0, 0, 0, 0), nil, 0, 0, false
		end

		local historical = self._world:GetPoseAt(source, timestamp)

		if historical ~= nil then
			local pose = historical :: CFrame
			reference = if offset == nil then pose.Position else (pose * offset).Position
			originFromHistory = true
		elseif self._requireHistoricalOrigin then
			-- A Source was named and the world has nothing recorded for it then.
			-- Falling back to where it stands now is the permissive answer; a
			-- shooter that was not being tracked at the claimed moment would get
			-- measured against the present and pass anyway.
			return rejection("NoSourceHistory", timestamp, now - timestamp, 0, 0, 0, false),
				nil,
				0,
				0,
				false
		end
	end

	local originError = (origin - reference).Magnitude
	local directionError = 0
	local serverDirection = serverPose.Direction

	if serverDirection ~= nil and serverDirection.Magnitude > 1e-4 then
		local cosine = math.clamp(unitDirection:Dot(serverDirection.Unit), -1, 1)
		directionError = math.acos(cosine)
	end

	if latency > self._maxLatency then
		return rejection(
			"Stale",
			timestamp,
			latency,
			originError,
			directionError,
			distance,
			originFromHistory
		),
			nil,
			originError,
			directionError,
			originFromHistory
	end

	if latency < self._minLatency then
		return rejection(
			"Future",
			timestamp,
			latency,
			originError,
			directionError,
			distance,
			originFromHistory
		),
			nil,
			originError,
			directionError,
			originFromHistory
	end

	if originError > self._maxOriginError then
		return rejection(
			"OriginTooFar",
			timestamp,
			latency,
			originError,
			directionError,
			distance,
			originFromHistory
		),
			nil,
			originError,
			directionError,
			originFromHistory
	end

	if directionError > self._maxDirectionError then
		return rejection(
			"DirectionTooFar",
			timestamp,
			latency,
			originError,
			directionError,
			distance,
			originFromHistory
		),
			nil,
			originError,
			directionError,
			originFromHistory
	end

	if distance > self._maxDistance then
		return rejection(
			"DistanceTooFar",
			timestamp,
			latency,
			originError,
			directionError,
			distance,
			originFromHistory
		),
			nil,
			originError,
			directionError,
			originFromHistory
	end

	local stats = self._world:GetStats()

	if stats.Snapshots == 0 then
		return rejection(
			"NoHistory",
			timestamp,
			latency,
			originError,
			directionError,
			distance,
			originFromHistory
		),
			nil,
			originError,
			directionError,
			originFromHistory
	end

	-- The newest snapshot is only the present while something is still writing
	-- snapshots. A recorder that stalled leaves RewindTo silently clamping every
	-- fresh claim onto whatever it managed to record last, so the claim gets
	-- checked against a world that is minutes old and nothing says so.
	local newest = stats.Newest

	if
		self._maxHistoryAge > 0
		and newest ~= nil
		and now - (newest :: number) > self._maxHistoryAge
	then
		return rejection(
			"StaleHistory",
			timestamp,
			latency,
			originError,
			directionError,
			distance,
			originFromHistory
		),
			nil,
			originError,
			directionError,
			originFromHistory
	end

	-- RewindTo clamps a timestamp it cannot reach. Accepting one and letting it
	-- clamp would test the claim against a world state it never described, so a
	-- claim older than the recorded window is refused outright. A claim newer
	-- than the newest snapshot is fine once the history itself is fresh, and
	-- MinLatency already governs how far ahead a claim may sit.
	local oldest = stats.Oldest

	if oldest ~= nil and timestamp < oldest then
		return rejection(
			"OutsideHistory",
			timestamp,
			latency,
			originError,
			directionError,
			distance,
			originFromHistory
		),
			nil,
			originError,
			directionError,
			originFromHistory
	end

	-- Rate limiting is charged last so a claim rejected on its own merits does
	-- not also burn the shooter's budget.
	if not self:_consumeToken(actor, now) then
		return rejection(
			"RateLimited",
			timestamp,
			latency,
			originError,
			directionError,
			distance,
			originFromHistory
		),
			nil,
			originError,
			directionError,
			originFromHistory
	end

	-- Accepted. What comes back is the shot the server is willing to simulate,
	-- not the one the client described.

	-- Origin is the server's own belief -- the shooter's recorded pose at the
	-- claimed moment when it was tracked, its position now when it was not.
	-- The claim's Origin is never carried forward: it was only ever evidence,
	-- and it has already been weighed.

	-- Direction is the client's, normalised. That is deliberate: the whole
	-- point of lag compensation is that the shooter's aim at their own moment
	-- is more truthful than the server's stale copy of it, and the aim it
	-- carries has already been bounded against the server's by
	-- MaxDirectionError.
	local shot: ValidatedShot = table.freeze({
		Timestamp = timestamp,
		Origin = reference,
		Direction = unitDirection,
		Distance = distance,
		Latency = latency,
	})

	return nil, shot, originError, directionError, originFromHistory
end

-- Advanced. Prefer ValidateAndQuery for a single authoritative query.

-- Validates a claim and hands back the rewound world to replay it in. That
-- WorldRoot is a lease in everything but name: there is one set of proxies, so
-- the next Validate moves them and the caller holding this one is now querying
-- a different instant with nothing to say so.

-- This exists for callers that genuinely need several queries against the same
-- moment, and it puts the lease discipline on them. Everything else wants
-- ValidateAndQuery, which closes the lease itself and never hands a world out.
function Validator.Validate(
	self: Validator,
	actor: any,
	claim: Claim,
	serverPose: ServerPose
): Verdict
	local rejected, shot, originError, directionError, fromHistory =
		self:_check(actor, claim, serverPose)

	if rejected ~= nil then
		return rejected
	end

	local accepted = shot :: ValidatedShot
	local root, info = self._world:RewindTo(accepted.Timestamp)

	return table.freeze({
		Accepted = true,
		Reason = nil,
		Timestamp = accepted.Timestamp,
		Latency = accepted.Latency,
		OriginError = originError,
		DirectionError = directionError,
		Distance = accepted.Distance,
		WorldRoot = root,
		Info = info,
		OriginFromHistory = fromHistory,
		Shot = accepted,
	})
end

-- Validate, rewind, query and restore, as one transaction.

-- The dangerous shape of Validate is that the caller holds a rewound world
-- across code it does not control, and the next validation moves it. Here the
-- world never leaves the callback, so it cannot be held at all.

-- The callback is handed the sanitised shot rather than being trusted to reach
-- back for the claim. Nothing downstream should ever see the raw claim again:
-- it was the evidence, and the verdict is what replaced it.
function Validator.ValidateAndQuery<T...>(
	self: Validator,
	actor: any,
	claim: Claim,
	serverPose: ServerPose,
	query: (
		shot: ValidatedShot,
		worldRoot: WorldModel,
		info: RewindWorld.RewindInfo
	) -> T...
): (Verdict, T...)
	if type(query) ~= "function" then
		fail("ValidateAndQuery expects a function to run against the rewound world")
	end

	local rejected, shot, originError, directionError, fromHistory =
		self:_check(actor, claim, serverPose)

	if rejected ~= nil then
		return (rejectOnly :: (Verdict) -> (Verdict, T...))(rejected)
	end

	local accepted = shot :: ValidatedShot

	-- No WorldRoot on the verdict, because by the time it is returned the lease
	-- is closed and the proxies are back at the present. Handing one out would
	-- be handing out something already stale.
	local verdict: Verdict = table.freeze({
		Accepted = true,
		Reason = nil,
		Timestamp = accepted.Timestamp,
		Latency = accepted.Latency,
		OriginError = originError,
		DirectionError = directionError,
		Distance = accepted.Distance,
		WorldRoot = nil,
		Info = nil,
		OriginFromHistory = fromHistory,
		Shot = accepted,
	})

	return verdict,
		self._world:WithTime(accepted.Timestamp, function(worldRoot, info)
			return query(accepted, worldRoot, info)
		end)
end

-- The rewind world holds one set of proxies, so a returned WorldRoot is only
-- posed for the claim that produced it. Query it before validating anything
-- else.
function Validator.Forget(self: Validator, actor: any)
	if actor ~= nil then
		self._buckets[actor] = nil
	end
end

function Validator.Reset(self: Validator)
	self._buckets = setmetatable({}, { __mode = "k" }) :: any
end

function Validator.GetWorld(self: Validator): RewindWorld.RewindWorld
	return self._world
end

return Validator
