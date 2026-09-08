--!strict

local Types = require(script.Parent.Parent.Types)
local Ordering = require(script.Parent.Parent.Collision.Ordering)
local Candidate = require(script.Parent.Candidate)

-- The order contacts come back in, and what makes that order the same twice.

-- The engine has no opinion about which of two contacts happened first, so the
-- library has to have one and it has to be total. Physical facts decide first:
-- when along the motion (Alpha), then how far the shape had travelled, then how
-- far the contact sat from the shape. Only when all three tie does anything
-- else get a say, and then the tie-break reads a metadata snapshot taken before
-- any caller callback ran -- because a callback that reordered live properties
-- mid-sort could otherwise decide its own ordering.

-- Priority and Response are layered on top of that, never underneath it. A
-- blocker wins an exact physical tie even over caller priority, because
-- priority is an ordering tool and not an occlusion bypass.

local CandidateOrdering = {}

type RawCandidate = Candidate.RawCandidate
type RankedCandidate = Candidate.RankedCandidate
type TieMetadata = Candidate.TieMetadata

-- Only the counters the ordering itself moves.
export type StatsSink = {
	TieBreakCandidates: number,
	UniqueCandidates: number,
}

local numberOrder = Ordering.number

local function rawCandidatePhysicalComparison(left: RawCandidate, right: RawCandidate): boolean?
	local comparison = numberOrder(left.Alpha, right.Alpha)

	if comparison ~= nil then
		return comparison
	end

	comparison = numberOrder(left.PathDistance, right.PathDistance)

	if comparison ~= nil then
		return comparison
	end

	comparison = numberOrder(left.SurfaceDistance, right.SurfaceDistance)

	if comparison ~= nil then
		return comparison
	end

	return nil
end

local function rawCandidatePrimaryComparison(left: RawCandidate, right: RawCandidate): boolean?
	local comparison = rawCandidatePhysicalComparison(left, right)

	if comparison ~= nil then
		return comparison
	end

	if left.Kind ~= right.Kind then
		-- A native contact carries a truthful surface point and normal, so prefer
		-- it to an endpoint overlap at the same physical point.
		return left.Kind == "Sweep"
	end

	return nil
end

local function rawCandidatePrimaryOrder(left: RawCandidate, right: RawCandidate): boolean
	return rawCandidatePrimaryComparison(left, right) == true
end

local function rawCandidateOrder(left: RawCandidate, right: RawCandidate): boolean
	local comparison = rawCandidatePrimaryComparison(left, right)

	if comparison ~= nil then
		return comparison
	end

	if left == right then
		return false
	end

	local leftMetadata = left.TieMetadata
	local rightMetadata = right.TieMetadata
	assert(leftMetadata ~= nil, "left tied candidate is missing tie metadata")
	assert(rightMetadata ~= nil, "right tied candidate is missing tie metadata")

	comparison = Ordering.metadata(leftMetadata, rightMetadata)

	if comparison ~= nil then
		return comparison
	end

	-- The same part reached by two compound members at the same physical point
	-- is still one candidate; only genuinely distinct parts can get this far.
	comparison = numberOrder(left.Member, right.Member)

	if comparison ~= nil then
		return comparison
	end

	-- Exact geometric/name ties need a caller HitPriority to define an order.
	return false
end

local function rankedCandidateOrder(left: RankedCandidate, right: RankedCandidate): boolean
	local comparison = rawCandidatePrimaryComparison(left.Raw, right.Raw)

	if comparison ~= nil then
		return comparison
	end

	if left.Priority ~= right.Priority then
		return left.Priority > right.Priority
	end

	return rawCandidateOrder(left.Raw, right.Raw)
end

local function responseRank(response: Types.HitResponse): number
	if response == "Block" then
		return 1
	elseif response == "Hit" then
		return 2
	else
		return 3
	end
end

local function evaluatedCandidateOrder(left: RankedCandidate, right: RankedCandidate): boolean
	local comparison = rawCandidatePhysicalComparison(left.Raw, right.Raw)

	if comparison ~= nil then
		return comparison
	end

	local leftResponseRank = responseRank(left.Response)
	local rightResponseRank = responseRank(right.Response)

	if (left.Response == "Block") ~= (right.Response == "Block") then
		-- A blocker wins an exact physical tie even over caller priority.
		-- Priority is an ordering tool, not an occlusion bypass.
		return left.Response == "Block"
	end

	if left.Raw.Kind ~= right.Raw.Kind then
		return left.Raw.Kind == "Sweep"
	end

	if left.Priority ~= right.Priority then
		return left.Priority > right.Priority
	end

	if leftResponseRank ~= rightResponseRank then
		return leftResponseRank < rightResponseRank
	end

	return rawCandidateOrder(left.Raw, right.Raw)
end

-- One part is one candidate, but which contact represents it has to be the
-- physically earliest one, not the first member that happened to be walked.
-- Members are traversed in index order, so a naive first-wins dedup would let
-- member 1's late contact hide member 2's early one, and no amount of sorting
-- afterwards could recover a candidate that was never collected.
function CandidateOrdering.keepBest(
	stats: StatsSink,
	fresh: RawCandidate,
	candidates: { RawCandidate },
	encountered: { [BasePart]: number }
)
	local index = encountered[fresh.Instance]

	if index == nil then
		table.insert(candidates, fresh)
		encountered[fresh.Instance] = #candidates
		stats.UniqueCandidates += 1
		return
	end

	if rawCandidatePrimaryComparison(fresh, candidates[index]) == true then
		candidates[index] = fresh
	end
end

-- Cheap rejection before the engine call that measures surface distance: a
-- candidate that is already strictly later than the stored one cannot win.
-- Cheap rejection before the engine call that measures surface distance: a
-- candidate that is already strictly later than the stored one cannot win.
function CandidateOrdering.cannotImprove(
	alpha: number,
	part: BasePart,
	candidates: { RawCandidate },
	encountered: { [BasePart]: number }
): boolean
	local index = encountered[part]

	if index == nil then
		return false
	end

	return candidates[index].Alpha < alpha
end

-- Sorts the raw set into the order the rest of the pipeline depends on, and
-- takes tie metadata only for the runs that actually tied. Snapshotting every
-- candidate would read live properties for contacts nothing will compare.
function CandidateOrdering.prepareRaw(stats: StatsSink, rawCandidates: { RawCandidate })
	if #rawCandidates < 2 then
		return
	end

	table.sort(rawCandidates, rawCandidatePrimaryOrder)
	local runStart = 1
	local hasPrimaryTie = false

	while runStart <= #rawCandidates do
		local runEnd = runStart + 1

		while
			runEnd <= #rawCandidates
			and rawCandidatePrimaryComparison(rawCandidates[runStart], rawCandidates[runEnd])
				== nil
		do
			runEnd += 1
		end

		if runEnd - runStart > 1 then
			hasPrimaryTie = true

			-- Keep every later ordering phase on the same pre-callback view.
			-- Reading live properties from a comparator would let callbacks reorder it.
			for index = runStart, runEnd - 1 do
				local candidate = rawCandidates[index]

				if candidate.TieMetadata == nil then
					candidate.TieMetadata = Ordering.snapshot(candidate.Instance)
					stats.TieBreakCandidates += 1
				end
			end
		end

		runStart = runEnd
	end

	if hasPrimaryTie then
		table.sort(rawCandidates, rawCandidateOrder)
	end
end

-- The comparators the sweep hands to table.sort. Exposed rather than inlined so
-- the ordering rules live in one place and the sort sites read as what they
-- are: two passes over one array, physical order then response order.
CandidateOrdering.rankedOrder = rankedCandidateOrder
CandidateOrdering.evaluatedOrder = evaluatedCandidateOrder

return CandidateOrdering
