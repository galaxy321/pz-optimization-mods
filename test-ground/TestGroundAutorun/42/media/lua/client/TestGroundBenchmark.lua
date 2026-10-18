-- Test Ground Autorun 1.5.1: "Benchmark Save" on the main menu. A button opens a window with your saves
-- and "New vanilla save". The run happens in a throwaway copy (made by Test Ground Capture's copySave),
-- or in a new vanilla save, never in the save you chose; the copy is deleted the next time the main
-- menu shows. The report and the end screen name the save you chose. The fixed baseline plan runs.
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISScrollingListBox"
require "TestGroundAutorun"

local A = TestGroundAutorun
if A.benchLoaded then return end
A.benchLoaded = true

local VANILLA = "New vanilla save"
local function say(s) print("[TestGroundAutorun] benchmark: " .. s) end

-- every save as { mode, name }, newest first. 1.5.1 (review of 1.5.0): from getFullSaveDirectoryTable(), which
-- lists the Saves folder; getSaveDirectory(mode) takes a path, not a mode name. An entry may be a File of a
-- save (its folder's parent is the game mode) or a "Mode/Name" string; anything else is skipped.
local function savesList()
	local out, seen = {}, {}
	local function add(mode, name, t)
		if mode and name and A.BENCH_MODES[mode] and not string.find(name, "^" .. A.BENCH_PREFIX) and not seen[mode .. "/" .. name] then
			seen[mode .. "/" .. name] = true
			out[#out + 1] = { mode = mode, name = name, t = t or 0 }
		end
	end
	pcall(function()
		local tbl = getFullSaveDirectoryTable()
		local function take(e)
			if type(e) == "string" then
				local mode, name = string.match(e, "^([^/\\]+)[/\\](.+)$")
				add(mode, name)
			elseif e ~= nil then
				pcall(function()
					local name = e:getName()
					local parent = e:getParentFile()
					local mode = parent and parent:getName()
					local t = 0
					pcall(function() t = e:lastModified() end)
					add(mode, name, t)
				end)
			end
		end
		if tbl.size and type(tbl.size) == "function" and tbl:size() > 0 then
			for i = 1, tbl:size() do take(tbl:get(i - 1) or tbl:rawget(i)) end
		else
			for _, e in ipairs(tbl) do take(e) end
		end
	end)
	table.sort(out, function(a, b) return a.t > b.t end)
	return out
end

local function stampName()
	local t = getTimestamp and getTimestamp() or os.time()
	return tostring(t)
end

TestGroundBenchWindow = ISPanel:derive("TestGroundBenchWindow")

function TestGroundBenchWindow:new()
	local w, h = 520, 420
	local o = ISPanel.new(self, (getCore():getScreenWidth() - w) / 2, (getCore():getScreenHeight() - h) / 2, w, h)
	o.backgroundColor = { r = 0.04, g = 0.05, b = 0.07, a = 0.97 }
	o.borderColor = { r = 0.45, g = 0.6, b = 0.85, a = 0.9 }
	o.moveWithMouse = true
	o.note = ""
	return o
end

function TestGroundBenchWindow:createChildren()
	self.list = ISScrollingListBox:new(20, 70, self.width - 40, self.height - 190)
	self.list:initialise(); self.list:instantiate()
	self.list.itemheight = 22
	self.list.font = UIFont.Small
	self.list.drawBorder = true
	self:addChild(self.list)
	self.list:addItem(VANILLA, { vanilla = true })
	for _, s in ipairs(savesList()) do self.list:addItem(s.name .. "   (" .. s.mode .. ")", s) end
	self.list.selected = 1
	local bw, bh, y = 150, 26, self.height - 40
	self.startBtn = ISButton:new(20, y, bw, bh, "Start benchmark", self, TestGroundBenchWindow.onStart)
	self.startBtn:initialise(); self.startBtn:instantiate(); self:addChild(self.startBtn)
	self.cancelBtn = ISButton:new(self.width - bw - 20, y, bw, bh, "Cancel", self, TestGroundBenchWindow.onCancel)
	self.cancelBtn:initialise(); self.cancelBtn:instantiate(); self:addChild(self.cancelBtn)
end

function TestGroundBenchWindow:onCancel() self:setVisible(false); self:removeFromUIManager(); A.benchWindow = nil end

function TestGroundBenchWindow:render()
	self:drawText("Benchmark Save", 20, 12, 1, 1, 1, 1, UIFont.Medium)
	self:drawText("Pick a save to test. The run happens in a throwaway copy of it; your save is not opened.", 20, 40, 0.75, 0.75, 0.75, 1, UIFont.Small)
	self:drawText("The copy is deleted the next time this menu shows. Runs the fixed baseline, then shows the results.", 20, self.height - 112, 0.75, 0.75, 0.75, 1, UIFont.Small)
	if self.note ~= "" then self:drawText(self.note, 20, self.height - 80, 0.95, 0.5, 0.4, 1, UIFont.Small) end
end

local function cut(name, n)   -- at most n bytes, never inside a multi-byte character
	if string.len(name) <= n then return name end
	local c = string.sub(name, 1, n)
	while string.len(c) > 0 and string.byte(c, string.len(c)) >= 128 do c = string.sub(c, 1, string.len(c) - 1) end
	return c
end

local function flagLines(win, save, mode, origin)
	local lines = { "save = " .. save, "mode = " .. mode, "origin = " .. string.gsub(origin, "#", "_") }
	-- the copy keeps the original's mod list, which may lack the test mods: they are added to the copy's list
	for _, l in ipairs({ "plan = baseline", "start = westpoint", "quit = 0", "endscreen = 1", "delay = 20",
		"addmods = TestGround,TestGroundBridge,TestGroundAutorun,TestGroundCapture" }) do lines[#lines + 1] = l end
	return lines
end

function TestGroundBenchWindow:begin(lines)
	A.writeFlagLines(lines)
	A.benchBusy = true
	self.copying = nil
	self:onCancel()
	A.kick()
end

function TestGroundBenchWindow:onStart()
	if self.copying or A.benchBusy then return end
	local row = self.list.items[self.list.selected]
	local pick = row and row.item
	if not pick then self.note = "Pick a save first."; return end
	local stamp = stampName()
	if pick.vanilla then
		local name = A.BENCH_PREFIX .. "Vanilla " .. stamp
		A.recordBench("Sandbox", name, VANILLA)
		say("starting on " .. VANILLA)
		local lines = flagLines(self, name, "Sandbox", VANILLA)
		table.insert(lines, 1, "newsave = " .. name)
		return self:begin(lines)
	end
	if not (TGCapture and TGCapture.copySaveStart) then
		self.note = "Test Ground Capture 1.0.7 is needed to copy a save (it isn't loaded)."
		return
	end
	local copy = string.gsub(A.BENCH_PREFIX .. cut(pick.name, 40) .. " " .. stamp, "#", "_")
	local okC, err = pcall(function() return TGCapture.copySaveStart(pick.mode, pick.name, copy) end)
	if not okC or (err ~= nil and err ~= "") then
		self.note = "Could not copy: " .. tostring(err)
		say("copy not started: " .. tostring(err))
		return
	end
	A.recordBench(pick.mode, copy, pick.name)   -- recorded as soon as the copy starts, so a half-made one is cleaned up too
	self.copying = { mode = pick.mode, src = pick.name, copy = copy, nextPoll = 0 }
	self.startBtn:setEnable(false)
	self.cancelBtn:setEnable(false)
	say("copying " .. pick.name .. " to " .. copy)
end

function TestGroundBenchWindow:prerender()
	ISPanel.prerender(self)
	local c = self.copying
	if not c or getTimestampMs() < c.nextPoll then return end
	c.nextPoll = getTimestampMs() + 300
	local ok, st = pcall(function() return TGCapture.copySaveStatus() end)
	st = ok and tostring(st) or "failed: status unreadable"
	if st == "done" then
		say("copy done")
		self:begin(flagLines(self, c.copy, c.mode, c.src))
	elseif string.sub(st, 1, 6) == "failed" or st == "idle" then
		self.note = "Could not copy: " .. st
		say(self.note)
		self.copying = nil
		self.startBtn:setEnable(true)
		self.cancelBtn:setEnable(true)
	else
		self.note = "Copying the save for the test: " .. st
	end
end

-- the button on the main menu
local function showWindow()
	if A.benchWindow then return end
	local w = TestGroundBenchWindow:new()
	w:initialise(); w:instantiate(); w:addToUIManager(); w:bringToTop()
	A.benchWindow = w
end

local function addButton()
	A.benchBusy = false
	local ms = MainScreen and MainScreen.instance
	if not ms or ms.testGroundBenchBtn then return end
	local ok, err = pcall(function()
		local btn = ISButton:new(20, getCore():getScreenHeight() - 56, 170, 30, "Benchmark Save", ms, function() showWindow() end)
		btn:initialise(); btn:instantiate()
		btn.borderColor = { r = 0.45, g = 0.6, b = 0.85, a = 1 }
		ms:addChild(btn)
		ms.testGroundBenchBtn = btn
	end)
	if not ok then say("could not add the menu button: " .. tostring(err)) end
end

Events.OnMainMenuEnter.Add(addButton)
if MainScreen and MainScreen.instance then addButton() end
