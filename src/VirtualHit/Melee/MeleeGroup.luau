--!strict

local Types = require(script.Parent.Parent.Types)
local FilterClass = require(script.Parent.Parent.Collision.Filter)
local Ordering = require(script.Parent.Parent.Collision.Ordering)
local HitPolicy = require(script.Parent.Parent.Sweep.HitPolicy)
local HitRegistryClass = require(script.Parent.Parent.Sweep.HitRegistry)
local SweepClass = require(script.Parent.Parent.Sweep.Sweep)
local Signal = require(script.Parent.Parent.Util.Signal)
local MeleeHitbox = require(script.Parent.MeleeHitbox)
local RuntimeClass = require(script.Parent.Runtime)
local StopReason = require(script.Parent.StopReason)
local Errors = require(script.Parent.Parent.Util.Errors)

-- Every field a member may inherit from the group. A member that sets one of
-- these overrides the group value; a member that omits it inherits.
export type MeleeGroupMember = {
	Source: MeleeHitbox.MeleeSource,
	Shape: Types.SweepShape,
	Offset: CFrame?,
	Filter: FilterClass.Filter?,
	RaycastParams: RaycastParams?,
	OverlapParams: OverlapParams?,
	WorldRoot: WorldRoot?,
	EntityResolver: Types.EntityResolver?,
	ZoneResolver: Types.ZoneResolver?,
	HitResponse: SweepClass.HitResponder?,
	HitPriority: SweepClass.HitPriority?,
	ProbeFree: boolean?,
	Priority: number?,
	Sweep: SweepClass.SweepConfig?,
	Name: string?,
}

export type MeleeGroupOptions = {
	Members: { MeleeGroupMember },
	-- The policy is a property of the group, never of a member: the whole point
	-- of a group is that its members cannot each land their own hit.
	HitPolicy: HitPolicy.Policy?,
	HitKey: SweepClass.HitKey?,
	Registry: SweepClass.HitRegistry?,
	Offset: CFrame?,
	Filter: FilterClass.Filter?,
	RaycastParams: RaycastParams?,
	OverlapParams: OverlapParams?,
	WorldRoot: WorldRoot?,
	EntityResolver: Types.EntityResolver?,
	ZoneResolver: Types.ZoneResolver?,
	HitResponse: SweepClass.HitResponder?,
	HitPriority: SweepClass.HitPriority?,
	ProbeFree: boolean?,
	Priority: number?,
	Sweep: SweepClass.SweepConfig?,
	-- A blocker stops the member that met it. StopOnBlock extends that to the
	-- rest of the group, which is what a physical weapon does when its swing
	-- is arrested by a wall.
	StopOnBlock: boolean?,
	-- Drives every member from one runtime slot and emits their events in
	-- global Alpha order at the end of the tick, so a group orders its hits the
	-- way a single compound sweep would. Turning it off registers each member
	-- with the runtime separately: per-member priority and per-member deferral,
	-- but events arrive grouped by member instead of by time.
	OrderHitsPerFrame: boolean?,
}

export type MeleeGroupHit = {
	Hit: Types.SweepHit,
	Hitbox: MeleeHitbox.MeleeHitbox,
	Member: number,
	Name: string?,
}

export type MeleeGroupBlock = {
	Block: Types.SweepBlock,
	Hitbox: MeleeHitbox.MeleeHitbox,
	Member: number,
	Name: string?,
}

type Entry = {
	Index: number,
	Name: string?,
	Hitbox: MeleeHitbox.MeleeHitbox,
	-- The private rule clone an ordered group hands its member. The member does
	-- not own it, so the group has to re-arm it itself.
	Registry: HitRegistryClass.HitRegistry,
	Connections: { Signal.Connection },
}

type Buffered = {
	Entry: Entry,
	Sequence: number,
	Alpha: number,
	IsContact: boolean,
	Hit: Types.SweepHit?,
	Block: Types.SweepBlock?,
	-- Filled by the key pass in flush, read by the emission pass.
	Key: any,
}

local MeleeGroup = {}
MeleeGroup.__index = MeleeGroup

export type MeleeGroup = typeof(setmetatable(
	{} :: {
		Hit: Signal.Signal<MeleeGroupHit>,
		Blocked: Signal.Signal<MeleeGroupBlock>,
		Started: Signal.VoidSignal,
		Stopped: Signal.Signal<StopReason.StopReason>,
		Error: Signal.Signal<string>,
		_entries: { Entry },
		_registry: HitRegistryClass.HitRegistry,
		_ownsRegistry: boolean,
		_stopOnBlock: boolean,
		_ordered: boolean,
		_priority: number,
		_runtime: RuntimeClass.Runtime,
		_innerRuntime: RuntimeClass.Runtime?,
		_tickHolder: { Tick: ((deltaTime: number) -> ())? },
		_buffer: { Buffered },
		_sequence: number,
		_buffering: boolean,
		_pendingStop: StopReason.StopReason?,
		_pendingShapeCasts: number,
		_pendingOverlapQueries: number,
		_hasPendingCost: boolean,
		_hitEvent: Signal.Emitter<MeleeGroupHit>,
		_blockedEvent: Signal.Emitter<MeleeGroupBlock>,
		_startedEvent: Signal.VoidEmitter,
		_stoppedEvent: Signal.Emitter<StopReason.StopReason>,
		_errorEvent: Signal.Emitter<string>,
		_runtimeStep: (deltaTime: number) -> (),
		_runtimeError: (message: string) -> (),
		_runtimeCost: RuntimeClass.CostReader,
		_active: boolean,
		_stopping: boolean,
		_destroyed: boolean,
	},
	MeleeGroup
))

local function fail(message: string, code: string?): never
	return Errors.raise("VirtualHit.meleeGroup", code or "InvalidArgument", message, 3)
end

local RESERVED_MEMBER_FIELDS = { "HitPolicy", "HitKey", "Registry" }

local function pick<T>(memberValue: T?, groupValue: T?): T?
	if memberValue ~= nil then
		return memberValue
	end

	return groupValue
end

local function buildMemberOptions(
	member: MeleeGroupMember,
	options: MeleeGroupOptions,
	registry: HitRegistryClass.HitRegistry
): MeleeHitbox.MeleeOptions
	return {
		Source = member.Source,
		Shape = member.Shape,
		Offset = pick(member.Offset, options.Offset),
		Filter = pick(member.Filter, options.Filter),
		RaycastParams = pick(member.RaycastParams, options.RaycastParams),
		OverlapParams = pick(member.OverlapParams, options.OverlapParams),
		WorldRoot = pick(member.WorldRoot, options.WorldRoot),
		EntityResolver = pick(member.EntityResolver, options.EntityResolver),
		ZoneResolver = pick(member.ZoneResolver, options.ZoneResolver),
		HitResponse = pick(member.HitResponse, options.HitResponse),
		HitPriority = pick(member.HitPriority, options.HitPriority),
		ProbeFree = pick(member.ProbeFree, options.ProbeFree),
		Priority = pick(member.Priority, options.Priority),
		Sweep = pick(member.Sweep, options.Sweep),
		Registry = registry,
	}
end

-- Alpha is the fraction of this tick's motion at which the contact happened,
-- and every member is stepped over the same interval, so it is directly
-- comparable across members. Everything after it is a deterministic tie-break.
local function bufferedOrder(left: Buffered, right: Buffered): boolean
	local comparison = Ordering.number(left.Alpha, right.Alpha)

	if comparison ~= nil then
		return comparison
	end

	if left.IsContact ~= right.IsContact then
		-- A native contact carries a truthful surface point, so it outranks an
		-- endpoint overlap at the same instant.
		return left.IsContact
	end

	if left.Entry.Index ~= right.Entry.Index then
		return left.Entry.Index < right.Entry.Index
	end

	return left.Sequence < right.Sequence
end

local function anyActive(self: MeleeGroup): boolean
	for _, entry in self._entries do
		if entry.Hitbox:IsActive() then
			return true
		end
	end

	return false
end

-- One transition, one signal. Members stop individually as their sources move
-- or their sweeps block; the group reports only its own active-to-inactive edge.
local function finish(self: MeleeGroup, reason: StopReason.StopReason)
	if not self._active or self._stopping then
		return
	end

	self._stopping = true

	for _, entry in self._entries do
		if entry.Hitbox:IsActive() then
			entry.Hitbox:Stop()
		end
	end

	self._stopping = false
	self._active = false
	self._pendingStop = nil

	if self._ordered then
		-- An ordered group holds a runtime slot of its own while it runs, and
		-- stopping has to hand it back. A stopped group left registered is
		-- ticked for the rest of the session, pumping members that stopped
		-- with it -- and it holds the runtime open against everything else
		-- that would let it disconnect.
		self._runtime:Remove(self)
	end

	self._stoppedEvent:Fire(reason)
end

local function flush(self: MeleeGroup)
	local buffer = self._buffer

	if #buffer > 1 then
		table.sort(buffer, bufferedOrder)
	end

	local blocked = false

	-- Every key before the first acceptance, for the same reason the sweep does
	-- it: HitKey is caller code, and a failure part way through this loop would
	-- otherwise leave earlier hits consumed and their signals already fired
	-- while the frame reported failure.
	for _, item in buffer do
		local hit = item.Hit

		if hit ~= nil then
			item.Key = self._registry:KeyFor(hit.Instance, hit.Entity, hit)
		end
	end

	for _, item in buffer do
		local hit = item.Hit

		if hit ~= nil then
			-- Acceptance happens here, not inside the member sweeps. Each member
			-- carries a private clone of the rule so it dedups within itself;
			-- the authoritative registry is consulted only once the whole frame
			-- is in physical order. Otherwise the member that merely stepped
			-- first would consume a OncePerEntity slot that belongs to the
			-- member which actually reached the target earlier.
			if self._registry:AcceptKey(item.Key) then
				self._hitEvent:Fire({
					Hit = hit,
					Hitbox = item.Entry.Hitbox,
					Member = item.Entry.Index,
					Name = item.Entry.Name,
				})
			end
		else
			local block = item.Block :: Types.SweepBlock
			blocked = true
			self._blockedEvent:Fire({
				Block = block,
				Hitbox = item.Entry.Hitbox,
				Member = item.Entry.Index,
				Name = item.Entry.Name,
			})
		end
	end

	table.clear(buffer)

	-- Stopping is applied after the whole frame has been reported. No contact a
	-- member already resolved is dropped just because another member was
	-- blocked earlier in the same tick.
	if blocked and self._stopOnBlock then
		finish(self, StopReason.Blocked)
		return
	end

	local pending: StopReason.StopReason? = self._pendingStop
	self._pendingStop = nil

	if pending ~= nil and self._active and not anyActive(self) then
		self._active = false
		self._stoppedEvent:Fire(pending)
	end
end

function MeleeGroup._consumeRuntimeCost(self: MeleeGroup): (number?, number?)
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

-- The tick and its delta are passed to pcall rather than captured in a closure.
-- One group stepping every frame is one closure a frame, and this call carries
-- no state a closure would be needed for. pcall's type says the values after
-- the boolean are the callee's own and this callee returns none, so the shape
-- is named here to bind the error.
local guardedTick: ((number) -> (), number) -> (boolean, any) = pcall :: any

function MeleeGroup._step(self: MeleeGroup, deltaTime: number)
	local tick = self._tickHolder.Tick
	local inner = self._innerRuntime

	if tick == nil or inner == nil then
		return
	end

	table.clear(self._buffer)
	self._sequence = 0
	self._buffering = true
	local completed, message = guardedTick(tick, deltaTime)
	self._buffering = false

	local stats = inner:GetLastStats()

	if stats ~= nil then
		self._pendingShapeCasts += stats.ShapeCasts
		self._pendingOverlapQueries += stats.OverlapQueries
		self._hasPendingCost = true
	end

	if not completed then
		table.clear(self._buffer)
		error(message, 0)
	end

	flush(self)
end

function MeleeGroup._handleRuntimeError(self: MeleeGroup, message: string)
	if self._active then
		self._stopping = true

		for _, entry in self._entries do
			if entry.Hitbox:IsActive() then
				entry.Hitbox:Stop()
			end
		end

		self._stopping = false
		self._active = false
		self._stoppedEvent:Fire(StopReason.RuntimeError)
	end

	self._errorEvent:Fire(message)
	warn(`VirtualHit melee group stopped after a runtime error:\n{message}`)
end

function MeleeGroup.new(
	options: MeleeGroupOptions,
	runtimeOverride: RuntimeClass.Runtime?
): MeleeGroup
	if type(options) ~= "table" then
		fail("expected an options table")
	end

	local members = options.Members

	if type(members) ~= "table" or #members == 0 then
		fail("options.Members must contain at least one member")
	end

	for index, member in members do
		if type(member) ~= "table" then
			fail(`options.Members[{index}] must be a table`)
		end

		for _, field in RESERVED_MEMBER_FIELDS do
			if (member :: any)[field] ~= nil then
				fail(
					`options.Members[{index}].{field} is not allowed; the group owns hit acceptance`
				)
			end
		end

		if member.Name ~= nil and type(member.Name) ~= "string" then
			fail(`options.Members[{index}].Name must be a string`)
		end
	end

	if options.StopOnBlock ~= nil and type(options.StopOnBlock) ~= "boolean" then
		fail("options.StopOnBlock must be a boolean")
	end

	if options.OrderHitsPerFrame ~= nil and type(options.OrderHitsPerFrame) ~= "boolean" then
		fail("options.OrderHitsPerFrame must be a boolean")
	end

	local priority = options.Priority

	if
		priority ~= nil
		and (type(priority) ~= "number" or priority ~= priority or math.abs(priority) == math.huge)
	then
		fail("options.Priority must be a finite number")
	end

	local registry: HitRegistryClass.HitRegistry
	local ownsRegistry: boolean
	local sharedRegistry = options.Registry

	if sharedRegistry ~= nil then
		if
			type(sharedRegistry) ~= "table"
			or type((sharedRegistry :: any).Accept) ~= "function"
		then
			fail("options.Registry must come from VirtualHit.HitRegistry.new()")
		end

		if options.HitPolicy ~= nil or options.HitKey ~= nil then
			fail(
				"options.Registry cannot be combined with options.HitPolicy or options.HitKey",
				"RegistryConflict"
			)
		end

		registry = sharedRegistry
		ownsRegistry = false
	else
		local policy: HitPolicy.Policy = if options.HitPolicy == nil
			then "OncePerEntity"
			else options.HitPolicy
		registry = HitRegistryClass.new(policy, nil, options.HitKey)
		ownsRegistry = true
	end

	local ordered = options.OrderHitsPerFrame ~= false
	local outerRuntime = runtimeOverride or RuntimeClass.Default
	local tickHolder: { Tick: ((deltaTime: number) -> ())? } = { Tick = nil }
	local innerRuntime: RuntimeClass.Runtime? = nil

	if ordered then
		-- The inner runtime never connects to anything. The group owns one slot
		-- in the real runtime and pumps its members from there, so the whole
		-- group is scheduled, budgeted and deferred as a single unit.
		innerRuntime = RuntimeClass.new(function(callback)
			tickHolder.Tick = callback

			return function()
				tickHolder.Tick = nil
			end
		end)
	end

	local hitEvent: Signal.Emitter<MeleeGroupHit> = Signal.new()
	local blockedEvent: Signal.Emitter<MeleeGroupBlock> = Signal.new()
	local startedEvent: Signal.VoidEmitter = Signal.new()
	local stoppedEvent: Signal.Emitter<StopReason.StopReason> = Signal.new()
	local errorEvent: Signal.Emitter<string> = Signal.new()

	local group = (
		setmetatable({
			Hit = hitEvent,
			Blocked = blockedEvent,
			Started = startedEvent,
			Stopped = stoppedEvent,
			Error = errorEvent,
			_entries = {},
			_registry = registry,
			_ownsRegistry = ownsRegistry,
			_stopOnBlock = options.StopOnBlock ~= false,
			_ordered = ordered,
			_priority = priority or 0,
			_runtime = outerRuntime,
			_innerRuntime = innerRuntime,
			_tickHolder = tickHolder,
			_buffer = {},
			_sequence = 0,
			_buffering = false,
			_pendingStop = nil,
			_pendingShapeCasts = 0,
			_pendingOverlapQueries = 0,
			_hasPendingCost = false,
			_hitEvent = hitEvent,
			_blockedEvent = blockedEvent,
			_startedEvent = startedEvent,
			_stoppedEvent = stoppedEvent,
			_errorEvent = errorEvent,
			_active = false,
			_stopping = false,
			_destroyed = false,
		}, MeleeGroup) :: any
	) :: MeleeGroup

	group._runtimeStep = function(deltaTime: number)
		group:_step(deltaTime)
	end
	group._runtimeError = function(message: string)
		group:_handleRuntimeError(message)
	end
	group._runtimeCost = function()
		return group:_consumeRuntimeCost()
	end

	local memberRuntime = if ordered then innerRuntime else outerRuntime
	local entries: { Entry } = {}

	for index, member in members do
		-- Ordered groups decide acceptance themselves, after sorting the frame,
		-- so members get a private clone of the rule instead of the shared
		-- registry. Unordered groups have no cross-member ordering to protect
		-- and share the registry directly, as before.
		local memberRegistry = if ordered then registry:Clone() else registry
		local created, hitboxOrMessage = pcall(
			MeleeHitbox.new,
			buildMemberOptions(member, options, memberRegistry),
			memberRuntime
		)

		if not created then
			-- Partially built groups own probes, signals and an inner runtime
			-- that nothing else would ever release, so unwind all of it.
			for _, entry in entries do
				entry.Hitbox:Destroy()
			end

			if innerRuntime ~= nil then
				innerRuntime:Destroy()
			end

			error(hitboxOrMessage, 0)
		end

		-- Annotated rather than inferred: an inferred literal types Connections
		-- as the empty table, and the entry has to hold the connections made when
		-- the group starts.
		local entry: Entry = {
			Index = index,
			Name = member.Name,
			Hitbox = hitboxOrMessage :: MeleeHitbox.MeleeHitbox,
			Registry = memberRegistry,
			Connections = {},
		}

		table.insert(entries, entry)
	end

	group._entries = entries

	for _, entry in entries do
		local hitbox = entry.Hitbox

		table.insert(
			entry.Connections,
			hitbox.Hit:Connect(function(hit: Types.SweepHit)
				if group._buffering then
					group._sequence += 1
					table.insert(group._buffer, {
						Entry = entry,
						Sequence = group._sequence,
						Alpha = hit.Alpha,
						IsContact = hit.Kind == "Sweep",
						Hit = hit,
						Block = nil,
						Key = nil,
					})
					return
				end

				group._hitEvent:Fire({
					Hit = hit,
					Hitbox = hitbox,
					Member = entry.Index,
					Name = entry.Name,
				})
			end)
		)

		table.insert(
			entry.Connections,
			hitbox.Blocked:Connect(function(block: Types.SweepBlock)
				if group._buffering then
					group._sequence += 1
					table.insert(group._buffer, {
						Entry = entry,
						Sequence = group._sequence,
						Alpha = block.Alpha,
						IsContact = block.Kind == "Sweep",
						Hit = nil,
						Block = block,
						Key = nil,
					})
					return
				end

				group._blockedEvent:Fire({
					Block = block,
					Hitbox = hitbox,
					Member = entry.Index,
					Name = entry.Name,
				})

				if group._stopOnBlock then
					finish(group, StopReason.Blocked)
				end
			end)
		)

		table.insert(
			entry.Connections,
			hitbox.Error:Connect(function(message: string)
				group._errorEvent:Fire(message)
			end)
		)

		table.insert(
			entry.Connections,
			hitbox.Stopped:Connect(function(reason: StopReason.StopReason)
				if group._stopping or not group._active then
					return
				end

				if group._buffering then
					-- Applied after the tick has been reported, so a member that
					-- stops mid-tick cannot swallow the events of members that
					-- had already stepped.
					group._pendingStop = reason
					return
				end

				-- A member can stop on its own when its source is removed or
				-- reparented. The group survives until no member is left.
				if not anyActive(group) then
					group._active = false
					group._stoppedEvent:Fire(reason)
				end
			end)
		)
	end

	return group
end

function MeleeGroup.Start(self: MeleeGroup)
	if self._destroyed then
		fail("cannot Start a destroyed group", "Destroyed")
	end

	if self._active then
		return
	end

	local started: { MeleeHitbox.MeleeHitbox } = {}

	for _, entry in self._entries do
		local success, message = pcall(function(): any
			entry.Hitbox:Start()
			return nil
		end)

		if not success then
			-- All-or-nothing: a group that started only some of its members
			-- would apply a shared policy to a partial hitbox.
			self._stopping = true

			for _, hitbox in started do
				hitbox:Stop()
			end

			self._stopping = false
			error(message, 0)
		end

		table.insert(started, entry.Hitbox)
	end

	if self._ownsRegistry then
		self._registry:Reset()
	end

	-- Member clones are owned by the group, not by the member sweeps, so
	-- Hitbox:Start cannot re-arm them.
	for _, entry in self._entries do
		if entry.Registry ~= self._registry then
			entry.Registry:Reset()
		end
	end

	if self._ordered then
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
			self._stopping = true

			for _, hitbox in started do
				hitbox:Stop()
			end

			self._stopping = false
			self._runtime:Remove(self)
			error(message, 0)
		end
	end

	self._active = true
	self._startedEvent:Fire()
end

function MeleeGroup.Stop(self: MeleeGroup)
	finish(self, StopReason.Manual)
end

function MeleeGroup.Reset(self: MeleeGroup)
	if self._destroyed then
		fail("cannot Reset a destroyed group", "Destroyed")
	end

	if self._ownsRegistry then
		self._registry:Reset()
	end

	for _, entry in self._entries do
		if entry.Registry ~= self._registry then
			entry.Registry:Reset()
		end

		entry.Hitbox:Reset()
	end
end

function MeleeGroup.IsActive(self: MeleeGroup): boolean
	return self._active
end

function MeleeGroup.IsDestroyed(self: MeleeGroup): boolean
	return self._destroyed
end

function MeleeGroup.IsOrdered(self: MeleeGroup): boolean
	return self._ordered
end

function MeleeGroup.GetRegistry(self: MeleeGroup): HitRegistryClass.HitRegistry
	return self._registry
end

function MeleeGroup.GetMemberCount(self: MeleeGroup): number
	return #self._entries
end

function MeleeGroup.GetMember(self: MeleeGroup, index: number): MeleeHitbox.MeleeHitbox?
	local entry = self._entries[index]
	return if entry == nil then nil else entry.Hitbox
end

function MeleeGroup.GetMembers(self: MeleeGroup): { MeleeHitbox.MeleeHitbox }
	local hitboxes: { MeleeHitbox.MeleeHitbox } = {}

	for _, entry in self._entries do
		table.insert(hitboxes, entry.Hitbox)
	end

	return hitboxes
end

function MeleeGroup.WasLastStepTruncated(self: MeleeGroup): boolean
	for _, entry in self._entries do
		if entry.Hitbox:WasLastStepTruncated() then
			return true
		end
	end

	return false
end

function MeleeGroup.Destroy(self: MeleeGroup)
	if self._destroyed then
		return
	end

	self._destroyed = true
	local wasActive = self._active
	self._stopping = true

	for _, entry in self._entries do
		for _, connection in entry.Connections do
			connection:Disconnect()
		end

		table.clear(entry.Connections)
		entry.Hitbox:Destroy()
	end

	self._stopping = false
	self._active = false
	self._runtime:Remove(self)
	table.clear(self._buffer)

	local inner = self._innerRuntime

	if inner ~= nil then
		self._innerRuntime = nil
		inner:Destroy()
	end

	if wasActive then
		self._stoppedEvent:Fire(StopReason.Destroyed)
	end

	self._hitEvent:Destroy()
	self._blockedEvent:Destroy()
	self._startedEvent:Destroy()
	self._stoppedEvent:Destroy()
	self._errorEvent:Destroy()
end

return MeleeGroup
