-- Test Ground 1.13.20: the end-of-run screen. A panel with the run's key numbers (the save tested, the
-- frame rate, the stutters, a line per step) and a countdown to closing the game, with a Pause button.
-- Shown by Runner's finish through T.endScreen(summary, plan). Not shown in an unattended Autorun run
-- (T.trusted) unless the flag says endscreen = 1; endscreen = off never shows it. The closing countdown
-- (30 s, or the plan's seconds) runs for Benchmark Save, menu starts and plans that set it; a run started by
-- a command (Bridge) gets the screen without it.
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "TestGround/Core"
local TG = TestGroundInternal
local T = TG.T
if TG.loaded.EndScreen then return end
TG.loaded.EndScreen = true

local FONT, SMALL = UIFont.Medium, UIFont.Small
local MAX_ROWS = 14
local WHITE, GREY, AMBER = { 1, 1, 1 }, { 0.65, 0.65, 0.65 }, { 0.95, 0.75, 0.3 }

TestGroundEndScreen = ISPanel:derive("TestGroundEndScreen")

function TestGroundEndScreen:new(sum, seconds)
	local rows = math.min(MAX_ROWS, #sum.rows)
	local w, h = 620, 170 + rows * 18 + (#sum.rows > MAX_ROWS and 18 or 0) + 40
	local o = ISPanel.new(self, (getCore():getScreenWidth() - w) / 2, (getCore():getScreenHeight() - h) / 2, w, h)
	o.sum, o.rowsShown = sum, rows
	o.backgroundColor = { r = 0.04, g = 0.05, b = 0.07, a = 0.96 }
	o.borderColor = { r = 0.45, g = 0.6, b = 0.85, a = 0.9 }
	o.moveWithMouse = true
	o.left = seconds                     -- nil: no countdown
	o.lastMs = getTimestampMs()
	o.paused = false
	return o
end

function TestGroundEndScreen:createChildren()
	local bw, bh, y = 160, 26, self.height - 36
	self.pauseBtn = ISButton:new(20, y, bw, bh, "Pause countdown", self, TestGroundEndScreen.onPause)
	self.pauseBtn:initialise(); self.pauseBtn:instantiate(); self:addChild(self.pauseBtn)
	self.closeBtn = ISButton:new(20 + bw + 10, y, bw, bh, "Close game now", self, TestGroundEndScreen.onCloseGame)
	self.closeBtn:initialise(); self.closeBtn:instantiate(); self:addChild(self.closeBtn)
	self.keepBtn = ISButton:new(self.width - bw - 20, y, bw, bh, "Keep playing", self, TestGroundEndScreen.onKeep)
	self.keepBtn:initialise(); self.keepBtn:instantiate(); self:addChild(self.keepBtn)
	if not self.left then self.pauseBtn:setVisible(false); self.closeBtn:setTitle("Close game") end
end

function TestGroundEndScreen:onPause()
	self.paused = not self.paused
	self.pauseBtn:setTitle(self.paused and "Resume countdown" or "Pause countdown")
end
function TestGroundEndScreen:onKeep() self:setVisible(false); self:removeFromUIManager() end
function TestGroundEndScreen:onCloseGame()
	self:onKeep()
	pcall(function() getCore():quitToDesktop() end)
end

function TestGroundEndScreen:line(text, x, y, c, font)
	self:drawText(text, x, y, c[1], c[2], c[3], 1, font or SMALL)
end

function TestGroundEndScreen:prerender()
	ISPanel.prerender(self)
	local now = getTimestampMs()
	if self.left and not self.paused then
		self.left = self.left - (now - self.lastMs) / 1000
		if self.left <= 0 then self.left = 0; self:onCloseGame(); return end
	end
	self.lastMs = now
end

function TestGroundEndScreen:render()
	local s = self.sum
	local x, y = 20, 12
	self:line("Test Ground run finished" .. (s.stopped and (" (" .. tostring(s.stopped) .. ")") or ""), x, y, WHITE, FONT); y = y + 28
	self:line("Save tested: " .. tostring(s.save) .. (s.copyOf and "  (run in a throwaway copy)" or ""), x, y, AMBER); y = y + 20
	self:line(string.format("%d steps, %.0f s, %d frames", #s.rows, s.seconds, s.frames), x, y, GREY); y = y + 20
	self:line(string.format("%.1f fps on average, %.1f ms a frame, worst step p99 %d ms, worst frame %d ms", s.fps, s.mean, s.p99, s.worst), x, y, WHITE); y = y + 20
	self:line(string.format("%d frames over 33 ms, %d hitches of 100 ms or more", s.over33, s.over100), x, y, WHITE); y = y + 26
	self:line("Test", x, y, GREY); self:line("fps", 420, y, GREY); self:line("p99 ms", 480, y, GREY); self:line("hitches", 550, y, GREY); y = y + 18
	for i = 1, self.rowsShown do
		local e = s.rows[i]
		local nm = e.name
		if string.len(nm) > 44 then nm = string.sub(nm, 1, 43) .. "." end
		if e.skipped then
			self:line(nm .. "  (skipped)", x, y, GREY)
		else
			local c = e.f.over100 > 0 and AMBER or WHITE
			self:line(nm, x, y, c)
			self:line(string.format("%.1f", e.f.fps), 420, y, c); self:line(tostring(e.f.p99), 480, y, c); self:line(tostring(e.f.over100), 550, y, c)
		end
		y = y + 18
	end
	if #s.rows > self.rowsShown then self:line(string.format("... and %d more steps in the report", #s.rows - self.rowsShown), x, y, GREY); y = y + 18 end
	if self.left then
		local txt = self.paused and "Countdown paused" or string.format("Closing the game in %d s", math.ceil(self.left))
		self:line(txt, x, self.height - 62, self.paused and AMBER or WHITE)
	end
end

function T.endScreen(sum, plan)
	local e = plan and plan.endscreen
	if e == false then return end
	if e == nil and T.trusted and not T.wantEndScreen then return end
	if #sum.rows == 0 then return end
	-- 1.13.21 (review of 1.13.20): the game is closed by the countdown only when the run asks for it: a
	-- plan's endscreen = <seconds>, Benchmark Save, or a run started from Test Ground's own menu. A run
	-- started by a command (Bridge) shows the screen with no countdown.
	local seconds
	if e ~= nil then seconds = e > 0 and e or nil
	elseif T.wantEndScreen or not T.commandStart then seconds = 30 end
	T.commandStart = nil
	local ok, err = pcall(function()
		local w = TestGroundEndScreen:new(sum, seconds)
		w:initialise(); w:instantiate(); w:addToUIManager(); w:bringToTop()
	end)
	if not ok then print("[TestGround] end screen failed: " .. tostring(err)) end
end
