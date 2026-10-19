-- Test Ground Capture: the Java side (global TGCapture) does the work; Test Ground calls it for each
-- screenshot (plan "capture = auto|back|world|both|game"). This only says in the console whether it loaded.
Events.OnGameStart.Add(function()
	local ok, s = pcall(function() return TGCapture.status() end)
	print("[TestGroundCapture] " .. (ok and tostring(s) or "Java side not loaded (is ZombieBuddy on, and the jar allowed?): " .. tostring(s)))
end)
