--!strict

local Types = require(script.Parent.Parent.Types)
local SweepClass = require(script.Parent.Parent.Sweep.Sweep)
local Errors = require(script.Parent.Parent.Util.Errors)
local Config = require(script.Parent.Parent.Config)

-- Live config section. Read through it so VirtualHit.configure() takes
-- effect without reloading the library.
local Tuning = Config.Recorder

-- Determinism is the loudest promise this library makes, and nothing else
-- protects it. A recorder turns a run into a comparable trace: the same scene
-- driven the same way must produce an identical trace, and when it does not,
-- the diff names the first frame and the first field that moved.

-- The second use is the one nobody has a tool for. A client predicting a shot
-- and a server replaying it are two runs of the same scene on two machines, so
-- the same trace comparison answers "did the client and server agree", and
-- reconcile() classifies the disagreement instead of just reporting one.

-- Nothing here is instrumentation. Recording is explicit, driven by the caller
-- through StepSweep, so a recorded run is exactly the run the caller performed.

local Recorder = {}
Recorder.__index = Recorder

local POSITION_PRECISION = 1e-3

-- Structured, so a divergence can be classified rather than only detected, and
-- flat enough to cross a RemoteEvent without losing anything.
export type HitRecord = {
	read Response: string,
	read Kind: string,
	read Instance: string,
	read Entity: string?,
	read Zone: string?,
	read Member: number,
	read Alpha: number,
	read Position: Vector3?,
	read Normal: Vector3?,
	read Distance: number?,
	read Material: string?,
}

export type StatsRecord = {
	read Segments: number,
	read RequiredSegments: number,
	read OverlapQueries: number,
	read ShapeCasts: number,
	read RawCandidates: number,
	read UniqueCandidates: number,
	read TieBreakCandidates: number,
	read Hits: number,
	read Ignored: number,
	read PolicyRejected: number,
	read Blocked: number,
	read Occluded: number,
	read Truncated: boolean,
}

export type Frame = {
	read Index: number,
	read Label: string,
	read Hits: { HitRecord },
	read Block: HitRecord?,
	read Stats: StatsRecord?,
}

export type Trace = {
	read Frames: { Frame },
}

export type Divergence = {
	read Frame: number,
	read Label: string,
	read Field: string,
	read Left: string,
	read Right: string,
}

-- What kind of disagreement this is. A shot the client saw and the server did
-- not is a very different problem from the same shot landing two studs apart.
export type DivergenceKind =
	"FrameCount"
	| "Label"
	| "Missing"
	| "Extra"
	| "Ordering"
	| "Timing"
	| "Geometry"
	| "Classification"
	| "Block"
	| "Stats"

export type Disagreement = {
	read Frame: number,
	read Label: string,
	read Kind: DivergenceKind,
	read Detail: string,
	read Client: string?,
	read Server: string?,
}

export type Report = {
	read Agreed: boolean,
	read Frames: number,
	read Disagreements: { Disagreement },
	read First: Disagreement?,
}

export type ReconcileOptions = {
	-- How far a contact point may move between machines before it counts.
	-- Two runs of the same geometry on different hardware are not bit-identical.
	PositionTolerance: number?,
	AlphaTolerance: number?,
	-- Counters are a strong signal but also the noisiest across machines with
	-- different streaming state, so they are off by default.
	CompareStats: boolean?,
}

export type Recorder = typeof(setmetatable(
	{} :: {
		_frames: { Frame },
		_recording: boolean,
	},
	Recorder
))

local function fail(message: string, code: string?): never
	return Errors.raise("VirtualHit.Recorder", code or "InvalidArgument", message, 3)
end

local function round(value: number): number
	return math.round(value / POSITION_PRECISION) * POSITION_PRECISION
end

local function vectorText(value: Vector3?): string
	if value == nil then
		return "-"
	end

	return string.format("%.3f,%.3f,%.3f", round(value.X), round(value.Y), round(value.Z))
end

-- Everything the ordering contract promises, and nothing incidental. Table
local function recordHit(hit: Types.SweepHit | Types.SweepBlock): HitRecord
	-- Built in one expression rather than assigned into afterwards. A record is
	-- frozen the moment it exists, so its type says read-only, and a type that
	-- says read-only cannot be filled in field by field.
	local result = if hit.Kind == "Sweep" then hit.Result else nil

	return table.freeze({
		Response = hit.Response,
		Kind = hit.Kind,
		Instance = hit.Instance:GetFullName(),
		Entity = if hit.Entity == nil then nil else hit.Entity:GetFullName(),
		Zone = hit.Zone,
		Member = hit.Member,
		Alpha = round(hit.Alpha),
		Position = if result then result.Position else nil,
		Normal = if result then result.Normal else nil,
		Distance = if result then round(result.Distance) else nil,
		Material = if result then result.Material.Name else nil,
	})
end

local function hitText(record: HitRecord): string
	local base = string.format(
		"%s|%s|%s|%s|m%d|a%.4f|%s",
		record.Response,
		record.Instance,
		record.Entity or "-",
		record.Zone or "-",
		record.Member,
		record.Alpha,
		record.Kind
	)

	if record.Position == nil then
		return base
	end

	return string.format(
		"%s|p%s|n%s|d%.3f|%s",
		base,
		vectorText(record.Position),
		vectorText(record.Normal),
		record.Distance or 0,
		record.Material or "-"
	)
end

-- Counters only. Times and cache-hit counts are performance facts, not
-- determinism facts, and would make every trace differ.
local function recordStats(stats: SweepClass.SweepStats?): StatsRecord?
	if stats == nil then
		return nil
	end

	return table.freeze({
		Segments = stats.Segments,
		RequiredSegments = stats.RequiredSegments,
		OverlapQueries = stats.OverlapQueries,
		ShapeCasts = stats.ShapeCasts,
		RawCandidates = stats.RawCandidates,
		UniqueCandidates = stats.UniqueCandidates,
		TieBreakCandidates = stats.TieBreakCandidates,
		Hits = stats.Hits,
		Ignored = stats.Ignored,
		PolicyRejected = stats.PolicyRejected,
		Blocked = stats.Blocked,
		Occluded = stats.Occluded,
		Truncated = stats.Truncated,
	})
end

local function statsText(stats: StatsRecord?): string
	if stats == nil then
		return "none"
	end

	return string.format(
		"seg%d/%d ov%d sc%d raw%d uniq%d tie%d hit%d ign%d rej%d blk%d occ%d trunc%s",
		stats.Segments,
		stats.RequiredSegments,
		stats.OverlapQueries,
		stats.ShapeCasts,
		stats.RawCandidates,
		stats.UniqueCandidates,
		stats.TieBreakCandidates,
		stats.Hits,
		stats.Ignored,
		stats.PolicyRejected,
		stats.Blocked,
		stats.Occluded,
		tostring(stats.Truncated)
	)
end

function Recorder.new(): Recorder
	return (setmetatable({
		_frames = {},
		_recording = true,
	}, Recorder) :: any) :: Recorder
end

function Recorder.Start(self: Recorder)
	self._recording = true
end

function Recorder.Stop(self: Recorder)
	self._recording = false
end

function Recorder.Clear(self: Recorder)
	table.clear(self._frames)
end

function Recorder.Record(
	self: Recorder,
	label: string,
	hits: { Types.SweepHit },
	block: Types.SweepBlock?,
	stats: SweepClass.SweepStats?
)
	if not self._recording then
		return
	end

	if type(label) ~= "string" then
		fail("Record expects a string label")
	end

	local records: { HitRecord } = {}

	for _, hit in hits do
		table.insert(records, recordHit(hit))
	end

	table.insert(self._frames, {
		Index = #self._frames + 1,
		Label = label,
		Hits = records,
		Block = if block == nil then nil else recordHit(block),
		Stats = recordStats(stats),
	})
end

-- Steps a sweep and records the result in one call, so a recorded run cannot
-- drift from the run that produced it.
function Recorder.StepSweep(
	self: Recorder,
	label: string,
	sweep: SweepClass.Sweep,
	previous: CFrame,
	current: CFrame
): ({ Types.SweepHit }, Types.SweepBlock?)
	local hits, block = sweep:Step(previous, current)
	self:Record(label, hits, block, sweep:GetLastStats())

	return hits, block
end

function Recorder.GetTrace(self: Recorder): Trace
	local frames: { Frame } = {}

	for _, frame in self._frames do
		table.insert(
			frames,
			table.freeze({
				Index = frame.Index,
				Label = frame.Label,
				Hits = table.freeze(table.clone(frame.Hits)),
				Block = frame.Block,
				Stats = frame.Stats,
			})
		)
	end

	return table.freeze({ Frames = table.freeze(frames) })
end

function Recorder.GetFrameCount(self: Recorder): number
	return #self._frames
end

-- Everything a trace holds is a string, a number, a boolean or a Vector3, so a
-- trace crosses a RemoteEvent unchanged. That is what lets a client hand its
-- prediction to the server for comparison.
function Recorder.Serialize(self: Recorder): Trace
	return self:GetTrace()
end

function Recorder.deserialize(payload: any): Trace
	if type(payload) ~= "table" or type(payload.Frames) ~= "table" then
		fail("deserialize expects a table with a Frames array")
	end

	local frames: { Frame } = {}

	for index, frame in payload.Frames do
		if type(frame) ~= "table" or type(frame.Label) ~= "string" then
			fail(`frame {index} is malformed`)
		end

		local hits: { HitRecord } = {}

		-- `payload` is whatever came off the wire, so `frame.Hits` is `any`
		-- until the guard below has looked at each entry. Naming the array
		-- gives the loop a type; the guard is still the real check.
		local rawHits: { any } = if type(frame.Hits) == "table" then frame.Hits else {}

		for hitIndex, hit in rawHits do
			if type(hit) ~= "table" or type(hit.Instance) ~= "string" then
				fail(`frame {index} hit {hitIndex} is malformed`)
			end

			table.insert(hits, (table.freeze(table.clone(hit)) :: any) :: HitRecord)
		end

		table.insert(
			frames,
			table.freeze({
				Index = index,
				Label = frame.Label,
				Hits = table.freeze(hits),
				Block = frame.Block,
				Stats = frame.Stats,
			})
		)
	end

	return table.freeze({ Frames = table.freeze(frames) })
end

-- A flat, diffable rendering of the whole trace. Two identical runs produce
-- identical strings, which makes this usable as a golden file.
function Recorder.ToString(self: Recorder): string
	return Recorder.render(self:GetTrace())
end

function Recorder.render(trace: Trace): string
	local lines: { string } = {}

	for _, frame in trace.Frames do
		table.insert(
			lines,
			string.format("#%d %s [%s]", frame.Index, frame.Label, statsText(frame.Stats))
		)

		for index, hit in frame.Hits do
			table.insert(lines, string.format("  hit%d %s", index, hitText(hit)))
		end

		if frame.Block ~= nil then
			table.insert(lines, string.format("  block %s", hitText(frame.Block)))
		end
	end

	return table.concat(lines, "\n")
end

local function divergence(
	frame: number,
	label: string,
	field: string,
	left: string,
	right: string
): Divergence
	return table.freeze({
		Frame = frame,
		Label = label,
		Field = field,
		Left = left,
		Right = right,
	})
end

-- The first place two traces stop agreeing, or nil when they match. Returning
-- only the first divergence is deliberate: after one ordering difference every
-- later frame differs too, and that noise hides the cause.
function Recorder.diff(left: Trace, right: Trace): Divergence?
	if type(left) ~= "table" or type(right) ~= "table" then
		fail("diff expects two traces")
	end

	local count = math.max(#left.Frames, #right.Frames)

	for index = 1, count do
		local a = left.Frames[index]
		local b = right.Frames[index]

		if a == nil or b == nil then
			local label = if a ~= nil then a.Label else (b :: Frame).Label
			return divergence(
				index,
				label,
				"FrameCount",
				tostring(#left.Frames),
				tostring(#right.Frames)
			)
		end

		if a.Label ~= b.Label then
			return divergence(index, a.Label, "Label", a.Label, b.Label)
		end

		if #a.Hits ~= #b.Hits then
			return divergence(index, a.Label, "HitCount", tostring(#a.Hits), tostring(#b.Hits))
		end

		for hitIndex = 1, #a.Hits do
			local leftText = hitText(a.Hits[hitIndex])
			local rightText = hitText(b.Hits[hitIndex])

			if leftText ~= rightText then
				return divergence(index, a.Label, `Hit[{hitIndex}]`, leftText, rightText)
			end
		end

		local leftBlock = if a.Block == nil then "none" else hitText(a.Block)
		local rightBlock = if b.Block == nil then "none" else hitText(b.Block)

		if leftBlock ~= rightBlock then
			return divergence(index, a.Label, "Block", leftBlock, rightBlock)
		end

		local leftStats = statsText(a.Stats)
		local rightStats = statsText(b.Stats)

		if leftStats ~= rightStats then
			return divergence(index, a.Label, "Stats", leftStats, rightStats)
		end
	end

	return nil
end

function Recorder.describe(value: Divergence | Disagreement): string
	local field = (value :: any).Field or (value :: any).Kind
	local left = (value :: any).Left or (value :: any).Client or "-"
	local right = (value :: any).Right or (value :: any).Server or "-"

	return string.format(
		"frame %d (%s) %s:\n  left  %s\n  right %s",
		value.Frame,
		value.Label,
		tostring(field),
		tostring(left),
		tostring(right)
	)
end

local function identity(record: HitRecord): string
	-- What makes two hits "the same hit". Position and timing are compared
	-- separately, because a shot landing slightly differently is a different
	-- problem from a shot landing on something else entirely.
	return `{record.Instance}|{record.Member}|{record.Kind}`
end

local function positiveTolerance(value: any, name: string, defaultValue: number): number
	if value == nil then
		return defaultValue
	end

	if type(value) ~= "number" or value ~= value or value < 0 then
		fail(`options.{name} must be a non-negative number`)
	end

	return value
end

-- Compares a client prediction against the server's own replay and says what
-- kind of disagreement each one is. Both sides have to label their frames the
-- same way, normally with the shot id the claim carried.

-- A report is a diagnosis, not a verdict: only the server's own trace is
-- authoritative, and disagreement is as often streaming or latency as it is
-- anything worth acting on.
function Recorder.reconcile(client: Trace, server: Trace, options: ReconcileOptions?): Report
	local resolved: ReconcileOptions = if options == nil then {} else options

	if type(client) ~= "table" or type(server) ~= "table" then
		fail("reconcile expects two traces")
	end

	if type(resolved) ~= "table" then
		fail("options must be a table")
	end

	local positionTolerance =
		positiveTolerance(resolved.PositionTolerance, "PositionTolerance", Tuning.PositionTolerance)
	local alphaTolerance =
		positiveTolerance(resolved.AlphaTolerance, "AlphaTolerance", Tuning.AlphaTolerance)
	local compareStats = resolved.CompareStats == true
	local disagreements: { Disagreement } = {}

	local function report(
		frame: number,
		label: string,
		kind: DivergenceKind,
		detail: string,
		clientText: string?,
		serverText: string?
	)
		table.insert(
			disagreements,
			table.freeze({
				Frame = frame,
				Label = label,
				Kind = kind,
				Detail = detail,
				Client = clientText,
				Server = serverText,
			})
		)
	end

	local count = math.max(#client.Frames, #server.Frames)

	for index = 1, count do
		local a = client.Frames[index]
		local b = server.Frames[index]

		if a == nil or b == nil then
			local label = if a ~= nil then a.Label else (b :: Frame).Label
			report(
				index,
				label,
				"FrameCount",
				"one side recorded a frame the other did not",
				tostring(#client.Frames),
				tostring(#server.Frames)
			)
			break
		end

		if a.Label ~= b.Label then
			report(index, a.Label, "Label", "frames are not aligned", a.Label, b.Label)
			break
		end

		local serverByIdentity: { [string]: HitRecord } = {}
		local serverOrder: { [string]: number } = {}

		for position, hit in b.Hits do
			local key = identity(hit)
			serverByIdentity[key] = hit
			serverOrder[key] = position
		end

		local clientByIdentity: { [string]: boolean } = {}

		for position, hit in a.Hits do
			local key = identity(hit)
			clientByIdentity[key] = true
			local counterpart = serverByIdentity[key]

			if counterpart == nil then
				report(
					index,
					a.Label,
					"Missing",
					"the client reported a hit the server did not",
					hitText(hit),
					nil
				)
				continue
			end

			if serverOrder[key] ~= position then
				report(
					index,
					a.Label,
					"Ordering",
					`the same hit is at position {position} on the client and {serverOrder[key]} on the server`,
					hitText(hit),
					hitText(counterpart)
				)
			end

			if math.abs(hit.Alpha - counterpart.Alpha) > alphaTolerance then
				report(
					index,
					a.Label,
					"Timing",
					"the contact happened at a different point in the motion",
					tostring(hit.Alpha),
					tostring(counterpart.Alpha)
				)
			end

			local hitPosition = hit.Position
			local otherPosition = counterpart.Position

			if
				hitPosition ~= nil
				and otherPosition ~= nil
				and (hitPosition - otherPosition).Magnitude > positionTolerance
			then
				report(
					index,
					a.Label,
					"Geometry",
					"the contact point differs beyond tolerance",
					vectorText(hitPosition),
					vectorText(otherPosition)
				)
			end

			if hit.Entity ~= counterpart.Entity or hit.Zone ~= counterpart.Zone then
				report(
					index,
					a.Label,
					"Classification",
					"the same contact resolved to a different entity or zone",
					`{hit.Entity or "-"}/{hit.Zone or "-"}`,
					`{counterpart.Entity or "-"}/{counterpart.Zone or "-"}`
				)
			end
		end

		for _, hit in b.Hits do
			if not clientByIdentity[identity(hit)] then
				report(
					index,
					a.Label,
					"Extra",
					"the server reported a hit the client did not",
					nil,
					hitText(hit)
				)
			end
		end

		local clientBlock = if a.Block == nil then "none" else hitText(a.Block)
		local serverBlock = if b.Block == nil then "none" else hitText(b.Block)

		if clientBlock ~= serverBlock then
			report(index, a.Label, "Block", "the blockers disagree", clientBlock, serverBlock)
		end

		if compareStats then
			local clientStats = statsText(a.Stats)
			local serverStats = statsText(b.Stats)

			if clientStats ~= serverStats then
				report(index, a.Label, "Stats", "the counters differ", clientStats, serverStats)
			end
		end
	end

	return table.freeze({
		Agreed = #disagreements == 0,
		Frames = count,
		Disagreements = table.freeze(disagreements),
		First = disagreements[1],
	})
end

return Recorder
