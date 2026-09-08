--!strict

local Workspace = game:GetService("Workspace")

local Types = require(script.Parent.Parent.Types)
local FilterClass = require(script.Parent.Parent.Collision.Filter)
local Overlap = require(script.Parent.Parent.Collision.Overlap)
local Signal = require(script.Parent.Parent.Util.Signal)
local RuntimeClass = require(script.Parent.Parent.Melee.Runtime)
local ZoneIndexClass = require(script.Parent.ZoneIndex)
local Errors = require(script.Parent.Parent.Util.Errors)

-- An anchor is either a fixed pose or something that moves. A moving anchor is
-- re-read on every poll, so a zone can ride a vehicle, a projectile, or a bone.
export type ZoneAnchor = BasePart | Attachment | CFrame | Vector3

export type ZoneScope = "Part" | "Entity"

export type ZoneOptions = {
	Shape: Types.OverlapShape,
	Anchor: ZoneAnchor,
	Offset: CFrame?,
	Filter: FilterClass.Filter?,
	Params: OverlapParams?,
	WorldRoot: WorldRoot?,
	EntityResolver: Types.EntityResolver?,
	ZoneResolver: Types.ZoneResolver?,
	Sort: Overlap.OverlapSort?,
	-- Occupancy identity. "Entity" collapses every part of one character into a
	-- single occupant, which is what an aura or a capture point almost always
	-- wants; "Part" reports each part separately.
	Scope: ZoneScope?,
	-- Minimum seconds between polls. A zone rarely needs 60 Hz, and this is the
	-- cheapest lever there is for keeping many zones inside the query budget.
	Interval: number?,
	Priority: number?,
	Clock: (() -> number)?,
	-- Skips the engine query entirely when no tracked subject is anywhere near
	-- the zone. Everything the zone should be able to detect has to be tracked
	-- in the index, because an index makes the zone blind to anything else.
	Index: ZoneIndexClass.ZoneIndex?,
}

export type ZoneOccupant = {
	read Instance: BasePart,
	read Entity: Instance?,
	read Zone: string?,
	read Parts: { BasePart },
	read EnteredAt: number,
}

type Record = {
	Key: any,
	Instance: BasePart,
	Entity: Instance?,
	Zone: string?,
	Parts: { BasePart },
	EnteredAt: number,
}

-- One poll's occupancy, and the pool the records for it came from.

-- A poll used to allocate a map, an order array, four staging arrays and two
-- tables per occupant, all of which became garbage the moment the next poll
-- ran. At 60 Hz on a capture zone holding twenty bodies that is several
-- thousand tables a second, per zone.

-- Two of these are kept and swapped. The pools have to be separate, not one
-- shared pool, because the previous poll's records are still being read while
-- this one is being filled: recycling them a poll too early would let a record
-- answer for the wrong occupant.
type Frame = {
	Records: { [any]: Record },
	Order: { any },
	Pool: { Record },
	Leased: number,
}

local function newFrame(): Frame
	return {
		Records = {},
		Order = {},
		Pool = {},
		Leased = 0,
	}
end

local function resetFrame(frame: Frame): Frame
	table.clear(frame.Records)
	table.clear(frame.Order)
	frame.Leased = 0

	return frame
end

-- Leased and overwritten. Parts is emptied rather than replaced, so the array
-- keeps the capacity it grew to.
local function leaseRecord(frame: Frame, key: any, hit: Types.OverlapHit, enteredAt: number): Record
	local index = frame.Leased + 1
	frame.Leased = index
	local record = frame.Pool[index]

	if record == nil then
		record = {
			Key = key,
			Instance = hit.Instance,
			Entity = hit.Entity,
			Zone = hit.Zone,
			Parts = { hit.Instance },
			EnteredAt = enteredAt,
		}
		frame.Pool[index] = record

		return record
	end

	record.Key = key
	record.Instance = hit.Instance
	record.Entity = hit.Entity
	record.Zone = hit.Zone
	record.EnteredAt = enteredAt
	table.clear(record.Parts)
	table.insert(record.Parts, hit.Instance)

	return record
end

local Zone = {}
Zone.__index = Zone

export type Zone = typeof(setmetatable(
	{} :: {
		Entered: Signal.Signal<ZoneOccupant>,
		Exited: Signal.Signal<ZoneOccupant>,
		Stayed: Signal.Signal<ZoneOccupant>,
		Updated: Signal.Signal<{ ZoneOccupant }>,
		Started: Signal.VoidSignal,
		Stopped: Signal.VoidSignal,
		Error: Signal.Signal<string>,
		_shape: Types.OverlapShape,
		_anchor: ZoneAnchor,
		_offset: CFrame,
		_filter: FilterClass.Filter?,
		_params: OverlapParams?,
		_worldRoot: WorldRoot,
		_entityResolver: Types.EntityResolver?,
		_zoneResolver: Types.ZoneResolver?,
		_sort: Overlap.OverlapSort?,
		_scope: ZoneScope,
		_interval: number,
		_priority: number,
		_index: ZoneIndexClass.ZoneIndex?,
		_boundingRadius: number,
		_skippedPolls: number,
		_clock: () -> number,
		_runtime: RuntimeClass.Runtime,
		_current: Frame,
		_previous: Frame,
		_entered: { ZoneOccupant },
		_stayed: { ZoneOccupant },
		_exited: { ZoneOccupant },
		_lastPollAt: number,
		_pendingOverlapQueries: number,
		_hasPendingCost: boolean,
		_polling: boolean,
		_generation: number,
		_active: boolean,
		_destroyed: boolean,
		_enteredEvent: Signal.Emitter<ZoneOccupant>,
		_exitedEvent: Signal.Emitter<ZoneOccupant>,
		_stayedEvent: Signal.Emitter<ZoneOccupant>,
		_updatedEvent: Signal.Emitter<{ ZoneOccupant }>,
		_startedEvent: Signal.VoidEmitter,
		_stoppedEvent: Signal.VoidEmitter,
		_errorEvent: Signal.Emitter<string>,
		_runtimeStep: () -> (),
		_runtimeError: (message: string) -> (),
		_runtimeCost: RuntimeClass.CostReader,
	},
	Zone
))

local function fail(message: string, code: string?): never
	return Errors.raise("VirtualHit.zone", code or "InvalidArgument", message, 3)
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

local function validateAnchor(anchor: ZoneAnchor)
	local kind = typeof(anchor)

	if kind == "CFrame" then
		if not isFiniteCFrame(anchor :: CFrame) then
			fail("options.Anchor CFrame must be finite")
		end

		return
	elseif kind == "Vector3" then
		if not isFiniteVector3(anchor :: Vector3) then
			fail("options.Anchor Vector3 must be finite")
		end

		return
	elseif kind == "Instance" then
		local instance = anchor :: BasePart | Attachment

		if instance:IsA("Terrain") then
			fail("options.Anchor cannot be Terrain")
		end

		if instance:IsA("BasePart") or instance:IsA("Attachment") then
			return
		end
	end

	fail("options.Anchor must be a BasePart, Attachment, CFrame, or Vector3")
end

-- Returns nil when a tracked anchor has left the world, which is how a zone
-- learns its carrier was destroyed without holding a strong lifecycle contract.
local function anchorCFrame(anchor: ZoneAnchor, worldRoot: WorldRoot): CFrame?
	local kind = typeof(anchor)

	if kind == "CFrame" then
		return anchor :: CFrame
	elseif kind == "Vector3" then
		return CFrame.new(anchor :: Vector3)
	end

	local instance = anchor :: BasePart | Attachment

	if not instance:IsDescendantOf(worldRoot) then
		return nil
	end

	if instance:IsA("Bone") then
		return instance.TransformedWorldCFrame
	elseif instance:IsA("Attachment") then
		return instance.WorldCFrame
	end

	return (instance :: BasePart).CFrame
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

local function optionalNonNegative(value: any, name: string, defaultValue: number): number
	if value == nil then
		return defaultValue
	end

	if type(value) ~= "number" or not isFiniteNumber(value) or value < 0 then
		fail(`options.{name} must be a non-negative number`)
	end

	return value
end

local function finiteNumber(value: any, name: string, defaultValue: number): number
	if value == nil then
		return defaultValue
	end

	if type(value) ~= "number" or not isFiniteNumber(value) then
		fail(`options.{name} must be a finite number`)
	end

	return value
end

-- Conservative sphere around the whole shape, used only to ask the index
-- whether anything could possibly be inside. Overestimating costs a query that
-- would have happened anyway; underestimating would drop a real occupant.
local function primitiveRadius(shape: Types.PrimitiveShape): number
	if shape.Type == "Sphere" then
		return shape.Radius
	elseif shape.Type == "Block" then
		return shape.Size.Magnitude * 0.5
	end

	local part = shape.Part
	local centreOffset = (part.ExtentsCFrame.Position - part.Position).Magnitude
	return centreOffset + part.ExtentsSize.Magnitude * 0.5
end

local function boundingRadius(shape: Types.OverlapShape, offset: CFrame): number
	local base = offset.Position.Magnitude

	if shape.Type == "Compound" then
		local largest = 0

		for _, member in shape.Members do
			largest =
				math.max(largest, member.Offset.Position.Magnitude + primitiveRadius(member.Shape))
		end

		return base + largest
	end

	return base + primitiveRadius(shape :: Types.PrimitiveShape)
end

local function toOccupant(record: Record): ZoneOccupant
	return table.freeze({
		Instance = record.Instance,
		Entity = record.Entity,
		Zone = record.Zone,
		Parts = table.freeze(table.clone(record.Parts)),
		EnteredAt = record.EnteredAt,
	})
end

function Zone.new(options: ZoneOptions, runtimeOverride: RuntimeClass.Runtime?): Zone
	if type(options) ~= "table" then
		fail("expected an options table")
	end

	-- Reject a bad shape here rather than on the first poll, where the failure
	-- would surface inside the runtime heartbeat instead of at the caller.
	Overlap.validateShape(options.Shape)
	validateAnchor(options.Anchor)

	local offset = if options.Offset == nil then CFrame.identity else options.Offset

	if typeof(offset) ~= "CFrame" or not isFiniteCFrame(offset) then
		fail("options.Offset must be a finite CFrame")
	end

	if options.Filter ~= nil and options.Params ~= nil then
		fail("options.Filter and options.Params are mutually exclusive")
	end

	if options.EntityResolver ~= nil and type(options.EntityResolver) ~= "function" then
		fail("options.EntityResolver must be a function")
	end

	if options.ZoneResolver ~= nil and type(options.ZoneResolver) ~= "function" then
		fail("options.ZoneResolver must be a function")
	end

	local scope: ZoneScope = if options.Scope == nil then "Entity" else options.Scope

	if scope ~= "Part" and scope ~= "Entity" then
		fail("options.Scope must be Part or Entity")
	end

	if options.Clock ~= nil and type(options.Clock) ~= "function" then
		fail("options.Clock must be a function")
	end

	if
		options.Index ~= nil
		and (type(options.Index) ~= "table" or type((options.Index :: any).AnyWithin) ~= "function")
	then
		fail("options.Index must come from VirtualHit.zoneIndex()")
	end

	local enteredEvent: Signal.Emitter<ZoneOccupant> = Signal.new()
	local exitedEvent: Signal.Emitter<ZoneOccupant> = Signal.new()
	local stayedEvent: Signal.Emitter<ZoneOccupant> = Signal.new()
	local updatedEvent: Signal.Emitter<{ ZoneOccupant }> = Signal.new()
	local startedEvent: Signal.VoidEmitter = Signal.new()
	local stoppedEvent: Signal.VoidEmitter = Signal.new()
	local errorEvent: Signal.Emitter<string> = Signal.new()

	local zone = (
		setmetatable({
			Entered = enteredEvent,
			Exited = exitedEvent,
			Stayed = stayedEvent,
			Updated = updatedEvent,
			Started = startedEvent,
			Stopped = stoppedEvent,
			Error = errorEvent,
			_enteredEvent = enteredEvent,
			_exitedEvent = exitedEvent,
			_stayedEvent = stayedEvent,
			_updatedEvent = updatedEvent,
			_startedEvent = startedEvent,
			_stoppedEvent = stoppedEvent,
			_errorEvent = errorEvent,
			_shape = options.Shape,
			_anchor = options.Anchor,
			_offset = offset,
			_filter = options.Filter,
			_params = options.Params,
			_worldRoot = resolveWorldRoot(options.WorldRoot),
			_entityResolver = options.EntityResolver,
			_zoneResolver = options.ZoneResolver,
			_sort = options.Sort,
			_scope = scope,
			_index = options.Index,
			_boundingRadius = boundingRadius(options.Shape, offset),
			_skippedPolls = 0,
			_interval = optionalNonNegative(options.Interval, "Interval", 0),
			_priority = finiteNumber(options.Priority, "Priority", 0),
			_clock = options.Clock or os.clock,
			_runtime = runtimeOverride or RuntimeClass.Default,
			_current = newFrame(),
			_previous = newFrame(),
			_entered = {},
			_stayed = {},
			_exited = {},
			_lastPollAt = -math.huge,
			_pendingOverlapQueries = 0,
			_hasPendingCost = false,
			_polling = false,
			_generation = 0,
			_active = false,
			_destroyed = false,
		}, Zone) :: any
	) :: Zone

	zone._runtimeStep = function()
		zone:_step()
	end
	zone._runtimeError = function(message: string)
		zone:_handleRuntimeError(message)
	end
	zone._runtimeCost = function(): (number?, number?)
		return zone:_consumeRuntimeCost()
	end

	return zone
end

local function clearOccupants(self: Zone, emitExit: boolean)
	-- The frame is swapped out rather than emptied, so the records stay readable
	-- while the exits are announced.
	local departing = self._current
	self._current = resetFrame(self._previous)
	self._previous = departing

	if not emitExit then
		return
	end

	for _, key in departing.Order do
		local record = departing.Records[key]

		if record ~= nil then
			self._exitedEvent:Fire(toOccupant(record))
		end
	end
end

function Zone._consumeRuntimeCost(self: Zone): (number?, number?)
	if not self._hasPendingCost then
		return nil, nil
	end

	self._hasPendingCost = false
	local overlapQueries = self._pendingOverlapQueries
	self._pendingOverlapQueries = 0
	return 0, overlapQueries
end

function Zone._handleRuntimeError(self: Zone, message: string)
	if not self._active then
		return
	end

	self._active = false
	self._generation += 1
	self._runtime:Remove(self)
	clearOccupants(self, true)
	self._stoppedEvent:Fire()
	self._errorEvent:Fire(message)
	warn(`VirtualHit zone stopped after a runtime error:\n{message}`)
end

-- One overlap query per compound member, so the runtime cost report matches
-- what the shape actually costs.
local function overlapQueryCount(shape: Types.OverlapShape): number
	if shape.Type == "Compound" then
		return #shape.Members
	end

	return 1
end

function Zone.Poll(self: Zone): { ZoneOccupant }
	if self._destroyed then
		fail("cannot Poll a destroyed zone", "Destroyed")
	end

	if self._polling then
		fail("Poll cannot be called recursively on the same zone", "Reentrant")
	end

	-- The flag stays raised through signal emission, so a listener that calls
	-- Poll again fails loudly instead of recursing until the stack runs out.
	self._polling = true
	-- The method and its argument are passed to pcall rather than captured in a
	-- closure. A hundred zones polling every frame is a hundred closures a
	-- frame, and this one carries no state a closure would be needed for.
	local completed, resultOrMessage = pcall(Zone._poll, self)
	self._polling = false

	if not completed then
		error(resultOrMessage, 0)
	end

	return resultOrMessage :: { ZoneOccupant }
end

function Zone._poll(self: Zone): { ZoneOccupant }
	-- Stamped before anything can bail out. Leaving it unset on the way past a
	-- missing anchor would disable interval throttling and make the zone poll
	-- on every runtime step for as long as it stayed active.
	self._lastPollAt = self._clock()
	local pose = anchorCFrame(self._anchor, self._worldRoot)

	if pose == nil then
		-- The anchor left the world. Everyone inside is now outside.
		clearOccupants(self, true)
		return {}
	end

	self._generation += 1
	local generation = self._generation

	-- The broadphase question comes before the engine question. A zone with
	-- nothing near it becomes a handful of grid lookups instead of a real
	-- spatial query, which is what makes hundreds of idle zones affordable.
	local index = self._index

	if index ~= nil then
		local centre = ((pose :: CFrame) * self._offset).Position

		if not index:AnyWithin(centre, self._boundingRadius) then
			self._skippedPolls += 1
			-- Still a real poll: anyone who was inside has now left as far as
			-- this zone can tell, and that has to be reported.
			return self:_reconcile({}, generation)
		end
	end

	self._pendingOverlapQueries += overlapQueryCount(self._shape)
	self._hasPendingCost = true

	local hits: { Types.OverlapHit } = Overlap.perform({
		Origin = (pose :: CFrame) * self._offset,
		Shape = self._shape,
		Filter = self._filter,
		Params = self._params,
		WorldRoot = self._worldRoot,
		EntityResolver = self._entityResolver,
		ZoneResolver = self._zoneResolver,
		Sort = self._sort,
	})

	return self:_reconcile(hits, generation)
end

-- Turns a poll result into occupancy transitions. Shared by the real query and
-- by the broadphase skip, so a skipped poll reports departures exactly the way
-- an empty query would.
function Zone._reconcile(
	self: Zone,
	hits: { Types.OverlapHit },
	generation: number
): { ZoneOccupant }
	local now = self._clock()
	-- Swap, do not rebuild. The outgoing frame becomes previous and is still
	-- read below; the incoming one is emptied and refilled from its own pool,
	-- which is why the pools are per-frame rather than shared.
	local previous = self._current
	local current = resetFrame(self._previous)
	self._current = current
	self._previous = previous

	local previousRecords = previous.Records
	local records = current.Records
	local order = current.Order

	for _, hit in hits do
		local key: any = if self._scope == "Entity"
			then hit.Entity or hit.Instance
			else hit.Instance
		local record = records[key]

		if record == nil then
			local existing = previousRecords[key]
			record =
				leaseRecord(current, key, hit, if existing == nil then now else existing.EnteredAt)
			records[key] = record
			table.insert(order, key)
		else
			table.insert(record.Parts, hit.Instance)
		end
	end

	-- Staging only: these decide the order the signals fire in and are never
	-- handed out, so they are the zone's own arrays refilled every poll. The
	-- occupants themselves stay fresh and frozen, because those are the
	-- caller's and immutability is the point of them.
	local entered = self._entered
	local stayed = self._stayed
	local exited = self._exited
	table.clear(entered)
	table.clear(stayed)
	table.clear(exited)
	local occupants: { ZoneOccupant } = {}

	for _, key in order do
		local occupant = toOccupant(records[key])
		table.insert(occupants, occupant)

		if previousRecords[key] == nil then
			table.insert(entered, occupant)
		else
			table.insert(stayed, occupant)
		end
	end

	for key, record in previousRecords do
		if records[key] == nil then
			table.insert(exited, toOccupant(record))
		end
	end

	-- Exits are announced before entries so a listener that keys off occupancy
	-- never sees the same key in two states within one poll.
	for _, occupant in exited do
		if self._generation ~= generation then
			return occupants
		end

		self._exitedEvent:Fire(occupant)
	end

	for _, occupant in entered do
		if self._generation ~= generation then
			return occupants
		end

		self._enteredEvent:Fire(occupant)
	end

	for _, occupant in stayed do
		if self._generation ~= generation then
			return occupants
		end

		self._stayedEvent:Fire(occupant)
	end

	if self._generation == generation then
		self._updatedEvent:Fire(occupants)
	end

	return occupants
end

function Zone._step(self: Zone)
	if not self._active or self._destroyed then
		return
	end

	if self._interval > 0 and self._clock() - self._lastPollAt < self._interval then
		return
	end

	self:Poll()
end

function Zone.Start(self: Zone)
	if self._destroyed then
		fail("cannot Start a destroyed zone", "Destroyed")
	end

	if self._active then
		return
	end

	self._active = true
	self._lastPollAt = -math.huge

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

-- Stopping empties the zone. A listener applying an effect while an occupant is
-- inside must be told the effect ends, or a stopped zone would leave burning
-- targets behind forever.
function Zone.Stop(self: Zone)
	if not self._active then
		return
	end

	self._active = false
	self._generation += 1
	self._runtime:Remove(self)
	clearOccupants(self, true)
	self._stoppedEvent:Fire()
end

function Zone.GetOccupants(self: Zone): { ZoneOccupant }
	local occupants: { ZoneOccupant } = {}
	local current = self._current

	for _, key in current.Order do
		local record = current.Records[key]

		if record ~= nil then
			table.insert(occupants, toOccupant(record))
		end
	end

	return occupants
end

function Zone.GetOccupantCount(self: Zone): number
	return #self._current.Order
end

-- How many polls the broadphase index answered without touching the engine.
function Zone.GetSkippedPollCount(self: Zone): number
	return self._skippedPolls
end

function Zone.Contains(self: Zone, subject: Instance): boolean
	local current = self._current

	if current.Records[subject] ~= nil then
		return true
	end

	for _, key in current.Order do
		local record = current.Records[key]

		if record ~= nil then
			for _, part in record.Parts do
				if part == subject then
					return true
				end
			end
		end
	end

	return false
end

function Zone.IsActive(self: Zone): boolean
	return self._active
end

function Zone.IsDestroyed(self: Zone): boolean
	return self._destroyed
end

function Zone.Destroy(self: Zone)
	if self._destroyed then
		return
	end

	self._destroyed = true
	local wasActive = self._active
	self._active = false
	self._generation += 1
	self._runtime:Remove(self)
	clearOccupants(self, wasActive)

	if wasActive then
		self._stoppedEvent:Fire()
	end

	self._enteredEvent:Destroy()
	self._exitedEvent:Destroy()
	self._stayedEvent:Destroy()
	self._updatedEvent:Destroy()
	self._startedEvent:Destroy()
	self._stoppedEvent:Destroy()
	self._errorEvent:Destroy()

	-- The record pools outlive a poll by design; they must not outlive the zone,
	-- or a destroyed capture volume keeps holding every part it last saw.
	resetFrame(self._current)
	resetFrame(self._previous)
	table.clear(self._current.Pool)
	table.clear(self._previous.Pool)
	table.clear(self._entered)
	table.clear(self._stayed)
	table.clear(self._exited)
end

return Zone
