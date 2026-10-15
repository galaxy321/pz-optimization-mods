# Code walkthrough: LGEP Chunk Load Patch 1.2

The patch is two Lua files plus `mod.info`:

```
LGEPChunkLoadPatch/
  common/                         (B42 wants it to exist; empty apart from a readme)
  42/mod.info                     (id, name, require=\LGExtendedPlumbing)
  42/media/lua/shared/LGEPChunkLoadPatch/LGEPChunkLoadPatch_Capture.lua
  42/media/lua/server/LGEPChunkLoadPatch/LGEPChunkLoadPatch.lua
```

The two halves live in different folders on purpose. `shared/` loads when the game starts, and `server/` loads when a world starts. So the shared file is guaranteed to run before the plumbing mod's server file, and that ordering is the whole trick.

---

## Part 1: catching the handler (`shared/..._Capture.lua`)

**The problem.** The plumbing mod registers its scanner like this (LGEPPlumbing.lua ~655):

```lua
Events.LoadGridsquare.Add(function(square)
    local ok, err = pcall(notice, square)
    ...
end)
```

That function has no name, and `notice` is `local`. Once it's registered, there's no way to remove it, because `Events.LoadGridsquare.Remove(fn)` needs the exact same function value and we never get to see it.

**The trick: stand at the door.** `Events.LoadGridsquare` is an ordinary Lua table, and `Add` is just a field in it. So before the plumbing mod runs, we swap `Add` for our own function:

```lua
local originalAdd = event.Add
event.Add = function(fn)
    if looksLikePlumbingHandler() then
        CLP.captured = fn      -- keep it, don't register it
        return
    end
    return originalAdd(fn)     -- everybody else registers normally
end
```

Every mod that calls `Events.LoadGridsquare.Add` now goes through us. We pass everyone through except the plumbing mod's handler, which we keep in `LGEP_CLP.captured`. That's a global table, so the server file can reach it.

**How we know which call is the plumbing mod's:**

```lua
local function looksLikePlumbingHandler()
    local EP = LGEP
    return CLP.captured == nil
        and EP ~= nil
        and EP.eachCollector ~= nil   -- defined at LGEPPlumbing ~385
        and EP.forgetColumns == nil   -- defined at LGEPPlumbing ~1165
end
```

A Lua file runs top to bottom without anything else running in between. The plumbing file defines `eachCollector`, then registers the handler (line ~655), then defines `forgetColumns`. So the only `LoadGridsquare.Add` that happens while the first exists and the second doesn't is that file's. If an update moves these lines, nothing gets captured, the handler registers normally, and the patch just stands down.

---

## Part 2: the server file

It runs top to bottom once when the world starts, setting things up. After that, everything happens in three event handlers at the bottom: `LoadChunk`, `OnTick` and `OnInitGlobalModData`.

### 2a. Setup and settings (top of file)

```lua
if isClient() then return end      -- the plumbing mod does no work on MP clients either
local BUDGET_MS = 2                -- max ms of scanning per tick
local MAX_LEVELS_PER_TICK = 8      -- safety cap if the clock is coarse
local LAZY = true                  -- false = scan everything (1.0 behaviour)
local INDEX_EVERY_MS = 5000        -- how often to rebuild the "hot" map
```

`chunkKey(cx, cy)` turns chunk coordinates into one number, which is cheap to use as a table key. Chunk coordinates are tile coordinates divided by 8.

### 2b. Which chunks are hot (`rebuildIndex` and helpers)

`hot` is a set: `hot[chunkKey] = true` means "scan this chunk fully". It's built from three sources:

```lua
-- 1. every mirror the save has, from the plumbing mod's own saved list
local store = ModData.getOrCreate(EP.PIPE_STORE)       -- "LGExtendedPlumbing"
for key in pairs(store.mirrors) do ... heatAround(key, x, y, z, margin) end

-- 2. every barrel plumbed through the menu, from our own saved list
for key in pairs(plumbed) do ... heatAround("p:" .. key, x, y, z, margin) end

-- 3. every pipe piece, plus one chunk around it
pipes(EP.floorPipes); pipes(EP.wallPipes)
```

`ModData` is PZ's per-world save storage. Anything you put in `ModData.getOrCreate("name")` is saved with the world and comes back next session. Addresses are stored as `"x,y,z"` strings, which `parseKey` splits back into numbers with a pattern match.

`heatAround` decides how far one address reaches:

```lua
boxChunks(list, x, y, x, y, margin)       -- chunks within Reach of the point
local b = buildingBox(x, y, z)            -- the map building it's in, if any
if b then boxChunks(list, b.minX, b.minY, b.maxX, b.maxY, 1) end
```

- **The building box:** the plumbing mod pools water per building, so a mirror on the ground floor and a barrel on the roof belong together. `EP.mapBuildingAt` answers from the map's building index even when that area isn't loaded.
- **The Reach margin:** player-built bases have no map building. There the plumbing mod uses its Reach setting (12 tiles by default), so we heat `ceil(12 / 8) = 2` chunks around the point.
- **`addressMemo`:** caches each address's list of chunks, so the building lookup runs once per address rather than every 5 seconds.

### 2c. The queue (`enqueue`, `enqueueLevels`, `promoteCold`)

When a chunk loads, `enqueue(chunk)`:

1. **Works out where it is.** Kahlua (PZ's Lua) only exposes Java *methods*, not fields, so `chunk.wx` doesn't work. Instead it finds any square in the chunk and rounds its X/Y down to a multiple of 8.
2. **Skips it if already waiting** (`pending[key]`).
3. **If it's cold, skips it but remembers it:**
   ```lua
   if lazyOn() and not hot[key] then
       readCold[key] = { x = x0, y = y0, lo = lo, hi = hi }
       return
   end
   ```
4. **If it's hot, queues one entry per floor:** `{ x, y, z, key, last }`.

The queue is a plain table with two indices, `head` (next to read) and `tail` (last added). That avoids `table.remove(queue, 1)`, which shifts every element along each time.

`promoteCold` runs after each index rebuild. Any remembered cold chunk that has since turned hot (for example, you just plumbed a barrel there) and is still loaded gets queued. Chunks that have unloaded are dropped from `readCold`.

### 2d. Reading (`readLevel`)

```lua
for dx = 0, 7 do for dy = 0, 7 do
    local square = cell:getGridSquare(item.x + dx, item.y + dy, item.z)
    if square then handler(square) end      -- handler = the captured original
end end
```

Two details matter here:

- **We call the original handler**, which calls the original `notice()`. We never reimplement it, so whatever the plumbing mod does per square, it still does.
- **We look squares up again by coordinates**, rather than keeping the square objects from when the chunk loaded. PZ recycles square objects: when a chunk unloads, its squares are reused for another chunk somewhere else. A stale reference could point at a different place. If the chunk has gone, `getGridSquare` returns `nil` and we skip it, and its next load will queue it again.

### 2e. Following plumb and unplumb (`wrapSetIncluded`, `recordPlumbing`)

Both menu actions end up on the server in `LGEP.setIncluded(x, y, z, included)`. The plumbing mod's command handler calls it *through the table* (`EP.setIncluded(...)`, LGEPPlumbing ~3953), so if we replace the table entry, our version gets called:

```lua
local original = EP.setIncluded
EP.setIncluded = function(x, y, z, included)
    local r1, r2 = original(x, y, z, included)   -- the mod decides first
    pcall(recordPlumbing, x, y, z, included)     -- then we write down what happened
    return r1, r2
end
```

This is the "replace a global" pattern from the guide: keep the old function, call it, then add your bit. `recordPlumbing` doesn't trust the `included` argument alone. The original can refuse to plumb (`EP.canPlumbHere`), so we read the barrel's real state back with `EP.isIncluded`. Plumbed means it's added to `plumbed`, and anything else means it's removed. Setting `indexBuiltAt = nil` forces an index rebuild on the next tick, so the area turns hot straight away.

`EP.setIncludedWrappedByCLP = true` stops us wrapping twice. The wrap is installed from our `OnInitGlobalModData` handler, not when our file loads. Our file may run before the plumbing mod's (files load in path order, and `LGEPChunkLoadPatch/` sorts before `LGExtendedPlumbing/`), so `setIncluded` might not exist yet. By that event every mod's files have run, and no chunk has loaded.

### 2f. The three events

```lua
Events.LoadChunk.Add(function(chunk) ... enqueue(chunk) end)
```
Fires once per chunk after all its squares exist. It only queues, which is almost free.

```lua
Events.OnTick.Add(function()
    refreshIndex(...)                         -- rebuild "hot" every 5 s, or now if asked
    local started = nowMs()
    while head <= tail and levels < MAX_LEVELS_PER_TICK do
        local item = queue[head]; queue[head] = nil; head = head + 1
        pcall(readLevel, handler, cell, item)
        if item.last then pending[item.key] = nil end
        if nowMs() - started >= BUDGET_MS then break end   -- the budget
    end
end)
```
This is where the real work happens, a slice at a time. Each step is wrapped in `pcall` (Lua's try/catch), so one bad square logs an error instead of breaking every tick after it.

```lua
Events.OnInitGlobalModData.Add(function() ... plumbed = store.plumbed end)
```
Fires when a world's saved data is ready, before chunks load. It resets the session tables and loads our saved barrel list. Because `plumbed` *is* the table inside `ModData`, editing it later is automatically saved with the world.

---

## Things worth noticing as a modder

- **We never edit the original files.** Everything is done by intercepting (`Events.LoadGridsquare.Add`) or wrapping (`LGEP.setIncluded`). If the author updates the mod, the patch keeps working unless the specific things it hooks change, and then it stands down instead of breaking.
- **Fail safe, not fail silent.** If the capture misses, the original runs untouched and the console says so. If the index can't be built, `lazyBroken` turns lazy mode off and everything is scanned.
- **`pcall` around anything that runs per tick or per chunk.** An error in an event handler that fires thousands of times would otherwise flood the log or kill the feature.
- **Testing:** I ran both files against a fake `Events`, `getCell` and `ModData` written in Lua, not inside the game. The real check is in-game, by looking for `[LGEPChunkLoadPatch] active` in `console.txt`.
