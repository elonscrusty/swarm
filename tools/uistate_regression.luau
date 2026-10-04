-- Offline checks for the UI coordinator (src/client/UIState.lua) against the proven
-- overlap cases in docs/overhaul/UI_STATE_CONTRACT.md §6. Pure state: no Roblox mock.
-- Run: lune run tools/uistate_regression.luau
local UIState = require("../src/client/UIState")

local now = 0
UIState._SetClock(function()
	return now
end)
local function advance(dt: number)
	local t = 0
	while t < dt do
		now += 1 / 30
		t += 1 / 30
		UIState.Step(now)
	end
end

local failures = 0
local function check(name: string, ok: boolean)
	print((ok and "PASS " or "FAIL ") .. name)
	if not ok then
		failures += 1
	end
end

-- renderers that record what is on screen
local headlines: { string } = {}
local headlineOn: string? = nil
local finishHeadline: (() -> ())? = nil
UIState.SetRenderer("Headline", function(item, done)
	table.insert(headlines, item.Id)
	headlineOn = item.Id
	finishHeadline = function()
		headlineOn = nil
		done()
	end
end)
local pills: { [any]: string } = {}
local function pillCount(): number
	local n = 0
	for _ in pairs(pills) do
		n += 1
	end
	return n
end
UIState.SetRenderer("Notice", function(item)
	local key = {}
	pills[key] = item.Text
	return {
		Set = function(text: string, count: number)
			pills[key] = text .. " x" .. count
		end,
		Dismiss = function()
			pills[key] = nil
		end,
	}
end)

local visible: { [string]: boolean } = {}
local function handle(name: string, extra: { [string]: any }?): any
	local h = {
		Blocks = true,
		Covers = true,
		Show = function()
			visible[name] = true
		end,
		Hide = function()
			visible[name] = false
		end,
	}
	for k, v in pairs(extra or {}) do
		h[k] = v
	end
	return h
end

-- 1. duplicate portal announcements (Short 0:13/0:14, Long 9:10)
UIState.FromServer({ Text = "THE PORTAL HAS APPEARED", Big = true })
UIState.Headline({ Id = "portal.reveal", Title = "THE PORTAL HAS APPEARED", Sub = "Follow the arrow", Sound = "PortalAppear", Class = "Info", Prefer = true })
advance(0.3)
check("portal reveal from two producers shows one headline", #headlines == 1 and headlines[1] == "portal.reveal")
local merged = UIState.HeadlineShowing()
check("merged headline keeps the client's sub line and sound", merged ~= nil and merged.Sub == "Follow the arrow" and merged.Sound == "PortalAppear")
UIState.FromServer({ Text = "THE PORTAL HAS APPEARED", Big = true })
advance(0.3)
check("a late repeat of the same id is dropped", #headlines == 1);
(finishHeadline :: any)()
advance(0.2)

-- 2. caravan toast over the caravan panel (Short 0:50)
UIState.FromServer({ Text = "Defend the caravan! Hold its ring for 20 seconds." })
advance(0.1)
check("caravan defend message is carried by the objective slot, not a notice", pillCount() == 0)

-- 3. elite toast over the wave headline (Short 1:25)
UIState.Headline({ Id = "swarm.pressure.1", Title = "THE SWARM IS GROWING", Class = "Info" })
advance(0.3)
check("swarm headline showing", headlineOn == "swarm.pressure.1")
UIState.FromServer({ Text = "Wave 6: an elite leads it!" })
UIState.FromServer({ Text = "Arena set to Ruins" })
advance(0.1)
local critOnly = pillCount() == 1
for _, t in pairs(pills) do
	critOnly = critOnly and string.find(t, "elite", 1, true) ~= nil
end
check("during a headline only the threat notice starts (it sits under the headline)", critOnly);
(finishHeadline :: any)()
advance(0.2)
check("the informational notice follows once the headline has left", pillCount() == 2)
advance(4)
check("notices retire after their time", pillCount() == 0)

-- 4. four stacked notices (Long 8:12)
UIState.SetMaxNotices(2)
UIState.FromServer({ Text = "An elite Shielded Mite leads the wave!" })
UIState.FromServer({ Text = "An elite Burning Phase Moth leads the wave!" })
UIState.Notice({ Id = "achievement", Text = "Achievement: Field Engineer", Class = "Info" })
UIState.FromServer({ Text = "MrCarter opened the altar: an item for everyone!" })
advance(0.1)
local coalesced = false
for _, t in pairs(pills) do
	coalesced = coalesced or string.find(t, "x2", 1, true) ~= nil
end
check("at most two notices on a phone", pillCount() == 2)
check("two elite notices coalesce into one (x2)", coalesced)
advance(3.2)
check("the waiting notice shows when room frees", pillCount() >= 1)
advance(7)
check("nothing lingers", pillCount() == 0 and #UIState.QueuedNotices() == 0)
UIState.SetMaxNotices(3)

-- 5. upgrade choice above the Stage 2 clear dialog (Long 9:02)
UIState.Open("Portal", handle("Portal"))
check("stage clear shows alone", visible.Portal == true and UIState.Owner() == "Portal")
UIState.Open("LevelUp", handle("LevelUp"))
check("upgrade choice suspends the stage clear panel", visible.LevelUp == true and visible.Portal == false)
check("one input owner", UIState.Owner() == "LevelUp")
UIState.Close("LevelUp")
check("stage clear comes back after the choice", visible.Portal == true and UIState.Owner() == "Portal")
UIState.Open("LevelUp", handle("LevelUp"))
check("an upgrade arriving during stage clear also goes first", visible.LevelUp == true and visible.Portal == false)
UIState.Close("LevelUp")
UIState.Close("Portal")
check("world input back when no panel is open", UIState.WorldInputAllowed() and UIState.Owner() == nil)

-- sub-panels stack over their parent
UIState.Open("Pause", handle("Pause"))
UIState.Open("BugReport", handle("BugReport", { Stacks = true }))
check("bug report stacks over the run menu (both on screen, report owns input)", visible.Pause == true and visible.BugReport == true and UIState.Owner() == "BugReport")
UIState.Close("BugReport")
check("run menu owns input again", UIState.Owner() == "Pause")
check("run menu cannot open over an upgrade", (function()
	UIState.Close("Pause")
	UIState.Open("LevelUp", handle("LevelUp"))
	local ok = not UIState.CanOpen("Pause")
	UIState.Close("LevelUp")
	return ok
end)())

-- 6. reel + two portal headings + chest interaction (Long 9:10)
UIState.Reset("test")
headlines = {}
UIState.SetFeedback(true)
check("reward feedback blocks world interaction (chest prompt hidden)", not UIState.WorldInputAllowed())
UIState.FromServer({ Text = "THE PORTAL HAS APPEARED", Big = true })
UIState.Headline({ Id = "portal.reveal", Title = "THE PORTAL HAS APPEARED", Sub = "Follow the arrow", Class = "Info", Prefer = true })
advance(1)
check("informational headline waits for the reward feedback", #headlines == 0)
UIState.Headline({ Id = "big:the queen is enraged!", Title = "THE QUEEN IS ENRAGED!", Class = "Critical" })
advance(0.1)
check("a threat headline does not wait for reward feedback", headlineOn == "big:the queen is enraged!");
(finishHeadline :: any)()
UIState.SetFeedback(false)
advance(0.3)
check("the portal headline shows once the reward has gone, once", #headlines == 2 and headlines[2] == "portal.reveal");
(finishHeadline :: any)()

-- covering panel holds headlines; expiry
UIState.Open("LevelUp", handle("LevelUp"))
UIState.Headline({ Id = "portal.open", Title = "THE PORTAL IS OPEN", Class = "Info" })
advance(7)
UIState.Close("LevelUp")
advance(0.5)
check("a headline that waited past its expiry is dropped", headlines[#headlines] ~= "portal.open")

-- stale overlay watchdog: hidden UI never keeps eating movement
UIState.Open("Revive", handle("Revive"))
advance(1)
UIState.Audit(function(name)
	return name ~= "Revive" -- its overlay vanished without a Close
end)
check("watchdog closes a primary whose overlay vanished", not UIState.IsOpen("Revive") and not UIState.Blocking())

-- lifecycle
UIState.Notice({ Id = "x", Text = "x", Class = "Info" })
UIState.Headline({ Id = "y", Title = "Y", Class = "Critical" })
advance(0.1)
UIState.Reset("death")
check("reset drops queued and visible messages", pillCount() == 0 and UIState.HeadlineShowing() == nil and #UIState.QueuedNotices() == 0)

-- player answers show even under a panel
UIState.Open("Results", handle("Results"))
UIState.Notice({ Id = "text:sent", Text = "Thanks! Your report was sent.", Class = "Player" })
advance(0.1)
check("a direct answer to the player shows under a covering panel", pillCount() == 1)
UIState.Close("Results")

print(failures == 0 and "UISTATE: all passed" or ("UISTATE: " .. failures .. " failed"))
if failures > 0 then
	error("uistate regression failed")
end
