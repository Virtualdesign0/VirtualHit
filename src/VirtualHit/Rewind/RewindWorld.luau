--!strict

local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Types = require(script.Parent.Parent.Types)
local Errors = require(script.Parent.Parent.Util.Errors)
local Config = require(script.Parent.Parent.Config)

-- Live config section. Read through it so VirtualHit.configure() takes
-- effect without reloading the library.
local Tuning = Config.Rewind

-- Server-authoritative hit validation has to ask "where was this target when
-- the attacker pressed the button", not "where is it now". VirtualHit already
-- accepts any WorldRoot, so lag compensation needs no change to the query
-- layer: this module keeps a pose history, maintains a parallel WorldModel of
-- proxy parts, and re-poses those proxies to a past timestamp.

-- The proxies are ordinary queryable parts. They are deliberately NOT tagged as
-- internal exclusions, because hitting them is the entire point.

local RewindWorld = {}
RewindWorld.__index = RewindWorld

export type Disconnect = () -> ()
export type Connector = (callback: (deltaTime: number) -> ()) -> Disconnect

export type RewindOptions = {
	Duration: number?,
	Parent: Instance?,
	Name: string?,
	Clock: (() -> number)?,
	Connector: Connector?,
	-- Off, a proxy keeps the geometry it was cloned with. That is right for a
	-- world where bodies move but do not change shape, and it is what makes a
	-- capture one CFrame write per part.
	
	-- On, each capture re-reads the size, shape and query properties of every
	-- source and copies any change onto its proxy. That costs several property
	-- reads per part per capture, and it buys correctness for games that scale
	-- or morph characters -- where a proxy frozen at Track time is the wrong
	-- shape both now and in the past. Even then it is an approximation: the
	-- geometry is current, only the pose is historical.
	TrackGeometry: boolean?,
}

export type RewindInfo = {
	read Timestamp: number,
	read Resolved: number,
	read Oldest: number?,
	read Newest: number?,
	read Clamped: boolean,
	read Interpolated: boolean,
	read Samples: number,
	read Posed: number,
	read Missing: number,
}

export type RewindStats = {
	read TrackedParts: number,
	read Snapshots: number,
	read Oldest: number?,
	read Newest: number?,
	read Duration: number,
	-- Always false without TrackGeometry, because nothing is looking. With it,
	-- true once any tracked part has changed shape since it was cloned -- which
	-- is the signal that pose-only rewind is no longer describing this game.
	read GeometryTracked: boolean,
	read GeometryChanges: number,
}

type Snapshot = {
	Time: number,
	Poses: { [BasePart]: CFrame },
}

type Tracked = {
	Source: BasePart,
	Proxy: BasePart,
	Subject: Instance,
	-- A part that leaves the world stops being captured but keeps its proxy and
	-- its recorded poses until the last snapshot holding them ages out. A target
	-- that died after the shot was fired must still be hittable in the past.
	Retired: boolean,
}

type Subject = {
	Root: Instance,
	Connections: { RBXScriptConnection },
}

export type RewindWorld = typeof(setmetatable(
	{} :: {
		_duration: number,
		_trackGeometry: boolean,
		_geometryChanges: number,
		_clock: () -> number,
		_connect: Connector,
		_disconnect: Disconnect?,
		_world: WorldModel,
		_tracked: { [BasePart]: Tracked },
		_proxies: { [BasePart]: BasePart },
		_subjects: { [Instance]: Subject },
		_snapshots: { Snapshot },
		_pool: { Snapshot },
		_capturing: boolean,
		_leased: boolean,
		_destroyed: boolean,
	},
	RewindWorld
))

local function fail(message: string, code: string?): never
	return Errors.raise("VirtualHit.rewind", code or "InvalidArgument", message, 3)
end

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function defaultConnector(callback: (deltaTime: number) -> ()): Disconnect
	local connection = RunService.Heartbeat:Connect(callback)

	return function()
		connection:Disconnect()
	end
end

local function defaultParent(): Instance
	if RunService:IsServer() then
		return ServerStorage
	end

	return fail("options.Parent is required outside a server context")
end

-- A rewind timeline is compared against timestamps a client produced, so it has
-- to live in a clock both machines can name. os.clock() is CPU time since this
-- process started and means nothing on the other end of a RemoteEvent;
-- GetServerTimeNow() is the shared domain. Anything else must be supplied
-- explicitly through options.Clock, on both the recorder and the validator.
function RewindWorld.DefaultClock(): number
	return Workspace:GetServerTimeNow()
end

-- Proxies mirror collision geometry only. Children, decorations, and scripts
-- are stripped so a rewind world cannot run gameplay code or replicate.
local function createProxy(source: BasePart, parent: Instance): BasePart
	local wasArchivable = source.Archivable

	if not wasArchivable then
		source.Archivable = true
	end

	local cloned, result = pcall(function()
		return source:Clone()
	end)

	if not wasArchivable then
		source.Archivable = false
	end

	if not cloned then
		fail(`could not clone {source:GetFullName()}: {tostring(result)}`)
	end

	local proxy = result :: BasePart

	for _, child in proxy:GetChildren() do
		child:Destroy()
	end

	proxy.Name = source.Name
	proxy.Anchored = true
	proxy.CanCollide = false
	proxy.CanQuery = true
	proxy.CanTouch = false
	proxy.CastShadow = false
	proxy.Transparency = 1
	proxy.CFrame = source.CFrame
	proxy.Parent = parent

	return proxy
end

-- Copies whatever about a source part changes its shape onto its proxy.

-- A proxy is cloned once, at Track time. In a world where bodies move but do
-- not change shape that is exactly right and costs nothing. In a game that
-- scales or morphs characters it goes wrong quietly: the proxy is the shape the
-- body had when tracking started, which is neither its shape now nor its shape
-- at the rewound moment.

-- This is the cheaper half of the honest answer. The geometry becomes current
-- rather than historical -- a body that grew is replayed at its new size in an
-- old pose -- which is wrong in a way that is at least bounded and visible,
-- instead of drifting further from the truth the longer the session runs.
local function syncGeometry(entry: Tracked): boolean
	local source = entry.Source
	local proxy = entry.Proxy
	local changed = false

	if proxy.Size ~= source.Size then
		proxy.Size = source.Size
		changed = true
	end

	if proxy.CollisionGroup ~= source.CollisionGroup then
		proxy.CollisionGroup = source.CollisionGroup
		changed = true
	end

	if source:IsA("Part") and proxy:IsA("Part") and proxy.Shape ~= source.Shape then
		proxy.Shape = source.Shape
		changed = true
	end

	return changed
end

local function releaseSnapshot(self: RewindWorld, snapshot: Snapshot)
	table.clear(snapshot.Poses)
	table.insert(self._pool, snapshot)
end

local function acquireSnapshot(self: RewindWorld): Snapshot
	local pooled = table.remove(self._pool)

	if pooled ~= nil then
		return pooled
	end

	return {
		Time = 0,
		Poses = {},
	}
end

function RewindWorld.new(options: RewindOptions?): RewindWorld
	local resolved: RewindOptions = if options == nil then {} else options

	if type(resolved) ~= "table" then
		fail("expected an options table")
	end

	local duration = if resolved.Duration == nil then Tuning.Duration else resolved.Duration

	if type(duration) ~= "number" or not isFiniteNumber(duration) then
		fail("options.Duration must be a finite number")
	end

	if duration < Tuning.MinDuration or duration > Tuning.MaxDuration then
		fail(
			`options.Duration must be between {Tuning.MinDuration} and {Tuning.MaxDuration} seconds`
		)
	end

	if resolved.Clock ~= nil and type(resolved.Clock) ~= "function" then
		fail("options.Clock must be a function")
	end

	if resolved.Connector ~= nil and type(resolved.Connector) ~= "function" then
		fail("options.Connector must be a function")
	end

	local suppliedParent = resolved.Parent

	if suppliedParent ~= nil and typeof(suppliedParent) ~= "Instance" then
		fail("options.Parent must be an Instance")
	end

	local parent: Instance = suppliedParent or defaultParent()
	local world = Instance.new("WorldModel")
	world.Name = resolved.Name or "VirtualHitRewindWorld"
	world.Parent = parent

	return (
		setmetatable({
			_duration = duration,
			_trackGeometry = resolved.TrackGeometry == true,
			_clock = resolved.Clock or RewindWorld.DefaultClock,
			_connect = resolved.Connector or defaultConnector,
			_disconnect = nil,
			_world = world,
			_tracked = {},
			_proxies = {},
			_subjects = {},
			_snapshots = {},
			_pool = {},
			_capturing = false,
			_leased = false,
			_geometryChanges = 0,
			_destroyed = false,
		}, RewindWorld) :: any
	) :: RewindWorld
end

function RewindWorld.GetWorldRoot(self: RewindWorld): WorldModel
	return self._world
end

local function addPart(self: RewindWorld, part: BasePart, subject: Instance)
	if self._tracked[part] ~= nil or part:IsA("Terrain") then
		return
	end

	local proxy = createProxy(part, self._world)
	local entry: Tracked = {
		Source = part,
		Proxy = proxy,
		Subject = subject,
		Retired = false,
	}
	self._tracked[part] = entry
	self._proxies[proxy] = part
end

local function discardEntry(self: RewindWorld, part: BasePart, entry: Tracked)
	self._tracked[part] = nil
	self._proxies[entry.Proxy] = nil
	entry.Proxy:Destroy()
end

-- Retiring, not deleting. Erasing the recorded poses here would destroy exactly
-- the history lag compensation exists to replay: a target killed 100 ms after a
-- legitimate shot would become unhittable at the moment the shot was fired.
local function retirePart(self: RewindWorld, part: BasePart)
	local entry = self._tracked[part]

	if entry == nil or entry.Retired then
		return
	end

	entry.Retired = true

	-- Nothing recorded it yet, so there is no past worth keeping.
	for _, snapshot in self._snapshots do
		local recorded: CFrame? = snapshot.Poses[part]
		if recorded ~= nil then
			return
		end
	end

	discardEntry(self, part, entry)
end

-- A subject can leave the DataModel whole. A character being removed sets its
-- own Parent, not its parts', so DescendantRemoving never fires for anything
-- inside it and the entries would stay live forever: Capture skips them because
-- they are out of the world, and pruning never reaches them because nothing
-- ever marked them retired.
local function retireSubject(self: RewindWorld, subject: Instance)
	for part, entry in self._tracked do
		if entry.Subject == subject then
			retirePart(self, part)
		end
	end
end

-- The other direction, because a subject that comes back is hittable again and
-- retirement does not undo itself. Parts pruned while it was gone are tracked
-- afresh; the ones still held simply stop being retired.
local function reviveSubject(self: RewindWorld, subject: Instance)
	if subject:IsA("BasePart") then
		addPart(self, subject, subject)
	end

	for _, descendant in subject:GetDescendants() do
		if descendant:IsA("BasePart") then
			addPart(self, descendant, subject)
		end
	end

	for _, entry in self._tracked do
		if entry.Subject == subject then
			entry.Retired = false
		end
	end
end

-- Drops retired proxies once the last snapshot that mentioned them is gone.
local function pruneRetired(self: RewindWorld)
	local expired: { BasePart } = {}

	for part, entry in self._tracked do
		if entry.Retired then
			local referenced = false

			for _, snapshot in self._snapshots do
				local recorded: CFrame? = snapshot.Poses[part]
				if recorded ~= nil then
					referenced = true
					break
				end
			end

			if not referenced then
				table.insert(expired, part)
			end
		end
	end

	for _, part in expired do
		local entry = self._tracked[part]

		if entry ~= nil then
			discardEntry(self, part, entry)
		end
	end
end

-- Refuses anything that would move the world out from under an open lease.

-- Guarding RewindTo and Restore was not enough. A callback could Destroy the
-- world it was handed and WithTime would then try to restore something that no
-- longer exists; it could Clear the history the lease was posed from, or Track
-- a subject whose proxy appears mid-query at a pose nothing recorded. If the
-- API is going to be called a lease, everything that changes what the lease is
-- holding has to respect it.
local function assertMutable(self: RewindWorld)
	if self._leased then
		fail("cannot mutate the rewind world while a WithTime lease is active", "Reentrant")
	end
end

function RewindWorld.Track(self: RewindWorld, subject: Instance)
	assertMutable(self)

	if self._destroyed then
		fail("cannot Track on a destroyed rewind world", "Destroyed")
	end

	if typeof(subject) ~= "Instance" then
		fail("Track expects an Instance")
	end

	if self._subjects[subject] ~= nil then
		return
	end

	local record: Subject = {
		Root = subject,
		Connections = {},
	}
	self._subjects[subject] = record

	if subject:IsA("BasePart") then
		addPart(self, subject, subject)
	end

	for _, descendant in subject:GetDescendants() do
		if descendant:IsA("BasePart") then
			addPart(self, descendant, subject)
		end
	end

	-- A character gains and loses parts while it is alive, so the tracked set
	-- follows the subtree instead of being frozen at Track time.
	table.insert(
		record.Connections,
		subject.DescendantAdded:Connect(function(descendant)
			if descendant:IsA("BasePart") and not self._destroyed then
				addPart(self, descendant, subject)
			end
		end)
	)

	table.insert(
		record.Connections,
		subject.DescendantRemoving:Connect(function(descendant)
			if descendant:IsA("BasePart") then
				local entry = self._tracked[descendant]

				if entry ~= nil and entry.Subject == subject then
					retirePart(self, descendant)
				end
			end
		end)
	)

	-- Removing a character sets the model's own Parent, which is not a
	-- descendant change for anything inside it. Without this the whole subtree
	-- would stay tracked and unprunable after the subject left the world.
	table.insert(
		record.Connections,
		subject.AncestryChanged:Connect(function()
			if self._destroyed or self._subjects[subject] == nil then
				return
			end

			if subject:IsDescendantOf(game) then
				reviveSubject(self, subject)
			else
				retireSubject(self, subject)
			end
		end)
	)
end

function RewindWorld.Untrack(self: RewindWorld, subject: Instance)
	assertMutable(self)
	local record = self._subjects[subject]

	if record == nil then
		return
	end

	self._subjects[subject] = nil

	for _, connection in record.Connections do
		connection:Disconnect()
	end

	local removals: { BasePart } = {}

	for part, entry in self._tracked do
		if entry.Subject == subject then
			table.insert(removals, part)
		end
	end

	for _, part in removals do
		retirePart(self, part)
	end
end

function RewindWorld.IsTracking(self: RewindWorld, part: BasePart): boolean
	return self._tracked[part] ~= nil
end

-- Maps a hit on the rewind world back to the part the game actually owns.
function RewindWorld.Resolve(self: RewindWorld, proxy: BasePart): BasePart?
	return self._proxies[proxy]
end

-- The proxy standing in for a live part, or nil when it is not tracked.
function RewindWorld.GetProxy(self: RewindWorld, part: BasePart): BasePart?
	local entry = self._tracked[part]
	return if entry == nil then nil else entry.Proxy
end

-- Rewrites a list of live instances into the proxies that represent them.

-- Engine filtering does not translate on its own. A RaycastParams naming a live
-- character means nothing inside this world, because the thing that would be
-- hit is a proxy in a different hierarchy: an exclude list silently excludes
-- nothing and an include list silently includes nothing. Passing the list
-- through here first is what makes a filter mean the same thing in both worlds.

-- A Model expands to the proxies of every tracked part inside it. Untracked
-- instances are dropped, because there is nothing here to name.
function RewindWorld.TranslateInstances(self: RewindWorld, instances: { Instance }): { Instance }
	if type(instances) ~= "table" then
		fail("TranslateInstances expects an array of Instances")
	end

	local translated: { Instance } = {}
	local seen: { [Instance]: boolean } = {}

	for _, instance in instances do
		if typeof(instance) ~= "Instance" then
			fail("TranslateInstances expects an array of Instances")
		end

		for source, entry in self._tracked do
			if
				not seen[entry.Proxy]
				and (source == instance or source:IsDescendantOf(instance))
			then
				seen[entry.Proxy] = true
				table.insert(translated, entry.Proxy)
			end
		end
	end

	return translated
end

-- An EntityResolver for queries run against this world. It translates the proxy
-- back to its source part first, so the caller's own resolver never sees
-- rewind geometry.
function RewindWorld.EntityResolver(
	self: RewindWorld,
	inner: Types.EntityResolver?
): Types.EntityResolver
	-- Copied into a local so the nil check refines it. Luau does not carry a
	-- refinement across an upvalue read inside a closure.
	local wrapped = inner

	return function(instance: BasePart): Instance?
		local source: BasePart? = self._proxies[instance]

		if source == nil then
			return nil
		end

		if wrapped == nil then
			return source
		end

		return wrapped(source)
	end
end

function RewindWorld.Capture(self: RewindWorld): number
	-- A capture during a lease would append a snapshot the posed world knows
	-- nothing about, and the restore that follows would land somewhere the
	-- caller never asked for.
	assertMutable(self)

	if self._destroyed then
		fail("cannot Capture on a destroyed rewind world", "Destroyed")
	end

	if self._capturing then
		fail("Capture cannot be called recursively", "Reentrant")
	end

	-- Guarded so a failure anywhere below cannot leave the flag raised. A stuck
	-- flag would make every later Capture throw "cannot be called recursively"
	-- and silently freeze the history the whole rewind layer depends on.
	self._capturing = true
	-- Passed as an argument rather than captured. One closure per capture is one
	-- per frame per rewind world, and this runs at the recording rate.
	local completed, result = pcall(self._capture, self)
	self._capturing = false

	if not completed then
		error(result, 0)
	end

	return result :: number
end

function RewindWorld._capture(self: RewindWorld): number
	local now = self._clock()
	local snapshot = acquireSnapshot(self)
	snapshot.Time = now

	local geometryChanges = 0
	local trackGeometry = self._trackGeometry

	-- Parent, not IsDescendantOf. The full ancestry walk was the most expensive
	-- thing in the recording loop -- one per tracked part per capture, so tens of
	-- thousands a second on a busy server -- and it was answering a question the
	-- listeners already answer. A part removed from its subject fires
	-- DescendantRemoving and is retired; a subject removed whole fires
	-- AncestryChanged and its parts are retired with it. What is left for this
	-- guard is the part detaching itself, which is one property read.
	for part, entry in self._tracked do
		if not entry.Retired and part.Parent ~= nil then
			snapshot.Poses[part] = part.CFrame

			if trackGeometry and syncGeometry(entry) then
				geometryChanges += 1
			end
		end
	end

	self._geometryChanges += geometryChanges

	table.insert(self._snapshots, snapshot)

	local cutoff = now - self._duration
	local trimmed = false

	while #self._snapshots > 1 and self._snapshots[1].Time < cutoff do
		releaseSnapshot(self, table.remove(self._snapshots, 1) :: Snapshot)
		trimmed = true
	end

	if trimmed then
		pruneRetired(self)
	end

	return now
end

function RewindWorld.Start(self: RewindWorld)
	if self._destroyed then
		fail("cannot Start a destroyed rewind world", "Destroyed")
	end

	if self._disconnect ~= nil then
		return
	end

	local connected, disconnectOrMessage = pcall(function()
		return self._connect(function()
			if not self._destroyed then
				self:Capture()
			end
		end)
	end)

	if not connected then
		error(disconnectOrMessage, 0)
	end

	if type(disconnectOrMessage) ~= "function" then
		fail("connector must return a disconnect function", "NoConnector")
	end

	self._disconnect = disconnectOrMessage :: Disconnect
end

function RewindWorld.Stop(self: RewindWorld)
	local disconnect = self._disconnect

	if disconnect == nil then
		return
	end

	self._disconnect = nil
	local success, message = pcall(function(): any
		disconnect()
		return nil
	end)

	if not success then
		warn(`VirtualHit rewind disconnect failed: {tostring(message)}`)
	end
end

function RewindWorld.IsRecording(self: RewindWorld): boolean
	return self._disconnect ~= nil
end

function RewindWorld.GetStats(self: RewindWorld): RewindStats
	local count = 0

	for _ in self._tracked do
		count += 1
	end

	local snapshots = self._snapshots

	return table.freeze({
		TrackedParts = count,
		Snapshots = #snapshots,
		Oldest = if #snapshots == 0 then nil else snapshots[1].Time,
		Newest = if #snapshots == 0 then nil else snapshots[#snapshots].Time,
		Duration = self._duration,
		GeometryTracked = self._trackGeometry,
		GeometryChanges = self._geometryChanges,
	})
end

-- Finds the pair of snapshots bracketing the timestamp. Returning both lets the
-- caller interpolate, which is what keeps a rewound pose from snapping to the
-- capture rate.
local function bracket(snapshots: { Snapshot }, timestamp: number): (Snapshot?, Snapshot?, number)
	local count = #snapshots

	if count == 0 then
		return nil, nil, 0
	end

	if timestamp <= snapshots[1].Time then
		return snapshots[1], snapshots[1], 0
	end

	if timestamp >= snapshots[count].Time then
		return snapshots[count], snapshots[count], 0
	end

	local low = 1
	local high = count

	while high - low > 1 do
		local middle = (low + high) // 2

		if snapshots[middle].Time <= timestamp then
			low = middle
		else
			high = middle
		end
	end

	local earlier = snapshots[low]
	local later = snapshots[high]
	local span = later.Time - earlier.Time
	local alpha = if span <= 0 then 0 else (timestamp - earlier.Time) / span

	return earlier, later, alpha
end

-- Where a tracked part was at a moment in the past, on the same history and the
-- same interpolation the rewind world would use to pose it.

-- This exists so a validator can check the shooter against where the shooter
-- actually was when the claim says it fired, rather than against where it is
-- now. Over a 200 ms round trip a running player has moved several studs, and
-- comparing a claimed muzzle to a present-day root rejects honest shots.

-- Returns nil when the part is not tracked, or when no snapshot at or before
-- the requested time recorded it -- the same "did not exist yet" rule RewindTo
-- applies, for the same reason.
function RewindWorld.GetPoseAt(
	self: RewindWorld,
	part: BasePart,
	timestamp: number
): (CFrame?, boolean)
	if typeof(part) ~= "Instance" or not part:IsA("BasePart") then
		fail("GetPoseAt expects a BasePart")
	end

	if type(timestamp) ~= "number" or not isFiniteNumber(timestamp) then
		fail("GetPoseAt expects a finite timestamp")
	end

	if self._tracked[part] == nil then
		return nil, false
	end

	local snapshots = self._snapshots

	if #snapshots == 0 then
		return nil, true
	end

	local clamped = timestamp < snapshots[1].Time or timestamp > snapshots[#snapshots].Time
	local earlier, later, alpha = bracket(snapshots, timestamp)

	if earlier == nil then
		return nil, clamped
	end

	local earlierPose: CFrame? = earlier.Poses[part]

	if earlierPose == nil then
		return nil, clamped
	end

	local laterPose: CFrame? = if later == nil then nil else later.Poses[part]

	if laterPose == nil or alpha <= 0 then
		return earlierPose, clamped
	end

	return earlierPose:Lerp(laterPose, alpha), clamped
end

-- Poses every proxy at the requested time and returns the WorldModel to query.
-- A part with no recorded pose at that time has CanQuery cleared instead of
-- being left at a stale position: a target that was not being tracked yet must
-- not be hittable in the past.
function RewindWorld.RewindTo(self: RewindWorld, timestamp: number): (WorldModel, RewindInfo)
	if self._destroyed then
		fail("cannot RewindTo on a destroyed rewind world", "Destroyed")
	end

	if self._leased then
		-- A WithTime callback holds a root posed for one moment. Moving the
		-- proxies from inside it would hand that callback a world it never
		-- asked for, silently, which is the exact failure the lease exists to
		-- prevent. Refusing to nest is not enough if the inner call can just
		-- reach past it.
		fail("cannot RewindTo while a WithTime lease is active", "Reentrant")
	end

	if type(timestamp) ~= "number" or not isFiniteNumber(timestamp) then
		fail("RewindTo expects a finite timestamp")
	end

	local snapshots = self._snapshots
	local earlier, later, alpha = bracket(snapshots, timestamp)
	local oldest = if #snapshots == 0 then nil else snapshots[1].Time
	local newest = if #snapshots == 0 then nil else snapshots[#snapshots].Time
	local clamped = oldest == nil
		or timestamp < (oldest :: number)
		or timestamp > (newest :: number)
	local posed = 0
	local missing = 0

	for _, entry in self._tracked do
		local pose: CFrame? = nil

		if earlier ~= nil then
			local earlierPose: CFrame? = earlier.Poses[entry.Source]
			local laterPose: CFrame? = nil

			if later ~= nil then
				laterPose = later.Poses[entry.Source]
			end

			-- The earlier bracket is the authority on existence. A part that
			-- only appears in the later snapshot was created after the
			-- requested moment, and posing it at its later position would make
			-- it hittable at a time it did not exist.
			if earlierPose ~= nil and laterPose ~= nil then
				pose = if alpha <= 0 then earlierPose else earlierPose:Lerp(laterPose, alpha)
			elseif earlierPose ~= nil then
				pose = earlierPose
			end
		end

		if pose == nil then
			missing += 1
			entry.Proxy.CanQuery = false
		else
			posed += 1
			entry.Proxy.CFrame = pose :: CFrame
			entry.Proxy.CanQuery = true
		end
	end

	local resolvedTime = timestamp
	local interpolated = false

	if earlier ~= nil then
		if later == nil then
			resolvedTime = earlier.Time
		else
			resolvedTime = earlier.Time + (later.Time - earlier.Time) * alpha
			interpolated = earlier ~= later and alpha > 0
		end
	end

	local info: RewindInfo = table.freeze({
		Timestamp = timestamp,
		Resolved = resolvedTime,
		Oldest = oldest,
		Newest = newest,
		Clamped = clamped,
		Interpolated = interpolated,
		Samples = #snapshots,
		Posed = posed,
		Missing = missing,
	})

	return self._world, info
end

-- Restores every proxy to the newest recorded pose. Useful after a validation
-- pass so a later debug inspection of the rewind world shows the present.
function RewindWorld.Restore(self: RewindWorld): RewindInfo
	if self._leased then
		fail("cannot Restore while a WithTime lease is active", "Reentrant")
	end

	local snapshots = self._snapshots

	if #snapshots == 0 then
		local _, info = self:RewindTo(self._clock())
		return info
	end

	local _, info = self:RewindTo(snapshots[#snapshots].Time)
	return info
end

-- Runs a query against the world as it was, and restores it afterwards.

-- RewindTo hands out a WorldModel whose proxies are posed for one moment, and
-- there is exactly one set of them. That makes the returned root a lease
-- whether it is called one or not: a second RewindTo moves the same proxies,
-- so a caller holding the first root is now querying a different instant than
-- the one it asked for, and nothing tells it so.

-- Handing the root to a callback makes the lease the shape of the API instead
-- of a rule in the documentation. The restore runs even when the callback
-- throws, so a failed authoritative check cannot leave the world stuck in the
-- past for the next one.

-- The callback's own return values come back untouched, so this reads as an
-- expression rather than a block with a hole in it.

-- The callback must not yield. There is one set of proxies for the whole
-- world, so a callback that waits is holding every other caller's geometry in
-- the past for as long as it waits -- and the next lease to run during that
-- gap either fails as reentrant or, worse, resumes into a world that has moved
-- underneath it. This is not enforced, because catching a yield costs a
-- coroutine per lease on the hottest path the library has. Do the query, take
-- what you need out of it, and wait outside.
function RewindWorld.WithTime<T...>(
	self: RewindWorld,
	timestamp: number,
	query: (worldRoot: WorldModel, info: RewindInfo) -> T...
): T...
	if type(query) ~= "function" then
		fail("WithTime expects a function to run against the rewound world")
	end

	if self._leased then
		-- One set of proxies cannot be posed at two moments at once, and a
		-- nested call would silently move the world out from under the outer
		-- one. This is the same reason Step refuses to re-enter itself.
		fail("WithTime cannot be nested on the same rewind world", "Reentrant")
	end

	local root, info = self:RewindTo(timestamp)
	self._leased = true
	-- pcall forwards the query's own generic pack, which will not unify with
	-- table.pack's `...V`. Naming the guarded call gives that pack a shape to
	-- travel in; the same idiom as unpackPack below, for the same reason.
	local guardedCall: (typeof(query), WorldModel, RewindInfo) -> (boolean, ...any) = pcall :: any
	local captured = table.pack(guardedCall(query, root, info))
	self._leased = false

	-- Restored before the error is re-raised, so a throwing query leaves the
	-- world exactly as ready for the next caller as a returning one does.
	local restored, message = pcall(self.Restore, self)

	if not captured[1] then
		error(captured[2], 0)
	end

	if not restored then
		error(message, 0)
	end

	-- table.unpack is typed ...any, which will not unify with the query's own
	-- pack. Naming the shape says what is actually happening: the values the
	-- query returned are handed back unchanged.
	local unpackPack: (typeof(captured), number, number) -> T... = table.unpack :: any

	return unpackPack(captured, 2, captured.n)
end

function RewindWorld.Clear(self: RewindWorld)
	assertMutable(self)

	for _, snapshot in self._snapshots do
		releaseSnapshot(self, snapshot)
	end

	table.clear(self._snapshots)
	-- Retired entries were being kept alive only by the snapshots that mentioned
	-- them. With those gone there is nothing left to keep, and leaving the
	-- proxies parented would leak one part per body the world ever tracked.
	pruneRetired(self)
end

function RewindWorld.Destroy(self: RewindWorld)
	assertMutable(self)

	if self._destroyed then
		return
	end

	self._destroyed = true
	self:Stop()

	for subject in self._subjects do
		local record = self._subjects[subject]

		for _, connection in record.Connections do
			connection:Disconnect()
		end
	end

	table.clear(self._subjects)
	table.clear(self._tracked)
	table.clear(self._proxies)
	table.clear(self._snapshots)
	table.clear(self._pool)
	self._world:Destroy()
end

return RewindWorld
