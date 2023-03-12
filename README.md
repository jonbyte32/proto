# proto
> *[original devforum post](https://devforum.roblox.com/t/proto-efficient-process-scheduling-library/2215440)*

Proto is an efficient process scheduling library that prioritize both speed and memory. 

It utilizes thread pooling to reduce the memory and overhead that comes with creating a new thread each time. Right now there is only support for concurrent processes, but I may extend the library for parallel support in the future. Each process can be managed with the exception of FAST processes. FAST processes are optimized to run as fast as possible with the least amount of overhead. Library functions for scheduling processes prefixed with f are used to create FAST processes.

## performance

![image](https://user-images.githubusercontent.com/67112172/224548423-067efe2d-9490-4b7f-b1f8-cfec87ffcb80.png)


## examples

```lua
local proc = proto.create(function(name)
  print("Hello " .. name)
end)
print(proc.status) -- output: ready
proto.resume(proc, "World") -- output: Hello World
```

```lua
-- spawn will execute immediately

local proc = proto.spawn(function(name)
  print("Hello " .. name)
end, "spawn") -- output: Hello spawn

proto.fspawn(function(name)
  print("Hello " .. name)
end, 1, "fspawn") -- output: Hello fspawn
```

```lua
-- defer will execute at the next resumption point

local proc = proto.defer(function(name)
  print("Hello " .. name)
end, "defer") -- output: Hello defer

proto.fdefer(function(name)
  print("Hello " .. name)
end, 1, "fdefer") -- output: Hello fdefer
```

## current features

- [x] `proto.spawn` & `proto.fspawn`
- [x] `proto.defer` & `proto.fdefer`
- [x] `proto.delay` & `proto.fdelay` 
- [x] `proto.create`
