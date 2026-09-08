--!strict

local Workspace = game:GetService("Workspace")

local Types = require(script.Parent.Parent.Types)
local FilterClass = require(script.Parent.Parent.Collision.Filter)
local HitPolicy = require(script.Parent.Parent.Sweep.HitPolicy)
local SweepClass = require(script.Parent.Parent.Sweep.Sweep)
local DetailFieldClass = require(script.Parent.Parent.Detail.DetailField)
local Signal = require(script.Parent.Parent.Util.Signal)
local RuntimeClass = require(script.Parent.Runtime)
local StopReason = require(script.Parent.StopReason)
local Errors = require(script.Parent.Parent.Util.Errors)

export type MeleeSource = BasePart | Attachment
export type MeleeStopReason = StopReason.StopReason

export type MeleeOptions = {
	Source: MeleeSource,
	Shape: Types.SweepShape,
	Offset: CFrame?,
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
	Priority: number?,
	Sweep: SweepClass.SweepConfig?,
	-- Scales the step limits by distance to the nearest observer. See
	-- VirtualHit.detail().
	Detail: DetailFieldClass.DetailField?,
}

local MeleeHitbox = {}
MeleeHitbox.__index = MeleeHitbox

export type MeleeHitbox = typeof(setmetatable(
	{} :: {
		Source: MeleeSource,
		-- These virtual properties are enforced as read-only at runtime by
		-- __newindex. The pinned Luau analyzer does not yet accept property
		-- access modifiers in this structural typeof declaration.
		Shape: Types.SweepShape,
		Priority: number,
		Hit: Signal.Signal<Types.SweepHit>,
		Blocked: Signal.Signal<Types.SweepBlock>,
		Started: Signal.VoidSignal,
		Stopped: Signal.Signal<StopReason.StopReason>,
		Error: Signal.Signal<string>,
		_source: MeleeSource,
		_shape: Types.SweepShape,
		_priority: number,
		_worldRoot: WorldRoot,
		_sweep: SweepClass.Sweep,
		_runtime: RuntimeClass.Runtime,
		_hitEvent: Signal.Emitter<Types.SweepHit>,
		_blockedEvent: Signal.Emitter<Types.SweepBlock>,
		_startedEvent: Signal.VoidEmitter,
		_stoppedEvent: Signal.Emitter<StopReason.StopReason>,
		_errorEvent: Signal.Emitter<string>,
		_previous: CFrame?,
		_carrier: BasePart?,
		_sourceParent: Instance?,
		_sourceConnection: RBXScriptConnection?,
		_sessionGeneration: number,
		_active: boolean,
		_destroyed: boolean,
		_emissionDepth: number,
		_destroyEventsRequested: boolean,
		_runtimeStep: () -> (),
		_runtimeError: (message: string) -> (),
		_runtimeCost: RuntimeClass.CostReader,
		_runtimeStepAttempted: boolean,
		_hasPendingRuntimeCost: boolean,
		_pendingShapeCasts: number,
		_pendingOverlapQueries: number,
	},
	MeleeHitbox
))

local function fail(message: string, code: string?): never
	return Errors.raise("VirtualHit.melee", code or "InvalidArgument", message, 3)
end

-- xpcall's type says the values after the boolean are the callback's own, but
-- on failure the second one is the handler's. Naming the real shape here is
-- what lets the captured error be bound at all.
local guardedEmit: (() -> (), (any) -> Errors.Captured) -> (boolean, any) = xpcall :: any

-- Preserve the conventional class-table type used by typeof(setmetatable)
-- while installing runtime property getters for read-only public fields.
rawset(MeleeHitbox, "__index", function(self: MeleeHitbox, key: string): any
	if key == "Shape" then
		return self._shape
	elseif key == "Priority" then
		return self._priority
	end

	return (MeleeHitbox :: any)[key]
end)

MeleeHitbox.__newindex = function(self: MeleeHitbox, key: string, value: any)
	if key == "Shape" or key == "Priority" then
		fail(`{key} is read-only after construction`)
	end

	rawset(self :: any, key, value)
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

local function validateSource(source: MeleeSource)
	if
		typeof(source) ~= "Instance"
		or (not source:IsA("BasePart") and not source:IsA("Attachment"))
	then
		fail("options.Source must be a BasePart or Attachment")
	end

	if source:IsA("Terrain") then
		fail("options.Source cannot be Terrain")
	end
end

local function sourceCarrier(source: MeleeSource): BasePart?
	if source:IsA("BasePart") then
		return source
	end

	return source:FindFirstAncestorWhichIsA("BasePart")
end

local function sourceCFrame(source: MeleeSource): CFrame
	if source:IsA("Bone") then
		return source.TransformedWorldCFrame
	elseif source:IsA("Attachment") then
		return source.WorldCFrame
	else
		return source.CFrame
	end
end

local function configOrEmpty(config: SweepClass.SweepConfig?): SweepClass.SweepConfig
	if config == nil then
		return {}
	end

	if type(config) ~= "table" then
		fail("options.Sweep must be a table")
	end

	return config
end

local function snapshotShape(shape: Types.SweepShape): Types.SweepShape
	if type(shape) ~= "table" then
		return shape
	end

	return table.freeze(table.clone(shape)) :: any
end

local function runtimePriority(value: any): number
	if value == nil then
		return 0
	end

	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		fail("options.Priority must be a finite number")
	end

	return value
end

function MeleeHitbox.new(options: MeleeOptions, runtimeOverride: RuntimeClass.Runtime?): MeleeHitbox
	if type(options) ~= "table" then
		fail("expected an options table")
	end

	local source = options.Source
	validateSource(source)
	local shape = snapshotShape(options.Shape)
	local priority = runtimePriority(options.Priority)
	local worldRoot = resolveWorldRoot(options.WorldRoot)
	local config = configOrEmpty(options.Sweep)
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
		HitResponse = options.HitResponse,
		HitPriority = options.HitPriority,
		MaxLinearStep = config.MaxLinearStep,
		MaxAngularStep = config.MaxAngularStep,
		MaxSegments = config.MaxSegments,
		Detail = options.Detail,
		MaxHitsPerSegment = config.MaxHitsPerSegment,
	})
	local hitEvent: Signal.Emitter<Types.SweepHit> = Signal.new()
	local blockedEvent: Signal.Emitter<Types.SweepBlock> = Signal.new()
	local startedEvent: Signal.VoidEmitter = Signal.new()
	local stoppedEvent: Signal.Emitter<StopReason.StopReason> = Signal.new()
	local errorEvent: Signal.Emitter<string> = Signal.new()
	local runtime = runtimeOverride or RuntimeClass.Default
	local hitbox = (
		setmetatable({
			Source = source,
			Hit = hitEvent,
			Blocked = blockedEvent,
			Started = startedEvent,
			Stopped = stoppedEvent,
			Error = errorEvent,
			_source = source,
			_shape = shape,
			_priority = priority,
			_worldRoot = worldRoot,
			_sweep = sweep,
			_runtime = runtime,
			_hitEvent = hitEvent,
			_blockedEvent = blockedEvent,
			_startedEvent = startedEvent,
			_stoppedEvent = stoppedEvent,
			_errorEvent = errorEvent,
			_previous = nil,
			_carrier = nil,
			_sourceParent = nil,
			_sourceConnection = nil,
			_sessionGeneration = 0,
			_active = false,
			_destroyed = false,
			_emissionDepth = 0,
			_destroyEventsRequested = false,
			_runtimeStep = function() end,
			_runtimeError = function(_message: string) end,
			_runtimeCost = function()
				return nil, nil
			end,
			_runtimeStepAttempted = false,
			_hasPendingRuntimeCost = false,
			_pendingShapeCasts = 0,
			_pendingOverlapQueries = 0,
		}, MeleeHitbox) :: any
	) :: MeleeHitbox

	hitbox._runtimeStep = function()
		hitbox:_step()
	end
	hitbox._runtimeError = function(message: string)
		hitbox:_handleRuntimeError(message)
	end
	hitbox._runtimeCost = function(): (number?, number?)
		return hitbox:_consumeRuntimeCost()
	end

	return hitbox
end

function MeleeHitbox._trackingState(self: MeleeHitbox): (CFrame?, BasePart?)
	local source = self._source

	if not source:IsDescendantOf(self._worldRoot) then
		return nil, nil
	end

	local carrier = sourceCarrier(source)

	if carrier == nil or carrier:IsA("Terrain") or not carrier:IsDescendantOf(self._worldRoot) then
		return nil, nil
	end

	return sourceCFrame(source), carrier
end

function MeleeHitbox._disconnectSourceConnection(self: MeleeHitbox): ()
	if self._sourceConnection == nil then
		return
	end

	local connection = self._sourceConnection
	self._sourceConnection = nil
	connection:Disconnect()
end

local function destroyEvents(self: MeleeHitbox)
	self._destroyEventsRequested = false
	self._hitEvent:Destroy()
	self._blockedEvent:Destroy()
	self._startedEvent:Destroy()
	self._stoppedEvent:Destroy()
	self._errorEvent:Destroy()
end

local function emit(self: MeleeHitbox, callback: () -> ())
	self._emissionDepth += 1
	local success, captured = guardedEmit(callback, Errors.capture)
	self._emissionDepth -= 1

	if self._emissionDepth == 0 and self._destroyEventsRequested then
		destroyEvents(self)
	end

	if not success then
		-- Rethrown as it was thrown. A sweep inside this emission may have
		-- raised something the caller was told to branch on.
		Errors.rethrow(captured :: Errors.Captured)
	end
end

local function requestEventDestroy(self: MeleeHitbox)
	if self._emissionDepth > 0 then
		self._destroyEventsRequested = true
	else
		destroyEvents(self)
	end
end

local function deactivate(self: MeleeHitbox): boolean
	if not self._active then
		return false
	end

	self._active = false
	self:_disconnectSourceConnection()
	self._previous = nil
	self._carrier = nil
	self._sourceParent = nil
	self._runtime:Remove(self)
	return true
end

local function trackingStopReason(self: MeleeHitbox): StopReason.StopReason
	if self.Source ~= self._source then
		return StopReason.SourceRemoved
	end

	local current, carrier = self:_trackingState()

	if current ~= nil and carrier ~= nil and carrier ~= self._carrier then
		return StopReason.CarrierChanged
	end

	return StopReason.SourceRemoved
end

local function ancestryStopReason(
	self: MeleeHitbox,
	changed: Instance,
	newParent: Instance?
): StopReason.StopReason?
	if self.Source ~= self._source then
		return StopReason.SourceRemoved
	end

	local current, carrier = self:_trackingState()

	if current == nil or carrier == nil then
		return StopReason.SourceRemoved
	elseif carrier ~= self._carrier then
		return StopReason.CarrierChanged
	end

	-- Direct source reparenting is always session-breaking, even if a deferred
	-- handler observes it after the source was put back under the same carrier.
	if changed == (self._source :: Instance) then
		return StopReason.SourceRemoved
	end

	-- Preserve the same latch for an ancestor that transiently left this
	-- WorldRoot, while ignoring harmless ancestor moves within the root. A move
	-- at or above the WorldRoot cannot change membership relative to that root.
	local changedAtOrAboveRoot = changed == self._worldRoot
		or self._worldRoot:IsDescendantOf(changed)
	local eventParentInsideRoot = newParent ~= nil
		and (newParent == self._worldRoot or newParent:IsDescendantOf(self._worldRoot))

	if not changedAtOrAboveRoot and not eventParentInsideRoot then
		return StopReason.SourceRemoved
	end

	return nil
end

local function stopWithReason(self: MeleeHitbox, reason: StopReason.StopReason): boolean
	if not deactivate(self) then
		return false
	end

	emit(self, function()
		self._stoppedEvent:Fire(reason)
	end)
	return true
end

function MeleeHitbox._consumeRuntimeCost(self: MeleeHitbox): (number?, number?)
	if not self._runtimeStepAttempted then
		return nil, nil
	end

	self._runtimeStepAttempted = false

	if self._hasPendingRuntimeCost then
		self._hasPendingRuntimeCost = false
		return self._pendingShapeCasts, self._pendingOverlapQueries
	end

	return self._sweep:_getLastQueryCounts()
end

function MeleeHitbox._step(self: MeleeHitbox): ()
	if not self._active or self._destroyed then
		return
	end

	if self.Source ~= self._source or self._source.Parent ~= self._sourceParent then
		stopWithReason(self, trackingStopReason(self))
		return
	end

	local current, carrier = self:_trackingState()

	if current == nil then
		stopWithReason(self, StopReason.SourceRemoved)
		return
	elseif carrier ~= self._carrier then
		stopWithReason(self, StopReason.CarrierChanged)
		return
	end

	local previous = self._previous
	self._previous = current

	if previous == nil then
		return
	end

	local sessionGeneration = self._sessionGeneration
	self._runtimeStepAttempted = true
	local hits, blockedBy = self._sweep:Step(previous, current)
	local shapeCasts, overlapQueries = self._sweep:_getLastQueryCounts()

	if shapeCasts ~= nil and overlapQueries ~= nil then
		self._pendingShapeCasts = shapeCasts
		self._pendingOverlapQueries = overlapQueries
		self._hasPendingRuntimeCost = true
	end

	if self._destroyed or not self._active or self._sessionGeneration ~= sessionGeneration then
		if not self._destroyed and self._active then
			self._sweep:Reset()
		end

		return
	end

	local stoppedByBlock = false

	if blockedBy ~= nil then
		-- A low-level Sweep blocks only its current Step. A melee session must
		-- stop here as well or its next frame could start beyond the blocker.
		stoppedByBlock = deactivate(self)
	end

	emit(self, function()
		if stoppedByBlock then
			self._stoppedEvent:Fire(StopReason.Blocked)
		end

		for _, hit in hits do
			self._hitEvent:Fire(hit)
		end

		if blockedBy ~= nil then
			self._blockedEvent:Fire(blockedBy)
		end
	end)
end

function MeleeHitbox._handleRuntimeError(self: MeleeHitbox, message: string): ()
	if not deactivate(self) then
		return
	end

	emit(self, function()
		self._stoppedEvent:Fire(StopReason.RuntimeError)
		self._errorEvent:Fire(message)
	end)
	warn(`VirtualHit melee stopped after a runtime error:\n{message}`)
end

function MeleeHitbox.Start(self: MeleeHitbox): ()
	if self._destroyed then
		fail("cannot Start a destroyed hitbox", "Destroyed")
	end

	if self._active then
		return
	end

	if self.Source ~= self._source then
		fail("Source is read-only after construction")
	end

	local current, carrier = self:_trackingState()

	if current == nil or carrier == nil then
		fail("Source must be a descendant of options.WorldRoot when Start is called")
	end

	local validCarrier = carrier :: BasePart
	self._sweep:_setInternalExclusions({ validCarrier })
	self._sweep:Reset()
	self._previous = current
	self._carrier = validCarrier
	self._sourceParent = self._source.Parent
	self._sessionGeneration += 1
	local sessionGeneration = self._sessionGeneration
	self._active = true
	self._sourceConnection = self._source.AncestryChanged:Connect(function(changed, newParent)
		if self._active then
			local reason: StopReason.StopReason? = ancestryStopReason(self, changed, newParent)

			if reason ~= nil then
				stopWithReason(self, reason)
			end
		end
	end)
	local registered, captured = xpcall(function(): any
		self._runtime:Add(
			self,
			self._runtimeStep,
			self._runtimeError,
			self._priority,
			self._runtimeCost
		)
		return nil
	end, Errors.capture)

	if not registered then
		self._active = false
		self:_disconnectSourceConnection()
		self._previous = nil
		self._carrier = nil
		self._sourceParent = nil
		self._runtime:Remove(self)
		Errors.rethrow(captured :: Errors.Captured)
	end

	if self._active and not self._destroyed and self._sessionGeneration == sessionGeneration then
		emit(self, function()
			self._startedEvent:Fire()
		end)
	end
end

function MeleeHitbox.Stop(self: MeleeHitbox): ()
	stopWithReason(self, StopReason.Manual)
end

function MeleeHitbox.Reset(self: MeleeHitbox): ()
	if self._destroyed then
		fail("cannot Reset a destroyed hitbox", "Destroyed")
	end

	if self.Source ~= self._source then
		stopWithReason(self, StopReason.SourceRemoved)
		fail("Source is read-only after construction")
	end

	self._sweep:Reset()

	if self._active then
		self._sessionGeneration += 1

		if self._source.Parent ~= self._sourceParent then
			stopWithReason(self, trackingStopReason(self))
			return
		end

		local current, carrier = self:_trackingState()

		if current == nil then
			stopWithReason(self, StopReason.SourceRemoved)
		elseif carrier ~= self._carrier then
			stopWithReason(self, StopReason.CarrierChanged)
		else
			self._previous = current
		end
	end
end

function MeleeHitbox.WasLastStepTruncated(self: MeleeHitbox): boolean
	return self._sweep:WasLastStepTruncated()
end

function MeleeHitbox.IsActive(self: MeleeHitbox): boolean
	return self._active
end

function MeleeHitbox.IsDestroyed(self: MeleeHitbox): boolean
	return self._destroyed
end

function MeleeHitbox.GetLastSamples(self: MeleeHitbox): { CFrame }
	return self._sweep:GetLastSamples()
end

function MeleeHitbox.GetLastStats(self: MeleeHitbox): SweepClass.SweepStats?
	return self._sweep:GetLastStats()
end

function MeleeHitbox.GetLastTruncation(self: MeleeHitbox): SweepClass.SweepTruncation?
	return self._sweep:GetLastTruncation()
end

function MeleeHitbox.Destroy(self: MeleeHitbox): ()
	if self._destroyed then
		return
	end

	self._destroyed = true
	local wasActive = deactivate(self)

	if wasActive then
		emit(self, function()
			self._stoppedEvent:Fire(StopReason.Destroyed)
		end)
	end

	self._sweep:Destroy()
	requestEventDestroy(self)
end

return MeleeHitbox
