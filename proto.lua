-- proto :: scheduling library
-- jonbyte, 2023

--!nolint BuiltinGlobalWrite

local proto = {}
local DEBUG = true

-- typedefs

type Callback = (...any) -> (...any)
type Factory<T...> = (...any) -> ((...any) -> (T...))
type ArgPack = { [number]: any, n: number }

export type Proto = typeof(proto)
export type FProcess = {
    _exec : Callback?,
    _args : ArgPack?,
    _fast : boolean?
}
export type Process = {
    _status : "ready" | "active" | "done" | "cancelled",
    _thread : thread?,
    _data : ArgPack?,
    _awaits : {},
    _next : AnyProcess?,
    await : (self: AnyProcess, timeout: number?) -> (boolean, ...any),
    values : (self: AnyProcess) -> (...any),
    push : (self: AnyProcess, exec: Callback) -> (Process),
    cancel : (self: AnyProcess) -> (nil)
} | FProcess
export type Parent = {
    _procs : {Child},
    update : (self: Parent, child: Child) -> (nil),
    [any] : any
} & Process
export type Child = {
    _parent : Parent
} & Process
export type AnyProcess = Process & Parent & Child & FProcess

-- init

-- probably replace this with 'debug'/'release' feature
if (DEBUG == false) then
    warn = function(...: any)end
end

-- config

local REF_OK = {}
local REF_PROCESS= {}
local REF_PARENT = {}
local REF_CHILD = {}

local STATUS_READY = "ready"
local STATUS_ACTIVE = "active"
local STATUS_DONE = "done"
local STATUS_CANCELLED = "cancelled"

-- data

local rs = game:GetService("RunService")
local heartbeat = rs.Heartbeat
local clock = time()

local threads = {}
local use = nil

local fthreads = {}
local fuse = nil

local defers = {} :: { AnyProcess }
local delays = {} :: { AnyProcess }
local dflag = false

-- processors

local run = function(thread: thread, ok: {}, proc: AnyProcess, exec: Callback, ...: any): nil
    if (ok == REF_OK) then
        use = nil
        
        -- init
        proc._thread = thread
        proc._status = STATUS_ACTIVE
        
        -- execute
        local data = table.pack(exec(...))
        proc._data = data
        
        -- resume awaiting threads
        local awaits = proc._awaits
        for i = 1, #awaits do
            task.defer(awaits[i], true)
        end
        
        -- defer chained process
        if (proc._next) then
            proc._next._args = if data.n == 0 then nil else data
            table.insert(defers, proc._next)
        end
        
        -- update parent process
        if (proc._parent) then
            proc._parent:update(proc)
        end
        
        -- cleanup
        proc._thread = nil
        proc._status = STATUS_DONE
        
        use = (use and table.insert(threads, thread) or use) or thread
    end
    return nil
end

local main = function(...: any): nil
    local thread = coroutine.running()
    run(thread, ...)
    while true do
        run(thread, coroutine.yield())
    end
    return nil
end

local fast = function(ok: {}, exec: Callback, args: ArgPack?): nil
    local thread = coroutine.running()
    while true do
        if (ok == REF_OK) then
            fuse = nil
            if (not args) then
                exec()
            else
                exec(table.unpack(args, 1, args.n))
            end
            fuse = (fuse and table.insert(fthreads, thread) or fuse) or thread
        end
        ok, exec, args = coroutine.yield()
    end
end

-- methods

local await_timeout = function(cache: {thread}, thread: thread): nil
    local index = table.find(cache, thread)
    if (index) then
        table.remove(cache, index)
        coroutine.resume(thread, nil)
    end
    return nil
end

local function await(self: AnyProcess, timeout: number?): (string?, ...any)
    local status = self._status
    local thread = coroutine.running()
    local ok = nil
    if (status == STATUS_READY or status == STATUS_ACTIVE) then
        table.insert(self._awaits, thread)
        local job = nil
        if (timeout) then
            job = proto.fdelay(timeout, await_timeout, self._awaits, thread)
        end
        ok = coroutine.yield()
        if (ok == nil) then
            return nil -- timed out & timeout process already ran so no need to cancel
        end
        if (job) then
            job._status = STATUS_CANCELLED -- cancel timeout
        end
    end
    if (ok or status == STATUS_DONE) then
        return STATUS_DONE, table.unpack(self._data, 1, self._data.n)
    else
        return STATUS_CANCELLED, nil
    end
end
proto.await = await

local function values(self: AnyProcess, timeout: number?): (...any)
    return select(2, self:await(timeout))
end
proto.values = values

local function status(self: AnyProcess | thread): string?
    if (type(self) == "table") then
        return self._status
    elseif (type(self) == "thread") then
        return coroutine.status(self)
    end
    warn(`arg1 expected type 'Process | thread' got type '{typeof(self)}'`) 
    return nil
end
proto.status = status

local function cancel(self: AnyProcess | thread): nil
    if (type(self) == "table") then
        local stat = self._status
        if (stat == STATUS_READY or stat == STATUS_ACTIVE) then
            -- resume awaits
            local awaits = self._awaits
            for i = 1, #awaits do
                task.defer(awaits[i], false)
            end
            -- cancel chain
            if (self._next) then
                proto.cancel(self._next)
            end
            if (stat == STATUS_ACTIVE) then
                -- close thread
                coroutine.close(self._thread)
            end
        else
            warn(`cannot cancel a process with status '{stat}'`)
            return nil
        end
        self._status = STATUS_CANCELLED
    elseif (type(self) == "thread") then
        coroutine.close(self)
    else
        warn(`arg1 expected type 'Process | thread' got type '{typeof(self)}'`) 
    end
    return nil
end
proto.cancel = cancel

local function push(self: AnyProcess, exec: Callback): Process?
    local stat = self._status
    if (stat == STATUS_READY or stat == STATUS_ACTIVE) then
        self._next = {
            _status = STATUS_READY, _thread = nil, _data = nil, _awaits = {}, _next = nil, _exec = exec,
            await = await, values = values, push = push, status = status, cancel = cancel
        }
        return self._next
    end
    if (stat == STATUS_DONE) then
        return proto.spawn(exec, table.unpack(self._data, 1, self._data.n)) :: Process
    end
    if (stat == STATUS_CANCELLED) then
        return { _status = STATUS_CANCELLED }
    end
    return nil
end
proto.push = push

-- spawners

function proto.create(exec: Callback): Process
    return {
        _status = STATUS_READY, _thread = nil, _data = nil, _awaits = {}, _next = nil, _exec = exec,
        await = await, values = values, push = push, status = status, cancel = cancel
    }
end

function proto.spawn(exec: Callback | AnyProcess | thread, ...: any): (Process | thread)
    if (type(exec) == "function") then
        -- spawn a new process
        local proc = {
            _status = STATUS_READY, _thread = nil, _data = nil, _awaits = {}, _next = nil,
            await = await, values = values, push = push, status = status, cancel = cancel
        }
        coroutine.resume(use or table.remove(threads) or coroutine.create(main), REF_OK, proc, exec, ...)
        return proc :: Process
    end
    if (type(exec) == "table") then
        -- resume an existing process
        if (exec._status == STATUS_ACTIVE) then
            -- if active we know it is yielding at this point
            coroutine.resume(exec._thread :: thread, ...)
        elseif (exec._status == STATUS_READY) then
            coroutine.resume(use or table.remove(threads) or coroutine.create(main), REF_OK, exec, exec._exec, ...)
        else
            warn(`cannot spawn process with status '{exec._status}'`)
        end
        return exec :: Process
    end
    if (type(exec) == "thread") then
        -- resume an existing raw thread
        local status = coroutine.status(exec)
        if (status == "suspended") then
            coroutine.resume(exec :: thread, ...)
        else
            warn(`cannot resume thread with status '{status}'`)
        end
        return exec :: thread
    end
    warn(`arg1 expected type 'Function | Process | thread' got type '{typeof(exec)}'`)
    return exec
end

function proto.fspawn(exec: Callback, ...: any): thread
    local argc = select('#', ...)
    local thread = fuse or table.remove(fthreads) or coroutine.create(fast)
    coroutine.resume(thread, REF_OK, exec, if argc == 0 then nil else { n = argc, ... })
    return thread
end

function proto.defer(exec: Callback | AnyProcess | thread, ...: any): (Process | thread)?
    if (type(exec) == "function") then
        -- defer a new process
        local proc = {
            _status = STATUS_READY, _thread = nil, _data = nil, _awaits = {}, _next = nil,
            _exec = exec, _args = select('#', ...) > 0 and table.pack(...) or nil, _fast = false,
            await = await, values = values, push = push, status = status, cancel = cancel
        }
        table.insert(defers, proc)
        return proc
    elseif (type(exec) == "table") then
        -- defer resumption of an existing process
        --  using 'proto.spawn' as executor to account for
        -- different statuses on resumption
        if (exec._status == STATUS_ACTIVE) then
            return proto.defer(proto.spawn, exec._thread, ...)
        elseif (exec._status == STATUS_READY) then
            return proto.defer(proto.spawn, exec, ...)
        else
            warn(`cannot defer process with status '{exec._status}'`)
            return nil
        end
    elseif (type(exec) == "thread") then
        -- defer resumption of an existing raw thread
        return proto.defer(coroutine.resume, exec, ...)
    end
    warn(`arg1 expected type 'Function | Process | thread' got type '{typeof(exec)}'`)
    return nil
end

function proto.fdefer(exec: Callback, ...: any): Process
    -- defer a new fast process
    local proc = {
        _status = STATUS_READY, _exec = exec, _args = select('#', ...) > 0 and table.pack(...) or nil, _fast = true
    }
    table.insert(defers, proc)
    return proc :: any
end

function proto.delay(seconds: number, exec: Callback | AnyProcess | thread, ...: any): (Process | thread)?
    if (type(exec) == "function") then
        -- delay a new process
        local proc = {
            _status = STATUS_READY, _thread = nil, _data = nil, _awaits = {}, _next = nil,
            _exec = exec, _args = select('#', ...) > 0 and table.pack(...) or nil, _fast = false, _time = clock + seconds + 1e-3,
            await = await, values = values, push = push, status = status, cancel = cancel
        }
        if (delays[1] and delays[#delays]._time > clock + seconds + 1e-3) then
            dflag = true -- re-sort needed
        end
        table.insert(delays, proc)
        return proc
    elseif (type(exec) == "table") then
        -- delay an existing process
        return proto.delay(seconds, proto.spawn, exec._thread, ...)
    elseif (type(exec) == "thread") then
        -- delay an existing raw thread
        return proto.delay(seconds, proto.spawn, exec, ...)
    end
    warn(`arg1 expected type 'Function | Process | thread' got type '{typeof(exec)}'`)
    return nil
end

function proto.fdelay(seconds: number, exec: Callback, ...: any): Process
    -- delay a new fast process
    if (delays[1] and delays[#delays]._time > clock + seconds + 1e-3) then
        dflag = true -- re-sort needed
    end
    local proc = {
        _status = STATUS_READY, _exec = exec, _args = select('#', ...) > 0 and table.pack(...) or nil, _fast = true, _time = clock + seconds + 1e-3
    }
    table.insert(delays, proc)
    return proc :: any
end

function proto.parent(exec: Callback, update: Callback, data: {}?, execs: {Callback}, ...: any): Parent
    local proc = {
        _procs = {}, _status = STATUS_READY, _thread = nil, _data = nil, _awaits = {}, _next = nil,
        update = update, await = await, values = values, push = push, status = status, cancel = cancel
    }
    if (data) then
        for k, v in data do proc[k] = v end
    end
    coroutine.resume(use or table.remove(threads) or coroutine.create(main), REF_OK, proc, exec, proc)
    for i = 1, #execs do
        if (proc._status == STATUS_ACTIVE) then
            proc._procs[i] = proto.child(proc, execs[i], ...)
        end
    end
    return proc
end

function proto.child(parent: Parent, exec: Callback, ...: any): Child
    local proc = {
        _parent = parent, _status = STATUS_READY, _thread = nil, _data = nil, _awaits = {}, _next = nil,
        await = await, values = values, push = push, status = status, cancel = cancel
    }
    coroutine.resume(use or table.remove(threads) or coroutine.create(main), REF_OK, proc, exec, ...)
    return proc
end

-- factories

function proto.wrap(exec: Callback, fast: boolean?): Factory<Process>
    return function(...: any)
        return proto.spawn(exec, ...)
    end
end

local chain = function(execs: {Callback}, ...: any): (...any)
    local values = table.pack(...)
    for i = 1, #execs do
        values = table.pack(execs[i](table.unpack(values, 1, values.n)))
    end
    return table.unpack(values, 1, values.n)
end

function proto.chain(execs: {Callback}): Factory<Process>
    return function(...: any)
        return proto.spawn(chain, execs, ...)
    end
end

local retry = function(count: number, delay: number?, exec: Callback, ...): (...any)
    local values = table.pack(...)
    for i = 1, count do
        values = table.pack(exec(table.unpack(values, 1, values.n)))
        if (values[1]) then
            break
        end
        if (delay) then
            task.wait(delay)
        end
    end
    return table.unpack(values, 1, values.n)
end

function proto.retry(count: number, delay: number?, exec: Callback): Factory<Process>
    return function(...: any)
        return proto.spawn(retry, count, delay, exec, ...)
    end
end

-- prefixed by _ to avoid overwriting global 'pcall'
local _pcall = function(exec: Callback, err: Callback?, ...: any): (...any)
    local values = table.pack(pcall(exec(...)))
    if (not values[1] and err) then
        return err(values[2])
    end
    return table.unpack(values, 1, values.n)
end

function proto.pcall(exec: Callback, err: Callback?): Factory<Process>
    return function(...: any)
        return proto.spawn(_pcall, err, ...)
    end
end

local all_exec = function(self: Parent): (...any)
    if (self.count ~= self.target) then
        return coroutine.yield()
    end
end

local all_update = function(self: Parent, child: Child): nil
    self.count += 1
    if (self.count == self.target) then
        for _, proc in self._procs do
            if (proc ~= child and proc._status == STATUS_ACTIVE) then
                coroutine.close(proc._thread)
            end
        end
        coroutine.resume(self._thread)
        self._status = STATUS_DONE
    end
    return nil
end

function proto.all(execs: {Callback}, count: number?): Factory<Parent>
    return function(...: any)
        return proto.parent(all_exec, all_update, { count = 0, target = math.clamp(count or #execs, 0, #execs) }, execs, ...)
    end
end

-- utilities

-- experimental
function proto.reset(proc: AnyProcess): nil
    proc._status = STATUS_READY
    return nil
end

function proto.step(frames: number?): number
    local dt = 0
    for i = 1, frames or 1 do
        dt += heartbeat:Wait()
    end
    return dt
end

function proto.kill(): nil
    task.defer(coroutine.close, coroutine.running())
    coroutine.yield()
    return nil
end

-- scheduling

do
    -- load resumption points
    local steps = rs:IsServer()
        and table.freeze({ rs.PreAnimation, rs.Stepped, rs.PreSimulation,
            rs.Heartbeat, rs.PostSimulation })
        or  table.freeze({ rs.RenderStepped, rs.PreRender, rs.PreAnimation,
            rs.Stepped, rs.PreSimulation, rs.Heartbeat, rs.PostSimulation })
    local hb = (table.find(steps, heartbeat) :: number) - 1
    local index = hb
    local size = #steps

    local sort_delays = function(p1: AnyProcess, p2: AnyProcess)
        return p1._time < p2._time
    end

    -- initialize scheduler
    local update = function(dt)
        debug.profilebegin("PROTO-UPDATE")
        local proc = nil
        local todo = defers
        debug.profilebegin("DELAY")
        if (index == hb) then
            clock = time()
            if (delays[1]) then
                -- load delayed processes to deferred
                if (dflag) then
                    dflag = false
                    table.sort(delays, sort_delays)
                end
                for i = 1, #delays do
                    proc = delays[i]
                    if (clock >= proc._time) then
                        table.insert(todo, proc)
                        delays[i] = nil
                    end
                end
            end
        end
        debug.profileend()
        debug.profilebegin("DEFER")
        -- execute deferred processes
        if (defers[1]) then
            defers = {}
            for i = 1, #todo do
                proc = todo[i]
                if (proc._status == STATUS_READY) then
                    if (proc._fast) then
                        coroutine.resume(
                            fuse or table.remove(fthreads) or coroutine.create(fast),
                            REF_OK, proc._exec, proc._args
                        )
                    else
                        if (proc._args) then
                            coroutine.resume(
                                use or table.remove(threads) or coroutine.create(main),
                                REF_OK, proc, proc._exec, table.unpack(proc._args, 1, proc._args.n)
                            )
                        else
                            coroutine.resume(
                                use or table.remove(threads) or coroutine.create(main),
                                REF_OK, proc, proc._exec, nil
                            )
                        end
                    end
                end
                todo[i] = nil
            end
        end
        debug.profileend()
        debug.profileend()
        return nil
    end

    task.spawn(function()
        while true do
            update(steps[index + 1]:Wait())
            index = (index + 1) % size
        end
        return nil
    end)
end

-- coroutine compat
-- local coroutine = proto

proto.yield = coroutine.yield
proto.isyieldable = coroutine.isyieldable
proto.running = coroutine.running
proto.resume = proto.spawn
proto.close = proto.cancel

-- tasklib compat
-- local task = proto

proto.wait = task.wait
proto.synchronize = task.synchronize
proto.desynchronzie = task.desynchronize

return proto
