--!strict

-- Every error this library raises carries a code.

-- A string message is fine for a human and useless for a caller: a combat
-- system that wants to fall back when a ProbeFree sweep meets a rotating shape,
-- or to drop a shot when a projectile hits the engine's shapecast limit, cannot
-- pattern-match prose. It needs something to branch on.

-- The thrown value is a table, but tostring() reproduces exactly what the old
-- string errors produced, position prefix included, so logs, tracebacks and
-- Studio output are unchanged. Nothing that reads errors as text has to care
-- that they are now structured.

local Errors = {}

export type Error = {
	Code: string,
	Message: string,
	Source: string,
	Detail: { [string]: any }?,
}

local ErrorMeta = {}

function ErrorMeta.__tostring(self: any): string
	return self._text
end

ErrorMeta.__index = ErrorMeta

-- Reproduces Lua's own "chunk:line: " prefix. error() only prepends position to
-- string values, so raising a table would otherwise lose the one piece of
-- information that says which line went wrong.
local function positionAt(level: number): string
	-- Walks past frames that have no position of their own. Every module raises
	-- through a `fail` helper written as `return Errors.raise(...)`, which is a
	-- tail call, and a tail-called frame reports as C code on line -1. Reading
	-- only the level asked for therefore dropped the prefix from every error
	-- this library raises -- which is all of them.
	for at = level, level + 4 do
		local source, line = debug.info(at, "sl")

		if source == nil then
			break
		end

		if type(source) == "string" and type(line) == "number" and line > 0 then
			return string.format("%s:%d: ", source, line)
		end
	end

	return ""
end

-- `level` means the same thing it means to error(): 1 is the function calling
-- raise, 2 its caller, and so on. One extra frame is added internally because
-- raise itself sits between them.
function Errors.raise(
	source: string,
	code: string,
	message: string,
	level: number?,
	detail: { [string]: any }?
): never
	local depth = if level == nil then 1 else level
	local text = `{positionAt(depth + 1)}{source}: {message}`

	error(
		setmetatable({
			Code = code,
			Message = message,
			Source = source,
			Detail = detail,
			_text = text,
		}, ErrorMeta),
		0
	)
end

-- Errors from the engine, or from any code that predates this module, are plain
-- strings. Both readers below tolerate that and simply report no code.
function Errors.codeOf(err: any): string?
	if type(err) ~= "table" then
		return nil
	end

	local code = (err :: any).Code
	return if type(code) == "string" then code else nil
end

function Errors.sourceOf(err: any): string?
	if type(err) ~= "table" then
		return nil
	end

	local source = (err :: any).Source
	return if type(source) == "string" then source else nil
end

function Errors.detailOf(err: any): { [string]: any }?
	if type(err) ~= "table" then
		return nil
	end

	local detail = (err :: any).Detail
	return if type(detail) == "table" then detail else nil
end

function Errors.is(err: any, code: string): boolean
	return Errors.codeOf(err) == code
end

function Errors.message(err: any): string
	if type(err) == "table" then
		local message = (err :: any).Message

		if type(message) == "string" then
			return message
		end
	end

	return tostring(err)
end

-- Keeps a guarded call from flattening a structured error into prose.

-- debug.traceback stringifies whatever it is handed, so an xpcall handler that
-- returns one destroys the Code at exactly the moment the caller was told to
-- branch on it. Used as the handler, this keeps the two apart: Trace is what a
-- human reads in the diagnostics, Error is what gets rethrown.
export type Captured = {
	Error: any,
	Trace: string,
}

function Errors.capture(err: any): Captured
	return {
		Error = err,
		Trace = debug.traceback(tostring(err), 2),
	}
end

-- Rethrows exactly what was thrown, code intact. The position prefix is already
-- baked into the value, so level 0 is right.
function Errors.rethrow(captured: Captured): never
	error(captured.Error, 0)
end

-- The codes a caller might realistically branch on. Validation codes are
-- programmer errors and are not worth naming here: you fix those, you do not
-- handle them.
export type Code =
	"InvalidArgument"
	| "Destroyed"
	| "Reentrant"
	| "ProbeFreeRotation"
	| "EngineShapecastLimit"
	| "TruncatedResponse"
	| "CallbackContract"
	| "RegistryConflict"
	| "ShapeUnsupported"
	| "RegionTooLarge"
	| "NoConnector"

local CODES = {
	-- The call was malformed. Fix the call.
	InvalidArgument = "InvalidArgument",
	-- The object was already destroyed.
	Destroyed = "Destroyed",
	-- A method was re-entered from inside one of its own callbacks.
	Reentrant = "Reentrant",
	-- A probe-free sweep met a shape rotating in place, which it cannot observe.
	ProbeFreeRotation = "ProbeFreeRotation",
	-- The movement needs more segments than Roblox's shapecast limit allows.
	EngineShapecastLimit = "EngineShapecastLimit",
	-- HitResponse cannot run on a step that did not see everything.
	TruncatedResponse = "TruncatedResponse",
	-- A caller callback returned something the contract does not allow.
	CallbackContract = "CallbackContract",
	-- Two settings describe the same acceptance rule differently.
	RegistryConflict = "RegistryConflict",
	-- The shape is not supported by this query.
	ShapeUnsupported = "ShapeUnsupported",
	-- The voxel region asked for is larger than one read may cover.
	RegionTooLarge = "RegionTooLarge",
	-- A lazy connection could not be established.
	NoConnector = "NoConnector",
}

Errors.Codes = table.freeze(CODES)

table.freeze(Errors)

return Errors
