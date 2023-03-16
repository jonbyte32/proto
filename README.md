# Description
Proto is an efficient scheduling library for the Roblox engine that prioritizes both speed and memory. It implements thread pooling to reduce the speed and memory overhead that comes when creating a completely new thread for each process. Right now there is only support for concurrent processes, but I may add support for parallel scheduling in the future. The API partially mocks the Luau task library, but it is not meant to be a complete replacement for the task library.

# Documentation
* Documentation will exist here and on the DevForum post
* In the future I will dedicate an API page for it on the website of a brand I am creating (if still relevant)

Link: https://devforum.roblox.com/t/proto-efficient-process-scheduling-library/2215440

# Examples
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
```lua
-- delay will execute on the next heartbeat after the specified amount of seconds

local proc = proto.delay(2, function(name)
  print("Hello " .. name)
end, "delay") -- output: Hello delay (2 seconds after calling)

proto.fdelay(2, function(name)
  print("Hello " .. name)
end, 1, "fdelay") -- output: Hello fdelay (2 seconds after calling)
```
