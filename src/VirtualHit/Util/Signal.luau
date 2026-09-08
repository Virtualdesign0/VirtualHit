--!strict

-- A synchronous, allocation-light replacement for the BindableEvent pairs the
-- public classes used through v0.6. BindableEvent copies every payload across
-- the engine boundary (losing table identity and table.freeze), costs one
-- Instance per signal, and under Deferred SignalBehavior runs handlers after
-- the step that produced them. Hit detection needs the opposite of all three.

-- Handlers are invoked in connection order, in the firing thread, each inside
-- its own xpcall. Isolating handler errors preserves the BindableEvent
-- guarantee that a listener cannot tear down the system that fired the signal.

local Errors = require(script.Parent.Errors)

local Signal = {}

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Signal<T...> = {
	Connect: (self: Signal<T...>, handler: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, handler: (T...) -> ()) -> Connection,
	Wait: (self: Signal<T...>) -> T...,
}

export type Emitter<T...> = Signal<T...> & {
	Fire: (self: Emitter<T...>, T...) -> (),
	DisconnectAll: (self: Emitter<T...>) -> (),
	Destroy: (self: Emitter<T...>) -> (),
	IsDestroyed: (self: Emitter<T...>) -> boolean,
}

-- Aliases for the payload-free case. Every empty type pack in the library goes
-- through these two names, so the spelling lives in one place.
export type VoidSignal = Signal<>
export type VoidEmitter = Emitter<>

-- The signal as its own methods see it. Deliberately not generic: T... belongs
-- to the Signal<T...> facade a caller holds, and duplicating that pack here
-- would give the solver more to infer for no extra safety -- which is what the
-- note further down was guarding against. None of these four fields need the
-- pack, so naming them costs nothing and lets the analyser check the list
-- surgery that walks them.
type SignalImpl = {
	_head: ConnectionImpl?,
	_tail: ConnectionImpl?,
	_waiters: { [thread]: Waiter },
	_destroyed: boolean,
}

type ConnectionImpl = {
	Connected: boolean,
	Disconnect: (self: ConnectionImpl) -> (),
	_signal: SignalImpl?,
	_handler: any,
	_next: ConnectionImpl?,
	_prev: ConnectionImpl?,
	_once: boolean,
}

-- One per outstanding Wait. Resumed is claimed by whoever answers the wait
-- first, so a Fire and a Destroy in the same dispatch cannot both resume it.
type Waiter = {
	Thread: thread,
	Resumed: boolean,
}

local Connection = {}
Connection.__index = Connection

local SignalClass = {}
SignalClass.__index = SignalClass

local function fail(message: string, code: string?): never
	return Errors.raise("VirtualHit signal", code or "InvalidArgument", message, 3)
end

local function traceback(message: any): string
	return debug.traceback(tostring(message), 2)
end

function Connection.Disconnect(self: ConnectionImpl)
	if not self.Connected then
		return
	end

	self.Connected = false
	local signal = self._signal

	if signal == nil then
		return
	end

	-- Unlink in constant time through the neighbours, and never touch this
	-- node's own _next: a fire loop standing on it still needs that link to
	-- reach the rest of the list.
	local previous = self._prev
	local following = self._next

	if previous ~= nil then
		previous._next = following
	else
		signal._head = following
	end

	if following ~= nil then
		following._prev = previous
	else
		signal._tail = previous
	end

	self._signal = nil
	self._handler = nil
end

-- The handler is untyped on purpose: `Signal<T...>` is the contract callers see,
-- and duplicating that pack here would give the solver more to infer for no
-- extra safety. The signal itself is typed -- see SignalImpl.
local function connect(self: SignalImpl, handler: any, once: boolean): Connection
	if self._destroyed then
		fail("cannot connect to a destroyed signal", "Destroyed")
	end

	if type(handler) ~= "function" then
		fail("Connect expects a function")
	end

	local tail: ConnectionImpl? = self._tail
	local connection: ConnectionImpl = setmetatable({
		Connected = true,
		_signal = self,
		_handler = handler,
		_next = nil,
		_prev = tail,
		_once = once,
	}, Connection) :: any

	-- Append through the tail pointer so handlers keep running in connection
	-- order without walking the list. Hit ordering is a documented contract of
	-- this library; listener order should not silently reverse it, and building
	-- a listener set should not be quadratic.
	if tail == nil then
		self._head = connection
	else
		tail._next = connection
	end

	self._tail = connection

	return connection :: any
end

function SignalClass.Connect(self: SignalImpl, handler: any): Connection
	return connect(self, handler, false)
end

function SignalClass.Once(self: SignalImpl, handler: any): Connection
	return connect(self, handler, true)
end

function SignalClass.Wait(self: SignalImpl): ...any
	if self._destroyed then
		fail("cannot Wait on a destroyed signal", "Destroyed")
	end

	local thread = coroutine.running()
	-- One record per wait, claimed before the resume rather than after it.

	-- Reading coroutine.status instead would make the guard depend on the
	-- resume being synchronous and on nothing running between the yield
	-- returning and the line below that deregisters: a Fire and a Destroy in
	-- the same dispatch would each see a suspended thread and each resume it.
	-- A flag says plainly whether this wait has already been answered, and a
	-- thread that errors after being resumed cannot leave its entry behind.
	local waiter: Waiter = {
		Thread = thread,
		Resumed = false,
	}

	local connection = connect(self, function(...)
		if waiter.Resumed then
			return
		end

		waiter.Resumed = true
		self._waiters[thread] = nil

		if coroutine.status(thread) == "suspended" then
			task.spawn(thread, ...)
		end
	end, true)

	-- Registered so Destroy can release a thread that would otherwise stay
	-- suspended for the rest of the session waiting on a signal that will
	-- never fire again.
	self._waiters[thread] = waiter
	local results = table.pack(coroutine.yield())
	self._waiters[thread] = nil
	connection:Disconnect()

	return table.unpack(results, 1, results.n)
end

function SignalClass.Fire(self: SignalImpl, ...: any)
	if self._destroyed then
		return
	end

	local node: ConnectionImpl? = self._head

	while node ~= nil do
		local current = node
		-- Read the successor before invoking, so a handler that disconnects
		-- itself or a later listener cannot strand this traversal.
		node = current._next

		if current.Connected then
			local handler = current._handler
			local once = current._once

			if once then
				Connection.Disconnect(current)
			end

			local success, message = xpcall(handler, traceback, ...)

			if not success then
				warn(`VirtualHit signal handler errored:\n{tostring(message)}`)
			end
		end
	end
end

function SignalClass.DisconnectAll(self: SignalImpl)
	local node: ConnectionImpl? = self._head
	self._head = nil
	self._tail = nil

	while node ~= nil do
		local current = node
		node = current._next
		current.Connected = false
		current._signal = nil
		current._handler = nil
	end
end

-- A destroyed signal resumes anything blocked in Wait with no values rather
-- than leaving those threads suspended forever. A caller that yielded on a
-- signal that has since been torn down sees nil, not a leak.
function SignalClass.Destroy(self: SignalImpl)
	if self._destroyed then
		return
	end

	self._destroyed = true
	SignalClass.DisconnectAll(self)

	local waiters = self._waiters
	self._waiters = {}

	for thread, waiter in waiters do
		if waiter.Resumed then
			continue
		end

		waiter.Resumed = true

		if coroutine.status(thread) == "suspended" then
			task.spawn(thread)
		end
	end
end

function SignalClass.IsDestroyed(self: SignalImpl): boolean
	return self._destroyed
end

function Signal.new<T...>(): Emitter<T...>
	return setmetatable({
		_head = nil,
		_tail = nil,
		_waiters = {},
		_destroyed = false,
	}, SignalClass) :: any
end

table.freeze(Signal)

return Signal
