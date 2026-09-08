--!strict

local RunService = game:GetService("RunService")

local Errors = require(script.Parent.Parent.Util.Errors)

export type Disconnect = () -> ()
export type Connector = (callback: (deltaTime: number) -> ()) -> Disconnect
export type CostReader = () -> (number?, number?)

export type RuntimeOptions = {
	MaxShapeCastsPerHeartbeat: number?,
	MaxOverlapQueriesPerHeartbeat: number?,
}

export type RuntimeConfig = {
	read MaxShapeCastsPerHeartbeat: number?,
	read MaxOverlapQueriesPerHeartbeat: number?,
}

export type RuntimeStats = {
	Heartbeat: number,
	DeltaTime: number,
	Active: number,
	Executed: number,
	Deferred: number,
	Failed: number,
	ShapeCasts: number,
	OverlapQueries: number,
	MaxDeferredHeartbeats: number,
	ShapeCastBudgetReached: boolean,
	OverlapQueryBudgetReached: boolean,
	TimeMs: number,
	PeakHitboxTimeMs: number,
}

export type Controller = {
	configure: (options: RuntimeOptions) -> (),
	getConfig: () -> RuntimeConfig,
	getLastStats: () -> RuntimeStats?,
}

type Entry = {
	Key: any,
	Step: (deltaTime: number) -> (),
	OnError: (message: string) -> (),
	GetCost: CostReader,
	Priority: number,
	DeferredHeartbeats: number,
	RegistrationSequence: number,
}

local Runtime = {}
Runtime.__index = Runtime

export type Runtime = typeof(setmetatable(
	{} :: {
		_connect: Connector,
		_active: { [any]: Entry },
		_disconnect: Disconnect?,
		_connectionGeneration: number,
		_nextRegistrationSequence: number,
		_orderCache: { Entry },
		_orderDirty: boolean,
		_heartbeat: number,
		_maxShapeCastsPerHeartbeat: number?,
		_maxOverlapQueriesPerHeartbeat: number?,
		_workingStats: RuntimeStats,
		_lastStats: RuntimeStats,
		_hasLastStats: boolean,
		_lastStatsSnapshot: RuntimeStats?,
		_configSnapshot: RuntimeConfig?,
		_stepping: boolean,
		_destroyed: boolean,
	},
	Runtime
))

local defaultRuntime: Runtime? = nil

local function fail(message: string, code: string?): never
	return Errors.raise("VirtualHit MeleeRuntime", code or "InvalidArgument", message, 3)
end

local function traceback(message: any): string
	return debug.traceback(tostring(message), 2)
end

-- xpcall's type says the values after the boolean are the stepped function's
-- own, but Step returns nothing and on failure the second value is the
-- handler's traceback. Naming the real shape is what lets it be bound.
local guardedStep: ((number) -> (), (any) -> string, number) -> (boolean, any) = xpcall :: any

local function defaultConnector(callback: (deltaTime: number) -> ()): Disconnect
	local connection = RunService.Heartbeat:Connect(callback)

	return function()
		connection:Disconnect()
	end
end

local function safeDisconnect(disconnect: Disconnect, context: string)
	local success, message = pcall(function(): any
		disconnect()
		return nil
	end)

	if not success then
		warn(`VirtualHit query runtime {context} disconnect failed: {tostring(message)}`)
	end
end

local function optionalPositiveInteger(value: any, name: string): number?
	if value == nil then
		return nil
	end

	if
		type(value) ~= "number"
		or value ~= value
		or math.abs(value) == math.huge
		or value <= 0
		or value % 1 ~= 0
	then
		fail(`{name} must be a positive integer or nil`)
	end

	return value
end

local function finitePriority(value: any): number
	if value == nil then
		return 0
	end

	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		fail("priority must be a finite number")
	end

	return value
end

local function validateOptions(options: RuntimeOptions?): (number?, number?)
	if options == nil then
		return nil, nil
	end

	if type(options) ~= "table" then
		fail("options must be a table")
	end

	return optionalPositiveInteger(options.MaxShapeCastsPerHeartbeat, "MaxShapeCastsPerHeartbeat"),
		optionalPositiveInteger(
			options.MaxOverlapQueriesPerHeartbeat,
			"MaxOverlapQueriesPerHeartbeat"
		)
end

local function createStats(): RuntimeStats
	return {
		Heartbeat = 0,
		DeltaTime = 0,
		Active = 0,
		Executed = 0,
		Deferred = 0,
		Failed = 0,
		ShapeCasts = 0,
		OverlapQueries = 0,
		MaxDeferredHeartbeats = 0,
		ShapeCastBudgetReached = false,
		OverlapQueryBudgetReached = false,
		TimeMs = 0,
		PeakHitboxTimeMs = 0,
	}
end

local function resetStats(stats: RuntimeStats, heartbeat: number, deltaTime: number, active: number)
	stats.Heartbeat = heartbeat
	stats.DeltaTime = deltaTime
	stats.Active = active
	stats.Executed = 0
	stats.Deferred = 0
	stats.Failed = 0
	stats.ShapeCasts = 0
	stats.OverlapQueries = 0
	stats.MaxDeferredHeartbeats = 0
	stats.ShapeCastBudgetReached = false
	stats.OverlapQueryBudgetReached = false
	stats.TimeMs = 0
	stats.PeakHitboxTimeMs = 0
end

local function copyStats(target: RuntimeStats, source: RuntimeStats)
	target.Heartbeat = source.Heartbeat
	target.DeltaTime = source.DeltaTime
	target.Active = source.Active
	target.Executed = source.Executed
	target.Deferred = source.Deferred
	target.Failed = source.Failed
	target.ShapeCasts = source.ShapeCasts
	target.OverlapQueries = source.OverlapQueries
	target.MaxDeferredHeartbeats = source.MaxDeferredHeartbeats
	target.ShapeCastBudgetReached = source.ShapeCastBudgetReached
	target.OverlapQueryBudgetReached = source.OverlapQueryBudgetReached
	target.TimeMs = source.TimeMs
	target.PeakHitboxTimeMs = source.PeakHitboxTimeMs
end

local function activeCount(active: { [any]: Entry }): number
	local count = 0

	for _ in active do
		count += 1
	end

	return count
end

local function budgetReached(limit: number?, spent: number): boolean
	return limit ~= nil and spent >= limit
end

local function entryOrder(left: Entry, right: Entry): boolean
	if left.DeferredHeartbeats ~= right.DeferredHeartbeats then
		return left.DeferredHeartbeats > right.DeferredHeartbeats
	elseif left.Priority ~= right.Priority then
		return left.Priority > right.Priority
	end

	return left.RegistrationSequence < right.RegistrationSequence
end

local function queryCount(value: any, name: string): number
	if
		type(value) ~= "number"
		or value ~= value
		or math.abs(value) == math.huge
		or value < 0
		or value % 1 ~= 0
	then
		fail(`cost reader returned an invalid {name}`)
	end

	return value
end

function Runtime.new(connector: Connector?, options: RuntimeOptions?): Runtime
	if connector ~= nil and type(connector) ~= "function" then
		fail("connector must be a function")
	end

	local maxShapeCasts, maxOverlapQueries = validateOptions(options)

	return setmetatable({
		_connect = connector or defaultConnector,
		_active = {},
		_disconnect = nil,
		_connectionGeneration = 0,
		_nextRegistrationSequence = 0,
		_orderCache = {},
		_orderDirty = true,
		_heartbeat = 0,
		_maxShapeCastsPerHeartbeat = maxShapeCasts,
		_maxOverlapQueriesPerHeartbeat = maxOverlapQueries,
		_workingStats = createStats(),
		_lastStats = createStats(),
		_hasLastStats = false,
		_lastStatsSnapshot = nil,
		_configSnapshot = nil,
		_stepping = false,
		_destroyed = false,
	}, Runtime) :: any
end

local function disconnectIfIdle(self: Runtime)
	if self._stepping or next(self._active) ~= nil or self._disconnect == nil then
		return
	end

	local disconnect = self._disconnect
	self._disconnect = nil
	safeDisconnect(disconnect, "idle")
end

local function readCost(entry: Entry): (number, number)
	local shapeCasts, overlapQueries = entry.GetCost()

	if shapeCasts == nil and overlapQueries == nil then
		return 0, 0
	elseif shapeCasts == nil or overlapQueries == nil then
		fail("cost reader must return both query counts or neither")
	end

	return queryCount(shapeCasts, "ShapeCasts"), queryCount(overlapQueries, "OverlapQueries")
end

local function executeEntry(self: Runtime, entry: Entry, stats: RuntimeStats, deltaTime: number)
	entry.DeferredHeartbeats = 0
	stats.Executed += 1
	local startedAt = os.clock()
	-- Members that integrate over time (projectiles) need the frame delta;
	-- members that read poses (melee, zones) simply ignore the argument.
	--
	-- Both guarded calls pass their arguments through xpcall rather than
	-- capturing them. Two closures per member per Heartbeat is two hundred
	-- allocations a frame at the load this runtime exists to survive.
	local success, stepResult = guardedStep(entry.Step, traceback, deltaTime)
	-- On success the two extra results are the query counts; on failure the
	-- first is the traceback and the second is absent.
	local costSuccess, costFirst, costSecond = xpcall(readCost, traceback, entry)
	local shapeCasts = if costSuccess then costFirst :: number else 0
	local overlapQueries = if costSuccess then costSecond :: number else 0
	local timeMs = (os.clock() - startedAt) * 1_000
	stats.PeakHitboxTimeMs = math.max(stats.PeakHitboxTimeMs, timeMs)

	if costSuccess then
		stats.ShapeCasts += shapeCasts
		stats.OverlapQueries += overlapQueries
	end

	if success and costSuccess then
		return
	end

	stats.Failed += 1
	local failureMessage = if success
		then tostring(costFirst)
		elseif costSuccess then tostring(stepResult)
		else `{tostring(stepResult)}\nVirtualHit runtime cost reader failed:\n{tostring(
			costFirst
		)}`

	if self._active[entry.Key] == entry then
		self._active[entry.Key] = nil
		local handled, handlerMessage = pcall(function(): any
			entry.OnError(failureMessage)
			return nil
		end)

		if not handled then
			warn(`VirtualHit query runtime failure handler errored: {tostring(handlerMessage)}`)
		end
	else
		-- The member may have replaced itself while Step/GetCost was running.
		-- Never let a stale failure tear down that replacement, but keep the
		-- original failure observable for diagnostics.
		warn(`VirtualHit stale query runtime member failed after replacement:\n{failureMessage}`)
	end
end

function Runtime._step(self: Runtime, deltaTime: number?)
	if self._destroyed or self._stepping then
		return
	end

	local startedAt = os.clock()
	self._stepping = true
	self._heartbeat += 1
	local heartbeat = self._heartbeat
	local frameDelta = if type(deltaTime) == "number" then deltaTime else 0
	local maxShapeCasts = self._maxShapeCastsPerHeartbeat
	local maxOverlapQueries = self._maxOverlapQueriesPerHeartbeat
	-- The order only changes when membership changes or when deferral debt
	-- moved, and with no budget configured nothing ever defers. Re-sorting a
	-- few hundred stable entries every Heartbeat is pure waste, so the sorted
	-- array is kept and rebuilt only when it is actually stale.
	local snapshot = self._orderCache

	if self._orderDirty then
		table.clear(snapshot)

		for _, entry in self._active do
			table.insert(snapshot, entry)
		end

		table.sort(snapshot, entryOrder)
		self._orderDirty = false
	end

	local stats = self._workingStats
	-- The sorted snapshot already holds exactly the live members, so counting
	-- them and reading their deferral debt happen in the loop that was going to
	-- walk them anyway. Three passes over a few hundred entries was two too many.
	resetStats(stats, heartbeat, frameDelta, 0)
	local active = 0
	local maxDeferred = 0

	for _, entry in snapshot do
		if self._active[entry.Key] == entry then
			active += 1

			if
				budgetReached(maxShapeCasts, stats.ShapeCasts)
				or budgetReached(maxOverlapQueries, stats.OverlapQueries)
			then
				entry.DeferredHeartbeats += 1
				stats.Deferred += 1
			else
				if entry.DeferredHeartbeats > 0 then
					-- Clearing debt changes the ordering key.
					self._orderDirty = true
				end

				executeEntry(self, entry, stats, frameDelta)
			end

			if entry.DeferredHeartbeats > maxDeferred then
				maxDeferred = entry.DeferredHeartbeats
			end
		end
	end

	if stats.Deferred > 0 then
		self._orderDirty = true
	end

	stats.Active = active
	stats.MaxDeferredHeartbeats = maxDeferred
	stats.ShapeCastBudgetReached = budgetReached(maxShapeCasts, stats.ShapeCasts)
	stats.OverlapQueryBudgetReached = budgetReached(maxOverlapQueries, stats.OverlapQueries)
	stats.TimeMs = (os.clock() - startedAt) * 1_000
	copyStats(self._lastStats, stats)
	self._hasLastStats = true
	self._lastStatsSnapshot = nil
	self._stepping = false
	disconnectIfIdle(self)
end

function Runtime.Add(
	self: Runtime,
	key: any,
	step: (deltaTime: number) -> (),
	onError: (message: string) -> (),
	priority: number?,
	getCost: CostReader?
)
	if self._destroyed then
		fail("cannot Add to a destroyed runtime")
	end

	if key == nil then
		fail("key cannot be nil")
	end

	if type(step) ~= "function" or type(onError) ~= "function" then
		fail("step and onError must be functions")
	end

	if getCost ~= nil and type(getCost) ~= "function" then
		fail("getCost must be a function")
	end

	local resolvedPriority = finitePriority(priority)

	if self._active[key] ~= nil then
		return
	end

	self._nextRegistrationSequence += 1
	local entry: Entry = {
		Key = key,
		Step = step,
		OnError = onError,
		GetCost = getCost or function()
			return nil, nil
		end,
		Priority = resolvedPriority,
		DeferredHeartbeats = 0,
		RegistrationSequence = self._nextRegistrationSequence,
	}
	self._active[key] = entry
	self._orderDirty = true

	if self._disconnect == nil then
		local connected, disconnectOrMessage = xpcall(function(): any
			return self._connect(function(frameDelta)
				self:_step(frameDelta)
			end)
		end, traceback)

		if not connected then
			if self._active[key] == entry then
				self._active[key] = nil
			end

			disconnectIfIdle(self)
			error(disconnectOrMessage, 0)
		end

		if type(disconnectOrMessage) ~= "function" then
			if self._active[key] == entry then
				self._active[key] = nil
			end

			disconnectIfIdle(self)
			fail("connector must return a disconnect function")
		end

		if self._destroyed then
			safeDisconnect(disconnectOrMessage, "destroyed connector")
			fail("runtime was destroyed while its connector was starting")
		end

		if self._disconnect == nil then
			self._disconnect = disconnectOrMessage
			self._connectionGeneration += 1
			disconnectIfIdle(self)
		else
			-- A synchronous connector callback can remove/re-add a member and
			-- finish a nested connection before this outer connector returns.
			-- Keep the already-published connection and close this superseded one.
			safeDisconnect(disconnectOrMessage, "superseded")
		end
	end
end

function Runtime.Remove(self: Runtime, key: any)
	if self._active[key] ~= nil then
		self._active[key] = nil
		self._orderDirty = true
	end

	disconnectIfIdle(self)
end

function Runtime.Configure(self: Runtime, options: RuntimeOptions)
	if self._destroyed then
		fail("cannot Configure a destroyed runtime")
	end

	local maxShapeCasts, maxOverlapQueries = validateOptions(options)
	self._maxShapeCastsPerHeartbeat = maxShapeCasts
	self._maxOverlapQueriesPerHeartbeat = maxOverlapQueries
	self._configSnapshot = nil
end

function Runtime.GetConfig(self: Runtime): RuntimeConfig
	local snapshot = self._configSnapshot

	if snapshot == nil then
		snapshot = table.freeze({
			MaxShapeCastsPerHeartbeat = self._maxShapeCastsPerHeartbeat,
			MaxOverlapQueriesPerHeartbeat = self._maxOverlapQueriesPerHeartbeat,
		})
		self._configSnapshot = snapshot
	end

	return snapshot :: RuntimeConfig
end

function Runtime.GetLastStats(self: Runtime): RuntimeStats?
	if not self._hasLastStats then
		return nil
	end

	local snapshot = self._lastStatsSnapshot

	if snapshot == nil then
		snapshot = table.freeze(table.clone(self._lastStats))
		self._lastStatsSnapshot = snapshot
	end

	return snapshot
end

function Runtime.GetActiveCount(self: Runtime): number
	return activeCount(self._active)
end

function Runtime.IsConnected(self: Runtime): boolean
	return self._disconnect ~= nil
end

function Runtime.GetConnectionGeneration(self: Runtime): number
	return self._connectionGeneration
end

function Runtime.Destroy(self: Runtime)
	if self._destroyed then
		return
	end

	if self == defaultRuntime then
		fail("cannot Destroy the default runtime")
	end

	local entries: { Entry } = {}

	for _, entry in self._active do
		table.insert(entries, entry)
	end

	table.sort(entries, function(left: Entry, right: Entry)
		return left.RegistrationSequence < right.RegistrationSequence
	end)

	self._destroyed = true
	table.clear(self._active)

	if self._disconnect ~= nil then
		local disconnect = self._disconnect
		self._disconnect = nil
		safeDisconnect(disconnect, "destroy")
	end

	for _, entry in entries do
		local handled, message = pcall(function(): any
			entry.OnError("VirtualHit query runtime was destroyed while its member was active")
			return nil
		end)

		if not handled then
			warn(`VirtualHit query runtime destroy handler errored: {tostring(message)}`)
		end
	end
end

local sharedDefaultRuntime = Runtime.new()
defaultRuntime = sharedDefaultRuntime
Runtime.Default = sharedDefaultRuntime

local publicController: Controller = {
	configure = function(options: RuntimeOptions)
		sharedDefaultRuntime:Configure(options)
	end,
	getConfig = function(): RuntimeConfig
		return sharedDefaultRuntime:GetConfig()
	end,
	getLastStats = function(): RuntimeStats?
		return sharedDefaultRuntime:GetLastStats()
	end,
}

Runtime.Public = table.freeze(publicController)

return table.freeze(Runtime)
