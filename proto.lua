--// Proto.luau
--// jonbyte
--// An efficient process scheduling library.

--!optimize 2
--!nocheck

-- typedefs
type Function = (...any) -> (...any)
type Process = { exec: Function, argc: number, argv: {}, status: number, rets: {}?, awaits: {}, thread: thread? }

-- global
local rs = game:GetService("RunService")
local heartbeat = rs.Heartbeat
local is_server = rs:IsServer()
local start_index = 5 - (is_server and 2 or 0)
local S0, S1, S2, S3 = "ready", "running", "done", "cancelled"
local now = time()

--?? used as a unique reference identifier
--?? to ensure processor function cannot be resumed by external system
local REF_OK = table.freeze({})

--?? is library subsytems running
local lib_active = false

-- caches
local threads = nil -- allocated ready threads
local fthreads = nil -- allocated ready fast threads
local defers = nil -- deferred processes
local fdefers = nil -- deferred fast processes
local scheds = nil -- delayed processes
local fscheds = nil -- delayed fast processes
local running = nil -- all running processes

-- debug counters
local ttotal = 0 -- total allocated threads
local ftotal = 0 -- total fast allocated threads

-- scheduling data
local update_job = nil
local points = nil
if (is_server) then
	points = table.freeze({ rs.PreAnimation, rs.Stepped, rs.PreSimulation, heartbeat, rs.PostSimulation })
else
	points = table.freeze({ rs.RenderStepped, rs.PreRender, rs.PreAnimation, rs.Stepped, rs.PreSimulation, heartbeat, rs.PostSimulation })
end
local pindex, psize = start_index, #points

-- fast processor
local fast = function(ok: {}, exec: Function, argc: number, argv: {}): nil
	ftotal += 1 -- debug counter
	local thread = coroutine.running()
	while (true) do
		if (ok == REF_OK) then
			running[thread] = true
			ok = if argc == 0 then exec() else exec(table.unpack(argv, 1, argc))
			table.insert(fthreads, thread)
			running[thread] = nil
		end
		ok, exec, argc, argv = coroutine.yield()
	end
	return nil
end

-- default processor
local main = function(ok: {}, proc: Process): nil
	ttotal += 1 -- debug counter
	local thread = coroutine.running()
	local rets, rets_n = nil, nil
	while (true) do
		if (ok == REF_OK) then
			-- load
			running[thread] = true
			proc.status = S1
			proc.thread = thread

			-- execute process
			rets = if proc.argc == 0 then { proc.exec() } else { proc.exec(table.unpack(proc.argv, 1, proc.argc)) }

			-- resume awaits
			if (#proc.awaits > 0) then
				rets_n = table.maxn(rets)
				for _, th in proc.awaits do
					coroutine.resume(th, table.unpack(rets, 1, rets_n))
				end
				table.clear(proc.awaits)
			end

			-- done
			running[thread] = nil
			proc.status = S2
			proc.thread = nil :: any
			proc.rets = rets
			table.insert(threads, thread)
		end
		ok, proc = coroutine.yield()
	end
	return nil
end

-- internal update loop
local update = function(): nil
	local proc, dt = nil, nil
	while (lib_active) do

		-- await next resumption
		dt = points[pindex]:Wait()
		if (not lib_active) then
			return nil
		end

		-- resume fast deferred processes
		for i = 1, #fdefers do
			proc = fdefers[i]
			coroutine.resume(table.remove(fthreads) or coroutine.create(fast), REF_OK, proc[1], proc[2], proc[3])
			fdefers[i] = nil
		end

		-- resume deferred processes
		for i = 1, #defers do
			proc = defers[i]
			if (proc.status == S0) then
				coroutine.resume(table.remove(threads) or coroutine.create(main), REF_OK, proc)
			end
			defers[i] = nil
		end

		if (points[pindex] == heartbeat) then
			now = time()

			-- resume fast scheduled processes
			for clock, procs in fscheds do
				if (now >= clock) then
					for i = 1, #procs do
						proc = procs[i]
						coroutine.resume(table.remove(fthreads) or coroutine.create(fast), REF_OK, proc[1], proc[2], proc[3])
					end
					fscheds[clock] = nil
				end
			end
			-- resume scheduled processes
			for clock, procs in scheds do
				if (now >= clock) then
					for i = 1, #procs do
						proc = procs[i]
						if (proc.status == S0) then
							coroutine.resume(table.remove(threads) or coroutine.create(main), REF_OK, proc)
						end
					end
					scheds[clock] = nil
				end
			end
		end

		pindex = pindex < psize and pindex + 1 or 1
	end
	return nil
end


local proto = {}

--[=[
	Allocate a new process which can be later run.
	Returns the new process.
--]=]
function proto.create(exec: Function): Process
	return { exec = exec, argc = 0, argv = threads, status = S0, rets = nil, awaits = { nil }, thread = nil }
end

--[=[
	Starts or resume the execution of a process.
	Returns the passed process.
--]=]
function proto.resume(proc: Process, ...: any): Process
	if (proc.status == S0) then -- start
		coroutine.resume(table.remove(threads) or coroutine.create(main), threads, proc)
	elseif (proc.status == S1) then -- resume
		coroutine.resume(proc.thread, ...)
	else
		warn(`[proto.spawn_proc]: cannot start or resume a terminated process`)
		return nil :: any
	end
	return proc
end

--[=[
	Allocate and immediately execute a new process.
	Returns the new process.
--]=]
function proto.spawn(exec: Function, ...: any): Process
	local proc = { exec = exec, argc = select('#', ...), argv = { ... }, status = S0, rets = nil, awaits = { nil }, thread = nil }
	coroutine.resume(table.remove(threads) or coroutine.create(main), REF_OK, proc)
	return proc
end

--[=[
	Allocate and immediately execute a new FAST process
	Does not support process management and therefore returns nothing.
--]=]
function proto.fspawn(exec: Function, argc: number?, ...: any): nil
	coroutine.resume(table.remove(fthreads) or coroutine.create(fast), REF_OK, exec, argc or 0, { ... })
	return nil
end

--[=[
	Allocate and schedule a new process to execute at the next resumption point.
	Returns the new process.
--]=]
function proto.defer(exec: Function | Process, ...: any): Process
	local proc = { exec = exec, argc = select('#', ...), argv = { ... }, status = S0, rets = nil, awaits = { nil }, thread = nil }
	table.insert(defers, proc)
	return proc
end

--[=[
	Allocate and schedule a new FAST process to execute at the next resumption point.
	Does not support process management and therefore returns nothing.
--]=]
function proto.fdefer(exec: Function, argc: number?, ...: any): nil
	table.insert(fdefers, { exec, argc or 0, { ... } })
	return nil
end

--[=[
	Allocate and schedule a new process to execute on the next heartbeat
		after the specified amount of seconds.
	Returns the new process.
--]=]
function proto.delay(clock: number, exec: Function, ...: any): Process
	clock = now + clock
	scheds[clock] = scheds[clock] or { nil }
	local proc = { exec = exec, argc = select('#', ...), argv = { ... }, status = S0, rets = nil, awaits = { nil }, thread = nil }
	table.insert(scheds[clock], proc)
	return proc
end

--[=[
	Allocate and schedule a new FAST process to execute on the next heartbeat
		after the specified amount of seconds.
	Does not support process management and therefore returns nothing.
--]=]
function proto.fdelay(clock: number, exec: Function, argc: number?, ...: any): nil
	clock = now + clock
	fscheds[clock] = fscheds[clock] or { nil }
	table.insert(fscheds[clock], { exec, argc or 0, { ... } })
	return nil
end

--[=[
	Yield current thread until process has finished or an optional timeout occurs.
	Returns
		[1] boolean : true if process finished normally
					: false if cancelled or timeout happens
		[2] ... : the return values of the process or nil
--]=]
function proto.await(proc: Process, timeout: number?): (boolean, ...any)
	local status = proc.status
	if (status == S0 or status == S1) then
		local thread = coroutine.running()
		if (timeout) then
			proto.fdelay(timeout, coroutine.resume, 3, thread, false, nil)
		end
		table.insert(proc.awaits, thread)
		return coroutine.yield()
	else
		if (proc.status == S2) then
			return true, table.unpack(proc.rets, 1, table.maxn(proc.rets))
		else
			return false, nil
		end
	end
end

function proto.get(proc: Process, timeout: number?)
	return select(2, proto.await(proc, timeout))
end

--[=[
	Prevents or stops the execution of a process.
--]=]
function proto.cancel(proc: Process): nil
	if (proc.status == S1) then
		coroutine.close(proc.thread)
		ttotal -= 1
		proc.status = S3
		running[proc.thread] = nil
		proc.thread = nil
	elseif (proc.status == S0) then
		proc.status = S3
	else
		warn("[proto.cancel]: cannot cancel a terminated process")
	end
	return nil
end

--[=[
	Wraps the execution of a function as a process.
	Returns the generator function.
--]=]
function proto.wrap(exec: Function): (...any) -> Process
	return function(...: any)
		return proto.spawn(exec, ...)
	end
end

--[=[
	Wraps the execution of a sequence of functions as a single process.
	Returns the generator function.
--]=]
function proto.chain(data: {Function}): (...any) -> Process
	return function(...: any)
		return proto.spawn(function(...)
			local argc, argv = select('#', ...), { ... }
			for _, exec in data do
				argv = { exec(table.unpack(argv, 1, argc)) }
				argc = table.maxn(argv)
			end
		end, ...)
	end
end

--[=[
	Yields current thread until the next resumption point.
	Returns the delta time between calling and resumption.
--]=]
local resume_yield = function(thread: thread, clock: number)
	return coroutine.resume(thread, os.clock() - clock)
end

function proto.step(): number
	table.insert(fdefers, { resume_yield, 2, { coroutine.running(), os.clock() } })
	return coroutine.yield()
end

-- # start/resume the internal update loop
function proto.__lib_start(alloc: number?): typeof(proto)
	if (lib_active) then
		warn("cannot start; proto is already active")
		return proto
	end
	lib_active = true
	
	-- initial allocation
	local alloc = alloc or 0
	threads = table.create(alloc)
	fthreads = table.create(alloc)
	defers = table.create(alloc)
	fdefers = table.create(alloc)
	scheds = {}
	fscheds = {}
	running = {}

	local thread = nil
	for _ = 1, alloc do
		-- normal threads
		thread = coroutine.create(main)
		coroutine.resume(thread)
		table.insert(threads, thread)
		-- fast threads
		thread = coroutine.create(fast)
		coroutine.resume(thread)
		table.insert(fthreads, thread)
	end
	ttotal = alloc
	ftotal = alloc

	-- internal update loop
	update_job = coroutine.create(update)
	coroutine.resume(update_job)

	return proto
end

-- # stop the internal update loop and clear all jobs
function proto.__lib_close(): typeof(proto)
	if (not lib_active) then
		warn("cannot close; proto is not active")
		return proto
	end
	lib_active = false
	
	-- cleanup running processes
	for thread, proc in running do
		coroutine.close(thread)
		if (type(proc) == "table") then
			proc.status = S3
			proc.thread = nil
		end
	end
	
	-- cleanup ready threads
	for _, thread in threads do
		coroutine.close(thread)
	end
	for _, thread in fthreads do
		coroutine.close(thread)
	end
	
	-- wipe memory
	threads = nil
	ttotal = 0
	fthreads = nil
	ftotal = 0
	defers = nil
	fdefers = nil
	scheds = nil
	fscheds = nil
	running = nil
	
	pindex = start_index -- will start on heartbeat
	return proto
end

function proto.__debug_log(): nil
	warn()
	warn("-----------------------------------------------")
	warn(`allocated threads : {ttotal}`)
	warn(`ready threads : {#threads}`)
	warn(`allocated fast threads : {ftotal}`)
	warn(`ready fast threads : {#fthreads}`)
	warn()
	local count = 0
	for _ in running do count += 1 end
	warn(`running proceses : {count - (ftotal - #fthreads)}`)
	warn(`running fast processes : {ftotal - #fthreads}`)
	warn()
	warn(`deferred processes : {#defers}`)
	warn(`deferred fast processes : {#fdefers}`)
	warn()
	count = 0
	for _, v in scheds do count += #v end
	warn(`scheduled processes : {count}`)
	count = 0
	for _, v in fscheds do count += #v end
	warn(`scheduled fast processes : {#fscheds}`)
	warn("-----------------------------------------------")
	warn()
	return nil
end

return proto.__lib_start(16)
