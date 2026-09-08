--!strict

-- A negative filter for zone polls.

-- Most zones in a real game are empty most of the time, and an empty poll still
-- costs a real GetPartsInPart against the engine broadphase. This index keeps a
-- coarse uniform grid of the subjects a game actually cares about, so a zone can
-- ask one cheap question first: could anything be in range at all. When the
-- answer is no, the engine query is skipped entirely.

-- The index is only ever used to skip work, never to produce results. That
-- means it has exactly one correctness requirement, and it is on the caller:
-- whatever a zone is supposed to detect must be tracked here. A zone with an
-- index will not find an untracked subject.

local RunService = game:GetService("RunService")

local Errors = require(script.Parent.Parent.Util.Errors)
local Config = require(script.Parent.Parent.Config)

-- Live config section. Read through it so VirtualHit.configure() takes
-- effect without reloading the library.
local Tuning = Config.Zone

local ZoneIndex = {}
ZoneIndex.__index = ZoneIndex

-- Below this many buckets a compaction is not worth the walk; above it, an
-- index whose live cells have halved is carrying more dead ones than live.
local MIN_COMPACT_BUCKETS = 32

export type Disconnect = () -> ()
export type Connector = (callback: () -> ()) -> Disconnect

type Entry = {
	Subject: Instance,
	Position: Vector3,
	Radius: number,
}

-- The grid was a flat map keyed by a "x:y:z" string. Every refresh built one of
-- those strings per subject and a fresh array per occupied cell, and every
-- query built another string per cell it walked -- which the radius widening
-- made considerably worse, because a wide subject makes every query walk more
-- cells. None of that describes anything: a cell is three integers.

-- So the map is nested and numeric, and the arrays are kept and refilled rather
-- than dropped and rebuilt. A bucket remembers where it lives so an empty one
-- can be unlinked when they accumulate.
type Bucket = {
	X: number,
	Y: number,
	Z: number,
	Entries: { Entry },
}

type Row = { [number]: Bucket }
type Plane = { [number]: Row }
type Grid = { [number]: Plane }

export type ZoneIndexOptions = {
	-- Grid cell edge in studs. Roughly the radius of a typical zone is a good
	-- starting point: too small and a query walks many cells, too large and
	-- every cell answers yes.
	CellSize: number?,
	-- Extra radius given to every subject, on top of the distance its own
	-- velocity could carry it before the next refresh.
	Padding: number?,
	-- Seconds of movement the velocity term covers. Raise it for subjects that
	-- teleport or move much faster than the refresh rate.
	Lookahead: number?,
	-- Drives the automatic per-frame refresh. Defaults to Heartbeat; tests
	-- supply their own.
	Connector: Connector?,
}

export type ZoneIndexStats = {
	read Subjects: number,
	read Cells: number,
	read Refreshes: number,
	read Queries: number,
	read Skipped: number,
}

export type ZoneIndex = typeof(setmetatable(
	{} :: {
		_cellSize: number,
		_padding: number,
		_lookahead: number,
		_connect: Connector,
		_disconnect: Disconnect?,
		_destroyed: boolean,
		_entries: { [Instance]: Entry },
		_cells: Grid,
		_buckets: { Bucket },
		_stale: { Instance },
		_sweepIn: number,
		_maxRadius: number,
		_dirty: boolean,
		_refreshes: number,
		_queries: number,
		_skipped: number,
	},
	ZoneIndex
))

local function fail(message: string, code: string?): never
	return Errors.raise("VirtualHit.zoneIndex", code or "InvalidArgument", message, 3)
end

local function defaultConnector(callback: () -> ()): Disconnect
	-- Heartbeat hands its listener a delta time and a Connector's callback
	-- takes nothing, so the two signatures do not meet: the wrapper drops the
	-- argument rather than widening the Connector contract for one caller.
	local connection = RunService.Heartbeat:Connect(function()
		callback()
	end)

	return function()
		connection:Disconnect()
	end
end

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function positiveNumber(value: any, name: string, defaultValue: number): number
	if value == nil then
		return defaultValue
	end

	if type(value) ~= "number" or not isFiniteNumber(value) or value <= 0 then
		fail(`options.{name} must be a finite number greater than zero`)
	end

	return value
end

-- Padding and Lookahead are slack, not sizes: zero of either is a caller
-- saying "no slack", and Config declares both with a floor of zero. They went
-- through positiveNumber, which rejected the very value the schema allows.
local function nonNegativeNumber(value: any, name: string, defaultValue: number): number
	if value == nil then
		return defaultValue
	end

	if type(value) ~= "number" or not isFiniteNumber(value) or value < 0 then
		fail(`options.{name} must be a finite number of zero or more`)
	end

	return value
end

-- A subject is one point and one radius, and the sphere has to contain the
-- whole subject. A Model is measured from the centre of its bounding box, not
-- its pivot: a pivot sitting outside the box would leave part of the model
-- outside a sphere drawn around it, and this index is only allowed to be wrong
-- in the direction that costs a query.
local function measure(subject: Instance): (Vector3?, number, Vector3)
	if subject:IsA("BasePart") then
		return subject.Position, subject.Size.Magnitude * 0.5, subject.AssemblyLinearVelocity
	end

	if subject:IsA("Model") then
		local success, bounds: CFrame?, size: Vector3? = pcall(function()
			local boundsCFrame, extents = subject:GetBoundingBox()
			return boundsCFrame, extents
		end)

		if success and bounds ~= nil then
			local velocity = Vector3.zero
			local primary = subject.PrimaryPart

			if primary ~= nil then
				velocity = primary.AssemblyLinearVelocity
			end

			return (bounds :: CFrame).Position,
				((size :: Vector3) or Vector3.zero).Magnitude * 0.5,
				velocity
		end

		return nil, 0, Vector3.zero
	end

	-- A Tool or a Folder is a bag of parts with no bounding box of its own.
	-- Measuring only the first one found would describe a subject smaller than
	-- it is, and this index is only allowed to be wrong in the direction that
	-- costs a query.
	local minimum: Vector3? = nil
	local maximum: Vector3? = nil
	local velocity = Vector3.zero

	for _, descendant in subject:GetDescendants() do
		if not descendant:IsA("BasePart") then
			continue
		end

		-- The part's bounding sphere, not its axis-aligned size: a rotated part
		-- sticks out past its own extents, and under-measuring here is the one
		-- error this index must never make.
		local reach = Vector3.one * (descendant.Size.Magnitude * 0.5)
		local centre = descendant.Position
		local low = centre - reach
		local high = centre + reach

		if minimum == nil then
			minimum = low
			maximum = high
			velocity = descendant.AssemblyLinearVelocity
		else
			minimum = (minimum :: Vector3):Min(low)
			maximum = (maximum :: Vector3):Max(high)
		end
	end

	if minimum == nil then
		return nil, 0, Vector3.zero
	end

	local low = minimum :: Vector3
	local high = maximum :: Vector3

	return (low + high) * 0.5, (high - low).Magnitude * 0.5, velocity
end

-- The bucket for a cell, created only the first time anything lands in it.
-- Buckets outlive a refresh on purpose: the array keeps its allocated capacity
-- through table.clear, so a stable set of occupied cells stops allocating
-- entirely after the first frame.
local function bucketAt(self: ZoneIndex, x: number, y: number, z: number): Bucket
	local cells = self._cells
	local plane = cells[x]

	if plane == nil then
		plane = {}
		cells[x] = plane
	end

	local row = plane[y]

	if row == nil then
		row = {}
		plane[y] = row
	end

	local bucket = row[z]

	if bucket == nil then
		bucket = {
			X = x,
			Y = y,
			Z = z,
			Entries = {},
		}
		row[z] = bucket
		table.insert(self._buckets, bucket)
	end

	return bucket
end

-- Drops buckets nothing landed in this refresh, and the rows and planes they
-- leave behind. Subjects that roam over a large map would otherwise leave one
-- empty bucket per cell they ever passed through.

-- Amortised: only worth walking once the dead outnumber the live, which keeps
-- the per-frame path at clear-and-fill.
local function compact(self: ZoneIndex)
	local buckets = self._buckets
	local cells = self._cells
	local kept = 0

	for index = 1, #buckets do
		local bucket = buckets[index]
		buckets[index] = nil

		if #bucket.Entries > 0 then
			kept += 1
			buckets[kept] = bucket
		else
			local plane = cells[bucket.X]

			if plane ~= nil then
				local row = plane[bucket.Y]

				if row ~= nil then
					row[bucket.Z] = nil

					if next(row) == nil then
						plane[bucket.Y] = nil

						if next(plane) == nil then
							cells[bucket.X] = nil
						end
					end
				end
			end
		end
	end
end

function ZoneIndex.new(options: ZoneIndexOptions?): ZoneIndex
	local resolved: ZoneIndexOptions = if options == nil then {} else options

	if type(resolved) ~= "table" then
		fail("expected an options table")
	end

	local cellSize = positiveNumber(resolved.CellSize, "CellSize", Tuning.CellSize)

	if cellSize < Tuning.MinCellSize then
		fail(`options.CellSize must be at least {Tuning.MinCellSize} studs`)
	end

	return (
		setmetatable({
			_cellSize = cellSize,
			_padding = nonNegativeNumber(resolved.Padding, "Padding", Tuning.Padding),
			_lookahead = nonNegativeNumber(resolved.Lookahead, "Lookahead", Tuning.Lookahead),
			_connect = resolved.Connector or defaultConnector,
			_disconnect = nil,
			_destroyed = false,
			_entries = {},
			_cells = {},
			_buckets = {},
			_stale = {},
			_sweepIn = 0,
			_maxRadius = 0,
			_dirty = true,
			_refreshes = 0,
			_queries = 0,
			_skipped = 0,
		}, ZoneIndex) :: any
	) :: ZoneIndex
end

function ZoneIndex.Track(self: ZoneIndex, subject: Instance)
	if typeof(subject) ~= "Instance" then
		fail("Track expects an Instance")
	end

	if self._entries[subject] ~= nil then
		return
	end

	if self._destroyed then
		fail("cannot Track on a destroyed index", "Destroyed")
	end

	self._entries[subject] = {
		Subject = subject,
		Position = Vector3.zero,
		Radius = 0,
	}
	self._dirty = true
	ZoneIndex._ensureAutoRefresh(self)
end

function ZoneIndex.Untrack(self: ZoneIndex, subject: Instance)
	if self._entries[subject] == nil then
		return
	end

	self._entries[subject] = nil
	self._dirty = true

	if next(self._entries) == nil then
		ZoneIndex._stopAutoRefresh(self)
	end
end

function ZoneIndex.IsTracking(self: ZoneIndex, subject: Instance): boolean
	return self._entries[subject] ~= nil
end

-- Recomputes every subject's cell. Runs once per frame on its own, so a moving
-- subject cannot be left in a stale cell by a caller who forgot to invalidate.
function ZoneIndex.Refresh(self: ZoneIndex)
	-- Emptied, not dropped. The arrays keep their capacity, so a stable set of
	-- occupied cells stops allocating after the first refresh.
	local buckets = self._buckets

	for _, bucket in buckets do
		table.clear(bucket.Entries)
	end

	local stale = self._stale
	table.clear(stale)
	-- Subjects are bucketed by their centre, so a query that only walked the
	-- cells its own sphere touches would miss a large subject whose centre sits
	-- outside them. The widest radius in the index is what the query has to
	-- widen its cell range by.
	local maxRadius = 0
	local cellSize = self._cellSize

	-- A full ancestry walk per subject per refresh was buying nothing most
	-- frames. Parent catches the subject detaching itself, which is the common
	-- case, and the deeper walk runs on a sweep instead. Between sweeps a
	-- subject detached higher up stays indexed and costs a query that finds
	-- nothing -- the direction this index is allowed to be wrong in.
	self._sweepIn -= 1
	local deepSweep = self._sweepIn <= 0

	if deepSweep then
		self._sweepIn = Tuning.PruneInterval
	end

	for subject, entry in self._entries do
		if subject.Parent == nil or (deepSweep and not subject:IsDescendantOf(game)) then
			table.insert(stale, subject)
			continue
		end

		local position, radius, velocity = measure(subject)

		if position == nil then
			continue
		end

		entry.Position = position
		-- The sphere has to cover where the subject will be by the time this
		-- entry is next refreshed, not only where it was measured.
		entry.Radius = radius + self._padding + velocity.Magnitude * self._lookahead

		if entry.Radius > maxRadius then
			maxRadius = entry.Radius
		end

		local bucket = bucketAt(
			self,
			math.floor(position.X / cellSize),
			math.floor(position.Y / cellSize),
			math.floor(position.Z / cellSize)
		)
		table.insert(bucket.Entries, entry)
	end

	for _, subject in stale do
		self._entries[subject] = nil
	end

	table.clear(stale)

	if #buckets > MIN_COMPACT_BUCKETS then
		local live = 0

		for _, bucket in buckets do
			if #bucket.Entries > 0 then
				live += 1
			end
		end

		if live * 2 < #buckets then
			compact(self)
		end
	end

	self._maxRadius = maxRadius
	self._refreshes += 1
	self._dirty = false
end

function ZoneIndex.Invalidate(self: ZoneIndex)
	self._dirty = true
end

-- Correctness cannot depend on the caller remembering to invalidate. A subject
-- that walked out of its cell and was never re-indexed would make a zone answer
-- "nothing near" and silently lose a real occupant, so the index marks itself
-- dirty every frame from its own lazy connection. Invalidate stays public for
-- tests and for callers who move something and want it seen immediately.
function ZoneIndex._ensureAutoRefresh(self: ZoneIndex)
	if self._disconnect ~= nil or next(self._entries) == nil then
		return
	end

	local connected, disconnectOrMessage = pcall(function()
		return self._connect(function()
			self._dirty = true
		end)
	end)

	if not connected or type(disconnectOrMessage) ~= "function" then
		-- Without a heartbeat the index would go stale, and a stale index drops
		-- hits. Failing loudly is the only safe answer.
		fail("could not start automatic refresh; supply options.Connector", "NoConnector")
	end

	self._disconnect = disconnectOrMessage :: Disconnect
end

function ZoneIndex._stopAutoRefresh(self: ZoneIndex)
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
		warn(`VirtualHit zone index disconnect failed: {tostring(message)}`)
	end
end

-- True when any tracked subject could reach inside the given sphere.

-- The one error this is allowed to make is a false positive, which costs the
-- query that would have run anyway. A false negative silently drops a real
-- occupant, so the cell range is widened by the widest radius in the index:
-- subjects sit in the cell holding their centre, and a subject large enough
-- reaches into the sphere from a cell the sphere itself never touches.
function ZoneIndex.AnyWithin(self: ZoneIndex, position: Vector3, radius: number): boolean
	if self._dirty then
		self:Refresh()
	end

	self._queries += 1

	if next(self._entries) == nil then
		self._skipped += 1
		return false
	end

	local cellSize = self._cellSize
	local reach = radius + self._maxRadius
	local minX = math.floor((position.X - reach) / cellSize)
	local maxX = math.floor((position.X + reach) / cellSize)
	local minY = math.floor((position.Y - reach) / cellSize)
	local maxY = math.floor((position.Y + reach) / cellSize)
	local minZ = math.floor((position.Z - reach) / cellSize)
	local maxZ = math.floor((position.Z + reach) / cellSize)

	local cells = self._cells

	for x = minX, maxX do
		local plane = cells[x]

		if plane ~= nil then
			for y = minY, maxY do
				local row = plane[y]

				if row ~= nil then
					for z = minZ, maxZ do
						local bucket = row[z]

						if bucket ~= nil then
							for _, entry in bucket.Entries do
								local limit = radius + entry.Radius

								if (entry.Position - position).Magnitude <= limit then
									return true
								end
							end
						end
					end
				end
			end
		end
	end

	self._skipped += 1
	return false
end

function ZoneIndex.GetStats(self: ZoneIndex): ZoneIndexStats
	local subjects = 0

	for _ in self._entries do
		subjects += 1
	end

	-- Live cells, not mapped ones: a bucket kept empty for reuse is not a cell
	-- anything is in.
	local cells = 0

	for _, bucket in self._buckets do
		if #bucket.Entries > 0 then
			cells += 1
		end
	end

	return table.freeze({
		Subjects = subjects,
		Cells = cells,
		Refreshes = self._refreshes,
		Queries = self._queries,
		Skipped = self._skipped,
	})
end

function ZoneIndex.Clear(self: ZoneIndex)
	table.clear(self._entries)
	table.clear(self._cells)
	table.clear(self._buckets)
	table.clear(self._stale)
	-- A stale widest radius would only ever widen a query, never narrow one, but
	-- an empty index has no business claiming a reach.
	self._maxRadius = 0
	-- A cleared index has nothing to sweep, and the next Track should get a full
	-- check rather than inherit a countdown from the old contents.
	self._sweepIn = 0
	self._dirty = true
	ZoneIndex._stopAutoRefresh(self)
end

function ZoneIndex.IsRefreshing(self: ZoneIndex): boolean
	return self._disconnect ~= nil
end

function ZoneIndex.IsDestroyed(self: ZoneIndex): boolean
	return self._destroyed
end

function ZoneIndex.Destroy(self: ZoneIndex)
	if self._destroyed then
		return
	end

	self._destroyed = true
	self:Clear()
end

return ZoneIndex
