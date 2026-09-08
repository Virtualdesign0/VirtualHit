--!strict

local Types = require(script.Parent.Parent.Types)
local Ordering = require(script.Parent.Parent.Collision.Ordering)

-- The working storage one Step needs, and none of which any caller ever sees.

-- A projectile substep that hits nothing used to allocate eleven tables to
-- report nothing, and two hundred projectiles at three substeps each is six
-- thousand of those per frame. None of it escapes the Step, so none of it has
-- to be new: the arrays are cleared and refilled, and the records are leased
-- from pools that grow to the busiest Step the sweep has ever had.

-- Reuse is safe because Step is guarded against re-entry on the same sweep, and
-- a callback that steps a *different* sweep touches that sweep's own scratch.

local Candidate = {}

export type TieMetadata = Ordering.TieMetadata

export type RawCandidate = {
	Instance: BasePart,
	Kind: "Overlap" | "Sweep",
	Member: number,
	Alpha: number,
	Pose: CFrame,
	NativeResult: RaycastResult?,
	PathDistance: number,
	SurfaceDistance: number,
	TieMetadata: TieMetadata?,
}

-- One record for both ordering phases. Ranking fills Candidate and Priority,
-- evaluation fills Response, and the array is re-sorted in place. Copying the
-- whole set into a second array of second records bought nothing but garbage.
export type RankedCandidate = {
	Candidate: Types.SweepCandidate,
	Raw: RawCandidate,
	Priority: number,
	Response: Types.HitResponse,
	-- Filled by the key pass in _applyEvaluated, read by the commit pass.
	Key: any,
}

export type ExclusionState = {
	List: { Instance },
	Seen: { [Instance]: boolean },
	-- An allowlist holds the only things the query may hit, so there is nothing
	-- to add to it: naming a part again leaves it hittable, and the alias that
	-- would turn the list into a blocklist would let the whole world in.
	Allowlist: boolean,
}

export type Scratch = {
	RootPoses: { CFrame },
	-- The Step being walked, so a candidate can report where the sweep root was
	-- at its contact alpha and not only where the member was.
	Previous: CFrame,
	Current: CFrame,
	Candidates: { RawCandidate },
	Encountered: { [BasePart]: number },
	Verdicts: { [BasePart]: boolean },
	BaseExclusions: { Instance },
	Ranked: { RankedCandidate },
	CandidatePool: { RawCandidate },
	CandidateLeased: number,
	RankedPool: { RankedCandidate },
	RankedLeased: number,
	ExclusionStates: { ExclusionState },
}

function Candidate.newScratch(): Scratch
	return {
		RootPoses = {},
		Previous = CFrame.identity,
		Current = CFrame.identity,
		Candidates = {},
		Encountered = {},
		Verdicts = {},
		BaseExclusions = {},
		Ranked = {},
		CandidatePool = {},
		CandidateLeased = 0,
		RankedPool = {},
		RankedLeased = 0,
		ExclusionStates = {},
	}
end

-- Where the sweep root was when a member made contact at this alpha.

-- The sample chains are built by lerping the root pose and applying each
-- member offset, so lerping the root by the same alpha is the pose that
-- produced the contact. Reporting the member pose as the sweep pose is what
-- would move a projectile body to wherever its offset arm happened to touch.
function Candidate.rootPoseAt(scratch: Scratch, alpha: number): CFrame
	if alpha <= 0 then
		return scratch.Previous
	end

	if alpha >= 1 then
		return scratch.Current
	end

	return scratch.Previous:Lerp(scratch.Current, alpha)
end

-- Returns the scratch with every array emptied and every pool handed back.
-- Records leased last Step are reused rather than collected; nothing here

function Candidate.resetScratch(scratch: Scratch): Scratch
	table.clear(scratch.RootPoses)
	table.clear(scratch.Candidates)
	table.clear(scratch.Encountered)
	table.clear(scratch.Verdicts)
	table.clear(scratch.BaseExclusions)
	table.clear(scratch.Ranked)
	scratch.CandidateLeased = 0
	scratch.RankedLeased = 0

	return scratch
end

-- Drops what the pooled records were pointing at once the Step is over.

-- The records themselves are kept -- that is the whole point of the pool -- but
-- an idle sweep has no business holding engine results describing a frame that
-- nobody will ask about again.
function Candidate.releaseScratch(scratch: Scratch)
	for index = 1, scratch.CandidateLeased do
		local record = scratch.CandidatePool[index]
		record.NativeResult = nil
		record.TieMetadata = nil
	end

	for index = 1, scratch.RankedLeased do
		-- A HitKey is caller-supplied and can be anything, including something
		-- large. An idle sweep has no business holding the last Step's keys.
		scratch.RankedPool[index].Key = nil
	end

	table.clear(scratch.Candidates)
	table.clear(scratch.Encountered)
	table.clear(scratch.Verdicts)
	table.clear(scratch.Ranked)
end

-- Traversal exclusions are member-local and live in a sweep-owned array with
-- its own membership set. Reading FilterDescendantsInstances back would
-- allocate a fresh array on every hit, and a shared list would let one
-- member's contact disappear from another member's cast entirely.

-- One state per member index is kept for the life of the sweep and refilled,
-- because a Compound sweep would otherwise allocate two tables per member on
-- every Step just to start from the same base list it started from last time.
function Candidate.prepareExclusionState(
	scratch: Scratch,
	memberIndex: number,
	base: { Instance },
	allowlist: boolean
): ExclusionState
	local state = scratch.ExclusionStates[memberIndex]

	if state == nil then
		state = {
			List = {},
			Seen = {},
			Allowlist = allowlist,
		}
		scratch.ExclusionStates[memberIndex] = state
	else
		table.clear(state.List)
		table.clear(state.Seen)
		state.Allowlist = allowlist
	end

	for index, instance in base do
		state.List[index] = instance
		state.Seen[instance] = true
	end

	return state
end

-- False when the part cannot be walked past, which is the caller's signal to
-- stop traversing this segment rather than cast into the same part forever.
function Candidate.addExclusion(
	params: RaycastParams,
	state: ExclusionState,
	instance: Instance
): boolean
	if state.Allowlist then
		return false
	end

	if state.Seen[instance] then
		return true
	end

	state.Seen[instance] = true
	table.insert(state.List, instance)
	params.FilterDescendantsInstances = state.List

	return true
end

-- Leased from the pool rather than built. A raw candidate never leaves the
-- Step that produced it -- the record a caller sees is a separate frozen table
-- so the pool can hand the same record back next Step.
function Candidate.leaseRaw(
	scratch: Scratch,
	part: BasePart,
	kind: "Overlap" | "Sweep",
	member: number,
	alpha: number,
	pose: CFrame,
	nativeResult: RaycastResult?,
	pathDistance: number,
	surfaceDistance: number
): RawCandidate
	local index = scratch.CandidateLeased + 1
	scratch.CandidateLeased = index
	local record = scratch.CandidatePool[index]

	if record == nil then
		-- Annotated rather than inferred: an inferred literal types TieMetadata
		-- as `nil`, and a pool slot has to hold every later value too.
		local fresh: RawCandidate = {
			Instance = part,
			Kind = kind,
			Member = member,
			Alpha = alpha,
			Pose = pose,
			NativeResult = nativeResult,
			PathDistance = pathDistance,
			SurfaceDistance = surfaceDistance,
			TieMetadata = nil,
		}
		scratch.CandidatePool[index] = fresh

		return fresh
	end

	record.Instance = part
	record.Kind = kind
	record.Member = member
	record.Alpha = alpha
	record.Pose = pose
	record.NativeResult = nativeResult
	record.PathDistance = pathDistance
	record.SurfaceDistance = surfaceDistance
	-- Stale metadata would silently decide a tie this Step never measured.
	record.TieMetadata = nil

	return record
end

return Candidate
