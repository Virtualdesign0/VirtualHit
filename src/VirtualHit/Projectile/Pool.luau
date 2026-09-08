--!strict

local Signal = require(script.Parent.Parent.Util.Signal)
local RuntimeClass = require(script.Parent.Parent.Melee.Runtime)
local Projectile = require(script.Parent.Projectile)
local StopReason = require(script.Parent.StopReason)
local Errors = require(script.Parent.Parent.Util.Errors)
local Config = require(script.Parent.Parent.Config)

-- Live config section. Read through it so VirtualHit.configure() takes effect
-- without reloading the library.
local Tuning = Config.Pool

-- Every projectile owns a Sweep, and every Sweep owns one query probe per
-- member. Spawning a projectile per shot therefore creates and destroys
-- Instances at the fire rate of the weapon, which is exactly the wrong thing to
-- do in a multiplayer game where a dozen players are firing at once.

-- A pool keeps a set of identically configured projectiles alive and re-arms
-- them instead. The template is fixed at construction because two projectiles
-- can only share a body if they share their shape, filter and policy.

local Pool = {}
Pool.__index = Pool

-- The flight-specific half of ProjectileOptions. Everything else is the
-- template and cannot vary per shot.
export type PoolLaunch = Projectile.LaunchOptions

export type PoolOptions = {
	-- ProjectileOptions without Origin, Velocity, Direction or Speed.
	Template: { [string]: any },
	-- Bodies built up front, before the first shot has to pay for one.
	Prewarm: number?,
	-- Idle bodies retained. Beyond this a returning projectile is destroyed
	-- rather than kept, so a burst does not permanently inflate the pool.
	MaxIdle: number?,
}

export type PoolStats = {
	read Idle: number,
	read Live: number,
	read Created: number,
	read Reused: number,
	read Discarded: number,
}

local LAUNCH_FIELDS = { "Origin", "Velocity", "Direction", "Speed" }

export type Pool = typeof(setmetatable(
	{} :: {
		-- Fires for every projectile the pool launches, so a caller can attach
		-- listeners in one place instead of per shot.
		Launched: Signal.Signal<Projectile.Projectile>,
		Returned: Signal.Signal<Projectile.Projectile, StopReason.StopReason>,
		_template: { [string]: any },
		_maxIdle: number,
		_runtime: RuntimeClass.Runtime?,
		_idle: { Projectile.Projectile },
		_live: { [Projectile.Projectile]: Signal.Connection },
		_liveCount: number,
		_created: number,
		_reused: number,
		_discarded: number,
		_destroyed: boolean,
		_launchedEvent: Signal.Emitter<Projectile.Projectile>,
		_returnedEvent: Signal.Emitter<Projectile.Projectile, StopReason.StopReason>,
	},
	Pool
))

local function fail(message: string, code: string?): never
	return Errors.raise("VirtualHit.projectilePool", code or "InvalidArgument", message, 3)
end

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function positiveInteger(value: any, name: string, defaultValue: number): number
	if value == nil then
		return defaultValue
	end

	if type(value) ~= "number" or not isFiniteNumber(value) or value < 0 or value % 1 ~= 0 then
		fail(`options.{name} must be a non-negative integer`)
	end

	return value
end

-- table.clone is shallow, so a nested Ricochet or Sweep table stayed shared
-- with whoever passed the template in. Mutating it afterwards left bodies built
-- before the change configured one way and bodies built after it another, and
-- the difference only surfaced once a reuse handed out the older one.

-- Objects are left alone deliberately. A Filter, a HitRegistry or a shape
-- descriptor is meant to be shared, is identified by identity, and carries a
-- metatable a copy would lose. Frozen tables cannot drift in the first place.
local function snapshotConfig(value: any): any
	if type(value) ~= "table" or table.isfrozen(value) or getmetatable(value) ~= nil then
		return value
	end

	local copy: { [any]: any } = {}

	for key, nested in value do
		copy[key] = snapshotConfig(nested)
	end

	return copy
end

-- A body is built with a placeholder launch so its Sweep and probes exist
-- before the first real shot. Relaunch overwrites every flight value.
local function buildBody(self: Pool): Projectile.Projectile
	local options: { [string]: any } = table.clone(self._template)
	options.Origin = Vector3.zero
	options.Direction = Vector3.zAxis
	options.Speed = 1

	self._created += 1
	return Projectile.new(options :: any, self._runtime)
end

function Pool.new(options: PoolOptions, runtimeOverride: RuntimeClass.Runtime?): Pool
	if type(options) ~= "table" then
		fail("expected an options table")
	end

	local template = options.Template

	if type(template) ~= "table" then
		fail("options.Template must be a table of ProjectileOptions")
	end

	for _, field in LAUNCH_FIELDS do
		if template[field] ~= nil then
			fail(`options.Template.{field} belongs to a launch, not to the pool template`)
		end
	end

	local launchedEvent: Signal.Emitter<Projectile.Projectile> = Signal.new()
	local returnedEvent: Signal.Emitter<Projectile.Projectile, StopReason.StopReason> = Signal.new()

	local pool = (
		setmetatable({
			Launched = launchedEvent,
			Returned = returnedEvent,
			_template = snapshotConfig(template),
			_maxIdle = positiveInteger(options.MaxIdle, "MaxIdle", Tuning.MaxIdle),
			_runtime = runtimeOverride,
			_idle = {},
			_live = {},
			_liveCount = 0,
			_created = 0,
			_reused = 0,
			_discarded = 0,
			_destroyed = false,
			_launchedEvent = launchedEvent,
			_returnedEvent = returnedEvent,
		}, Pool) :: any
	) :: Pool

	local prewarm = positiveInteger(options.Prewarm, "Prewarm", 0)

	for _ = 1, prewarm do
		table.insert(pool._idle, buildBody(pool))
	end

	return pool
end

local function release(self: Pool, projectile: Projectile.Projectile)
	local connection = self._live[projectile]

	if connection == nil then
		return
	end

	self._live[projectile] = nil
	self._liveCount -= 1
	connection:Disconnect()

	if self._destroyed or #self._idle >= self._maxIdle then
		self._discarded += 1
		projectile:Destroy()
		return
	end

	table.insert(self._idle, projectile)
end

-- Launches a body from the pool. The returned handle is valid until its Stopped
-- signal fires; after that the pool owns it again and may re-arm it for someone
-- else, so callers must not hold on to it past that point.
function Pool.Fire(self: Pool, launch: PoolLaunch): Projectile.Projectile
	if self._destroyed then
		fail("cannot Fire from a destroyed pool", "Destroyed")
	end

	if type(launch) ~= "table" then
		fail("Fire expects a launch table")
	end

	local projectile = table.remove(self._idle)

	if projectile == nil then
		projectile = buildBody(self)
	else
		self._reused += 1
	end

	local body = projectile :: Projectile.Projectile
	local armed, message = pcall(function(): any
		body:Relaunch(launch)
		return nil
	end)

	if not armed then
		-- A body that failed to arm is in an unknown state; it does not go back
		-- into the pool.
		self._discarded += 1
		body:Destroy()
		error(message, 0)
	end

	-- Connected before Start so a projectile that stops inside its very first
	-- step is still returned.
	self._live[body] = body.Stopped:Connect(function(reason: StopReason.StopReason)
		self._returnedEvent:Fire(body, reason)
		release(self, body)
	end)
	self._liveCount += 1

	local started, startMessage = pcall(function(): any
		body:Start()
		return nil
	end)

	if not started then
		release(self, body)
		error(startMessage, 0)
	end

	self._launchedEvent:Fire(body)
	return body
end

function Pool.GetStats(self: Pool): PoolStats
	return table.freeze({
		Idle = #self._idle,
		Live = self._liveCount,
		Created = self._created,
		Reused = self._reused,
		Discarded = self._discarded,
	})
end

function Pool.IsDestroyed(self: Pool): boolean
	return self._destroyed
end

function Pool.Destroy(self: Pool)
	if self._destroyed then
		return
	end

	self._destroyed = true

	local live: { Projectile.Projectile } = {}

	for projectile in self._live do
		table.insert(live, projectile)
	end

	for _, projectile in live do
		local connection = self._live[projectile]

		if connection ~= nil then
			self._live[projectile] = nil
			connection:Disconnect()
		end

		projectile:Destroy()
	end

	self._liveCount = 0

	for _, projectile in self._idle do
		projectile:Destroy()
	end

	table.clear(self._idle)
	self._launchedEvent:Destroy()
	self._returnedEvent:Destroy()
end

return Pool
