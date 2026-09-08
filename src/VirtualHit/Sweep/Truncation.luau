--!strict

local TruncationReasonModule = require(script.Parent.TruncationReason)

-- What a Step could not see, and how sure it is about not having seen it.

-- Every limit in a sweep -- segment budget, per-segment hit cap, the engine's
-- own part cap, an allowlist that cannot be walked through -- has the same
-- failure shape: the answer is a prefix of the truth, and the caller has to be
-- able to tell. A system that quietly returns the prefix is worse than one that
-- returns nothing, because nothing looks like nothing while a prefix looks like
-- an answer.

-- One Step can reach several limits at once, so the tracker keeps the most
-- safety-critical one rather than the first or the last. That choice has to be
-- deterministic, which is what the priority ordering below is for.

-- Certain separates "there was more and I know it" from "there may have been
-- more and I cannot tell". MaxParts and Allowlist are the uncertain ones: the
-- engine does not report what it dropped behind its own cap, and an allowlist
-- query cannot look past its nearest contact.

local Truncation = {}

type TruncationReason = TruncationReasonModule.Value

export type Mutable = {
	Truncated: true,
	Reason: TruncationReason?,
	Certain: boolean,
	Required: number?,
	RequiredAtLeast: number?,
	Allowed: number?,
	Segment: number?,
	Observed: number?,
	Sample: number?,
	Limit: number?,
}

-- Only the Truncated flag is written back into stats, because that is the one
-- piece a caller reads without asking for the detail.
export type StatsSink = { Truncated: boolean }

export type Tracker = {
	Working: Mutable,
	HasWorking: boolean,
	Last: Mutable,
	HasLast: boolean,
	Snapshot: any,
}

local function priority(reason: TruncationReason): number
	if reason == TruncationReasonModule.EngineShapecastLimit then
		return 5
	elseif reason == TruncationReasonModule.MaxSegments then
		return 4
	elseif reason == TruncationReasonModule.MaxHitsPerSegment then
		return 3
	elseif reason == TruncationReasonModule.Allowlist then
		-- Structural rather than a cap: it applies to every segment, so it
		-- outranks a per-query part limit that may never have bitten.
		return 2
	else
		return 1
	end
end

function Truncation.create(): Mutable
	return {
		Truncated = true,
		Reason = nil,
		Certain = false,
		Required = nil,
		RequiredAtLeast = nil,
		Allowed = nil,
		Segment = nil,
		Observed = nil,
		Sample = nil,
		Limit = nil,
	}
end

function Truncation.reset(truncation: Mutable)
	truncation.Reason = nil
	truncation.Certain = false
	truncation.Required = nil
	truncation.RequiredAtLeast = nil
	truncation.Allowed = nil
	truncation.Segment = nil
	truncation.Observed = nil
	truncation.Sample = nil
	truncation.Limit = nil
end

function Truncation.copy(target: Mutable, source: Mutable)
	target.Reason = source.Reason
	target.Certain = source.Certain
	target.Required = source.Required
	target.RequiredAtLeast = source.RequiredAtLeast
	target.Allowed = source.Allowed
	target.Segment = source.Segment
	target.Observed = source.Observed
	target.Sample = source.Sample
	target.Limit = source.Limit
end

function Truncation.newTracker(): Tracker
	return {
		Working = Truncation.create(),
		HasWorking = false,
		Last = Truncation.create(),
		HasLast = false,
		Snapshot = nil,
	}
end

function Truncation.beginStep(tracker: Tracker)
	Truncation.reset(tracker.Working)
	tracker.HasWorking = false
end

-- Carries the Step's verdict into the readable slot and drops the frozen copy a
-- previous read handed out.
function Truncation.commit(tracker: Tracker)
	tracker.HasLast = tracker.HasWorking
	tracker.Snapshot = nil

	if tracker.HasWorking then
		Truncation.copy(tracker.Last, tracker.Working)
	end
end

function Truncation.clearLast(tracker: Tracker)
	tracker.HasLast = false
	tracker.Snapshot = nil
end

local function prepare(tracker: Tracker, stats: StatsSink, reason: TruncationReason): Mutable?
	stats.Truncated = true

	if tracker.HasWorking then
		local current = tracker.Working.Reason
		assert(current ~= nil, "active Sweep truncations must carry a reason")

		if priority(reason) <= priority(current :: TruncationReason) then
			return nil
		end
	end

	tracker.HasWorking = true
	local working = tracker.Working
	Truncation.reset(working)
	working.Reason = reason

	return working
end

function Truncation.recordMaxSegments(
	tracker: Tracker,
	stats: StatsSink,
	required: number,
	allowed: number
)
	local record = prepare(tracker, stats, TruncationReasonModule.MaxSegments)

	if record == nil then
		return
	end

	record.Certain = true
	record.Required = required
	record.Allowed = allowed
end

function Truncation.recordMaxHitsPerSegment(
	tracker: Tracker,
	stats: StatsSink,
	allowed: number,
	segment: number
)
	local record = prepare(tracker, stats, TruncationReasonModule.MaxHitsPerSegment)

	if record == nil then
		return
	end

	record.Certain = true
	record.RequiredAtLeast = allowed + 1
	record.Allowed = allowed
	record.Segment = segment
end

-- An allowlist can only ever report its nearest contact per segment, so the
-- step is honestly incomplete rather than quietly single-hit.
function Truncation.recordAllowlist(tracker: Tracker, stats: StatsSink, segment: number)
	local record = prepare(tracker, stats, TruncationReasonModule.Allowlist)

	if record == nil then
		return
	end

	record.Certain = false
	record.Segment = segment
end

function Truncation.recordMaxParts(
	tracker: Tracker,
	stats: StatsSink,
	observed: number,
	allowed: number,
	sample: number
)
	local record = prepare(tracker, stats, TruncationReasonModule.MaxParts)

	if record == nil then
		return
	end

	-- The engine stops at its cap without saying what it dropped, so this is
	-- the one limit that cannot promise there really was more behind it.
	record.Certain = false
	record.Observed = observed
	record.Allowed = allowed
	record.Sample = sample
end

function Truncation.recordEngineLimit(
	tracker: Tracker,
	stats: StatsSink,
	required: number,
	allowed: number,
	limit: number
)
	local record = prepare(tracker, stats, TruncationReasonModule.EngineShapecastLimit)

	if record == nil then
		return
	end

	record.Certain = true
	record.Required = required
	record.Allowed = allowed
	record.Limit = limit
end

return Truncation
