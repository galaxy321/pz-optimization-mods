--
-- LG Extended Plumbing - Chunk Load Patch: the capture half.
--
-- WHY THIS LIVES IN shared/.  LGEPPlumbing.lua registers its per-square handler with an
-- anonymous function, so there is nothing to pass to Events.LoadGridsquare.Remove later.
-- The only way to stop it running per square, without editing that file, is to be standing
-- at the door when it calls Add.  shared/ is loaded before server/ in every mode, whatever
-- the mod order, so a wrapper installed here is always in place first.
--
-- HOW WE RECOGNISE THE RIGHT HANDLER.  A Lua file runs top to bottom without interruption.
-- LGEPPlumbing.lua defines LGEP.eachCollector (line ~385), then adds its LoadGridsquare
-- handler (line ~655), then defines LGEP.forgetColumns (line ~1165).  So the one
-- LoadGridsquare.Add that happens while eachCollector exists and forgetColumns does not is
-- that file's.  If an update to the original moves those around, nothing is captured, the
-- handler is registered normally, and the server half logs that it is standing down.
--

LGEP_CLP = LGEP_CLP or {}

local CLP = LGEP_CLP

if CLP.wrapped then return end

local function looksLikePlumbingHandler()
	local EP = LGEP
	return CLP.captured == nil
		and EP ~= nil
		and EP.eachCollector ~= nil
		and EP.forgetColumns == nil
end

local ok, err = pcall(function()
	local event = Events and Events.LoadGridsquare
	if not event or not event.Add then return end

	local originalAdd = event.Add
	event.Add = function(fn)
		if looksLikePlumbingHandler() then
			-- Held, not registered.  The server half calls it from a tick budget instead.
			CLP.captured = fn
			return
		end
		return originalAdd(fn)
	end

	-- If the server half stands down it hands the handler back through this.
	CLP.registerNormally = function(fn) return originalAdd(fn) end
	CLP.wrapped = true
end)

if not ok then
	print("[LGEPChunkLoadPatch] could not wrap Events.LoadGridsquare.Add: " .. tostring(err))
end
