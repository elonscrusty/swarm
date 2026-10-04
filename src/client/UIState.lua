--[[
	UIState.lua
	One client-side coordinator for what the screen shows and who owns input. The contract
	(priorities, lanes, semantic ids, lifecycle) is docs/overhaul/UI_STATE_CONTRACT.md; keep
	the two in step.

	  primary overlays  panels that take input (level-up, stage clear, results ...). Several
	                    may be open (earned and waiting); only the highest priority one is
	                    shown, the rest are suspended (hidden, never resolved) and come back
	                    when it closes. UIBuilder's show / hide go through Open / Close.
	  headline lane     one centre banner at a time (Hud draws it): semantic id dedupe,
	                    short queue, expiry, held while a covering panel, a stage-start card
	                    or reward feedback is up (Critical ones only wait for a covering panel).
	  notice lane       short pills under the top HUD (UIBuilder draws them): at most 2
	                    (phones) or 3 visible, the same id coalesces ("x2"), waiting ones
	                    expire; while a headline shows only Critical notices start.
	  cleanup           Reset(reason) on death / respawn / travel / leaving the run.

	No Roblox services: pure state, so a Lune test can drive it (tools/preview/uistate_test.luau).
	Renderers and per-frame Step come from UIBuilder / Hud.
]]

local UIState = {}

------------------------------------------------------------------------------------------
-- Clock (tests swap it)
------------------------------------------------------------------------------------------

local clock: () -> number = os.clock
function UIState._SetClock(fn: () -> number)
	clock = fn
end

------------------------------------------------------------------------------------------
-- Primary overlays
------------------------------------------------------------------------------------------

-- Higher wins. Names are UIBuilder's overlay names.
UIState.Priority = {
	Travel = 100, -- stage travel fade (StageUI)
	BugReport = 95, -- over Results / Pause, which opened it
	Results = 90,
	Revive = 80,
	LevelUp = 70, -- the upgrade choice
	Portal = 65, -- stage clear / continue
	Reward = 60, -- the full (paused) reward reveal only; the mini reel is feedback
	Items = 55, -- items list from the run menu
	Pause = 50, -- run menu / settings
	DevInbox = 40,
} :: { [string]: number }

export type Handle = {
	Show: (() -> ())?, -- make it visible (called when it becomes the owner, and again on a re-Open)
	Hide: (() -> ())?, -- suspend it (hide without resolving)
	Blocks: boolean?, -- thumbstick + world interaction off while shown
	Covers: boolean?, -- HUD / minimap / item strip hidden while shown
}

type Entry = { Name: string, Priority: number, Handle: Handle, Shown: boolean, ShownAt: number, OpenedAt: number }

local open: { [string]: Entry } = {}
local owner: string? = nil
local ownerListeners: { (string?) -> () } = {}

local function topName(): string?
	local best, bestP = nil, -math.huge
	for name, e in pairs(open) do
		if e.Priority > bestP or (e.Priority == bestP and best ~= nil and name < best) then
			best, bestP = name, e.Priority
		end
	end
	return best
end

local function call(fn: (() -> ())?)
	if fn then
		local ok, err = pcall(fn)
		if not ok then
			warn("[UIState] " .. tostring(err))
		end
	end
end

local function recompute(reshow: string?)
	local top = topName()
	-- suspend first, then show the owner (no frame with two panels)
	for name, e in pairs(open) do
		if name ~= top and e.Shown then
			e.Shown = false
			call(e.Handle.Hide)
		end
	end
	if top then
		local e = open[top]
		if not e.Shown then
			e.Shown = true
			e.ShownAt = clock()
			call(e.Handle.Show)
		elseif reshow == top then
			call(e.Handle.Show)
		end
	end
	if top ~= owner then
		owner = top
		for _, fn in ipairs(ownerListeners) do
			local ok, err = pcall(fn, top)
			if not ok then
				warn("[UIState] " .. tostring(err))
			end
		end
	end
end

-- Registers (or refreshes) an open primary. Returns true when it is shown now, false when
-- it waits behind a higher one (its Hide was called; Show comes when it is the owner).
function UIState.Open(name: string, handle: Handle): boolean
	local e = open[name]
	if e then
		e.Handle = handle
	else
		open[name] = {
			Name = name,
			Priority = UIState.Priority[name] or 10,
			Handle = handle,
			Shown = false,
			ShownAt = math.huge,
			OpenedAt = clock(),
		}
	end
	recompute(name)
	return owner == name
end

-- Removes an open primary (its own close animation is the caller's); the next one shows.
function UIState.Close(name: string)
	if open[name] then
		open[name] = nil
		recompute(nil)
	end
end

function UIState.IsOpen(name: string): boolean
	return open[name] ~= nil
end

-- Open and currently the owner (not suspended).
function UIState.IsShown(name: string): boolean
	local e = open[name]
	return e ~= nil and e.Shown
end

function UIState.Owner(): string?
	return owner
end

-- When `name` became the owner (math.huge while suspended / closed). A button press that
-- began before this must not count (no stale held button).
function UIState.ShownAt(name: string): number
	local e = open[name]
	return e and e.Shown and e.ShownAt or math.huge
end

-- Whether opening `name` now would show it (nothing of a higher priority is open).
function UIState.CanOpen(name: string): boolean
	local p = UIState.Priority[name] or 10
	for other, e in pairs(open) do
		if other ~= name and e.Priority > p then
			return false
		end
	end
	return true
end

-- The shown owner blocks the thumbstick / covers the HUD.
function UIState.Blocking(): boolean
	local e = owner and open[owner]
	return e ~= nil and e.Handle.Blocks == true
end

function UIState.Covered(): boolean
	local e = owner and open[owner]
	return e ~= nil and e.Handle.Covers == true
end

-- World interaction (chests, shrines, purchases, revive key) only with no panel open.
function UIState.WorldInputAllowed(): boolean
	return next(open) == nil and not UIState.FeedbackActive()
end

function UIState.OnOwnerChanged(fn: (string?) -> ())
	table.insert(ownerListeners, fn)
end

-- Every open primary's name (tests / debug).
function UIState.OpenNames(): { string }
	local list = {}
	for name in pairs(open) do
		table.insert(list, name)
	end
	table.sort(list, function(a, b)
		return (open[a].Priority > open[b].Priority)
	end)
	return list
end

-- Watchdog: `visible(name)` says whether a shown primary's overlay is really on screen. A
-- shown entry whose overlay vanished without a Close (destroyed, hidden by other code) is
-- closed, so a stale block can never keep eating movement.
function UIState.Audit(visible: (string) -> boolean?)
	local stale: { string } = {}
	for name, e in pairs(open) do
		if e.Shown and clock() - e.ShownAt > 0.5 and visible(name) == false then
			table.insert(stale, name)
		end
	end
	for _, name in ipairs(stale) do
		warn("[UIState] closing stale primary " .. name)
		UIState.Close(name)
	end
end

------------------------------------------------------------------------------------------
-- Holds (things the lanes wait for) and reward feedback
------------------------------------------------------------------------------------------

local holds: { [string]: boolean } = {}
local feedback: { [string]: boolean } = {}

-- A named hold on the headline lane (e.g. "Intro": the stage-start card is up).
function UIState.SetHold(name: string, on: boolean)
	if on then
		holds[name] = true
	else
		holds[name] = nil
	end
end

-- Automatic reward feedback on screen (mini reel / compact reward card). Holds non-critical
-- headlines and hides the loot prompt.
function UIState.SetFeedback(on: boolean, key: string?)
	if on then
		feedback[key or "Reward"] = true
	else
		feedback[key or "Reward"] = nil
	end
end

function UIState.FeedbackActive(): boolean
	return next(feedback) ~= nil
end

------------------------------------------------------------------------------------------
-- Headline lane
------------------------------------------------------------------------------------------

export type Headline = {
	Id: string,
	Title: string,
	Sub: string?,
	Color: any?, -- Color3
	Sound: string?,
	Class: string?, -- "Critical" | "Info"
	Expire: number?, -- seconds it may wait in the queue (default 6, Critical 4)
	Prefer: boolean?, -- this producer's Sub / Sound / Color win over a queued twin's
	-- filled in by UIState
	QueuedAt: number?,
}

local HEADLINE_QUEUE = 3
local HEADLINE_SAFETY = 4 -- a renderer that never reports done frees the lane after this
local headlineQueue: { Headline } = {}
local headlineNow: Headline? = nil
local headlineSince = 0
local headlineToken = 0
local recentHeadline: { [string]: number } = {} -- id -> when it last showed
local HEADLINE_REPEAT = 6 -- the same id within this many seconds is a duplicate
local HEADLINE_SETTLE = 0.15 -- an informational headline waits this long for a twin
local headlineRenderer: ((Headline, () -> ()) -> ())? = nil

local function critical(item: { Class: string? }): boolean
	return item.Class == "Critical"
end

local function headlineHeld(item: Headline): boolean
	if UIState.Covered() or open.Travel then
		return true
	end
	if critical(item) then
		return false
	end
	return next(holds) ~= nil or UIState.FeedbackActive()
end

function UIState.Headline(item: Headline)
	local now = clock()
	local id = item.Id
	if headlineNow and headlineNow.Id == id then
		return
	end
	local last = recentHeadline[id]
	if last and now - last < HEADLINE_REPEAT then
		return
	end
	for _, q in ipairs(headlineQueue) do
		if q.Id == id then
			-- the same event from a second producer: one banner, the richer wording
			if item.Prefer or not q.Sub or q.Sub == "" then
				q.Sub = item.Sub
			end
			if item.Prefer or not q.Sound then
				q.Sound = item.Sound
			end
			if item.Prefer and item.Color then
				q.Color = item.Color
			end
			return
		end
	end
	item.QueuedAt = now
	if critical(item) then
		-- threat first: in front of informational ones
		local at = #headlineQueue + 1
		for i, q in ipairs(headlineQueue) do
			if not critical(q) then
				at = i
				break
			end
		end
		table.insert(headlineQueue, at, item)
	else
		table.insert(headlineQueue, item)
	end
	while #headlineQueue > HEADLINE_QUEUE do
		-- drop the oldest informational one (or the oldest)
		local drop = #headlineQueue
		for i = #headlineQueue, 1, -1 do
			if not critical(headlineQueue[i]) then
				drop = i
				break
			end
		end
		table.remove(headlineQueue, drop)
	end
	UIState.Step()
end

function UIState.HeadlineShowing(): Headline?
	return headlineNow
end

-- True when an id is showing, queued or showed within HEADLINE_REPEAT seconds.
function UIState.HeadlineSeen(id: string): boolean
	if headlineNow and headlineNow.Id == id then
		return true
	end
	for _, q in ipairs(headlineQueue) do
		if q.Id == id then
			return true
		end
	end
	local last = recentHeadline[id]
	return last ~= nil and clock() - last < HEADLINE_REPEAT
end

local function stepHeadline(now: number)
	if headlineNow and now - headlineSince > HEADLINE_SAFETY then
		headlineNow = nil
	end
	-- stale ones leave the queue
	for i = #headlineQueue, 1, -1 do
		local q = headlineQueue[i]
		local wait = q.Expire or (critical(q) and 4 or 6)
		if now - (q.QueuedAt or now) > wait then
			table.remove(headlineQueue, i)
		end
	end
	if headlineNow or not headlineRenderer then
		return
	end
	for i, q in ipairs(headlineQueue) do
		-- informational ones settle a moment first, so a twin from another producer (the
		-- server's broadcast and the client's attribute watcher) can merge into it
		local settled = critical(q) or now - (q.QueuedAt or now) >= HEADLINE_SETTLE
		if settled and not headlineHeld(q) then
			table.remove(headlineQueue, i)
			headlineNow = q
			headlineSince = now
			recentHeadline[q.Id] = now
			headlineToken += 1
			local token = headlineToken
			local render = headlineRenderer :: (Headline, () -> ()) -> ()
			local ok, err = pcall(render, q, function()
				if token == headlineToken then
					headlineNow = nil
				end
			end)
			if not ok then
				warn("[UIState] " .. tostring(err))
				headlineNow = nil
			end
			return
		end
	end
end

------------------------------------------------------------------------------------------
-- Notice lane
------------------------------------------------------------------------------------------

export type Notice = {
	Id: string,
	Text: string,
	Color: any?, -- Color3
	Class: string?, -- "Critical" | "Info"
	Seconds: number?, -- on screen (default 3)
	Expire: number?, -- may wait this long (default Info 6, Critical 3)
	-- filled in by UIState
	Count: number?,
	QueuedAt: number?,
	Until: number?,
	Handle: NoticeHandle?,
}

export type NoticeHandle = {
	Set: (text: string, count: number) -> (),
	Dismiss: () -> (),
}

local DEDUPE_SECONDS = 4
local noticeVisible: { Notice } = {}
local noticeQueue: { Notice } = {}
local recentNotice: { [string]: { At: number, Text: string } } = {}
local noticeRenderer: ((Notice) -> NoticeHandle?)? = nil
local maxNotices = 3

-- Ids whose message the persistent objective slot already carries (never a notice).
UIState.ObjectiveCovers = { ["caravan.defend"] = true } :: { [string]: boolean }

function UIState.SetMaxNotices(n: number)
	maxNotices = math.max(1, n)
end

local function findIn(list: { Notice }, id: string): (Notice?, number?)
	for i, n in ipairs(list) do
		if n.Id == id then
			return n, i
		end
	end
	return nil, nil
end

function UIState.Notice(item: Notice)
	local now = clock()
	local id = item.Id
	if UIState.ObjectiveCovers[id] then
		return
	end
	-- a wave toast the wave headline already said
	local wave = string.match(id, "^wave%.(%d+)%.info$")
	if wave and UIState.HeadlineSeen("wave." .. wave) then
		return
	end
	local shown = findIn(noticeVisible, id)
	if shown then
		shown.Count = (shown.Count or 1) + 1
		shown.Text = item.Text
		shown.Until = now + (item.Seconds or 3)
		local h = shown.Handle
		if h then
			pcall(h.Set, shown.Text, shown.Count or 1)
		end
		return
	end
	local queued = findIn(noticeQueue, id)
	if queued then
		queued.Count = (queued.Count or 1) + 1
		queued.Text = item.Text
		return
	end
	local recent = recentNotice[id]
	if recent and recent.Text == item.Text and now - recent.At < DEDUPE_SECONDS then
		return
	end
	item.Count = 1
	item.QueuedAt = now
	if critical(item) then
		local at = #noticeQueue + 1
		for i, q in ipairs(noticeQueue) do
			if not critical(q) then
				at = i
				break
			end
		end
		table.insert(noticeQueue, at, item)
	else
		table.insert(noticeQueue, item)
	end
	UIState.Step()
end

function UIState.VisibleNotices(): { Notice }
	return noticeVisible
end

function UIState.QueuedNotices(): { Notice }
	return noticeQueue
end

local function noticeHeld(item: Notice): boolean
	if UIState.Covered() or open.Travel then
		return true
	end
	-- while a headline shows only threat notices start (they sit under it)
	return headlineNow ~= nil and not critical(item)
end

local function dismiss(n: Notice)
	local h = n.Handle
	n.Handle = nil
	if h then
		pcall(h.Dismiss)
	end
end

local function stepNotices(now: number)
	for i = #noticeVisible, 1, -1 do
		local n = noticeVisible[i]
		if now >= (n.Until or 0) then
			table.remove(noticeVisible, i)
			dismiss(n)
		end
	end
	for i = #noticeQueue, 1, -1 do
		local q = noticeQueue[i]
		if now - (q.QueuedAt or now) > (q.Expire or (critical(q) and 3 or 6)) then
			table.remove(noticeQueue, i)
		end
	end
	if not noticeRenderer then
		return
	end
	local i = 1
	while i <= #noticeQueue and #noticeVisible < maxNotices do
		local q = noticeQueue[i]
		if noticeHeld(q) then
			i += 1
		else
			table.remove(noticeQueue, i)
			q.Until = now + (q.Seconds or 3)
			recentNotice[q.Id] = { At = now, Text = q.Text }
			local render = noticeRenderer :: (Notice) -> NoticeHandle?
			local ok, h = pcall(render, q)
			if ok then
				q.Handle = h
				if h and (q.Count or 1) > 1 then
					pcall(h.Set, q.Text, q.Count or 1)
				end
				table.insert(noticeVisible, q)
			else
				warn("[UIState] " .. tostring(h))
			end
		end
	end
end

------------------------------------------------------------------------------------------
-- Renderers, per frame, reset
------------------------------------------------------------------------------------------

-- "Headline": fn(item, done) draws a banner and calls done() when it has left.
-- "Notice": fn(item) -> { Set, Dismiss } draws a pill.
function UIState.SetRenderer(lane: string, fn: any)
	if lane == "Headline" then
		headlineRenderer = fn
	elseif lane == "Notice" then
		noticeRenderer = fn
	end
end

function UIState.Step(now: number?)
	local t = now or clock()
	stepHeadline(t)
	stepNotices(t)
end

-- Death, respawn, stage travel, leaving the run: drop queued and visible messages (they
-- are about the moment that just ended). Open primaries are not touched here: their owners
-- close them (earned decisions are server-held and re-sent).
function UIState.Reset(_reason: string?)
	table.clear(headlineQueue)
	headlineNow = nil
	headlineToken += 1
	table.clear(recentHeadline)
	table.clear(noticeQueue)
	for _, n in ipairs(noticeVisible) do
		dismiss(n)
	end
	table.clear(noticeVisible)
	table.clear(recentNotice)
	table.clear(feedback)
end

------------------------------------------------------------------------------------------
-- Server messages (remote Notify): semantic id, lane and class
------------------------------------------------------------------------------------------

export type Class = { Id: string, Lane: string, Class: string }

-- Ordered: first match wins. `pattern` is a plain substring of the lower-cased text unless
-- `lua` is set. Ids are in the contract (section 3).
local RULES: { { Find: string, Lua: boolean?, Id: string, Lane: string, Class: string } } = {
	{ Find = "the portal has appeared", Id = "portal.reveal", Lane = "Headline", Class = "Info" },
	{ Find = "the portal is open", Id = "portal.open", Lane = "Headline", Class = "Info" },
	{ Find = "defeated! survive the surge", Id = "boss.defeated", Lane = "Headline", Class = "Info" },
	{ Find = "daily challenge", Id = "run.start.daily", Lane = "Headline", Class = "Info" },
	{ Find = "endless:", Id = "run.start.endless", Lane = "Headline", Class = "Info" },
	{ Find = "victory!", Id = "run.end", Lane = "Headline", Class = "Info" },
	{ Find = "the swarm wins", Id = "run.end", Lane = "Headline", Class = "Info" },
	{ Find = "defend the caravan", Id = "caravan.defend", Lane = "Notice", Class = "Info" },
	{ Find = "caravan", Id = "caravan.result", Lane = "Notice", Class = "Info" },
	{ Find = "^wave (%d+) ·", Lua = true, Id = "wave.%1.info", Lane = "Notice", Class = "Critical" },
	{ Find = "^wave (%d+):", Lua = true, Id = "wave.%1.elite", Lane = "Notice", Class = "Critical" },
	{ Find = "hunts you", Id = "elite", Lane = "Notice", Class = "Critical" },
	{ Find = "leads the wave", Id = "elite", Lane = "Notice", Class = "Critical" },
	{ Find = "a swarm of", Id = "swarm.approach", Lane = "Notice", Class = "Critical" },
	{ Find = "has fallen", Id = "team.fallen", Lane = "Notice", Class = "Critical" },
	{ Find = "achievement:", Id = "achievement", Lane = "Notice", Class = "Info" },
}

function UIState.Classify(text: string, big: boolean?): Class
	local low = string.lower(text)
	for _, r in ipairs(RULES) do
		if r.Lua then
			local cap = string.match(low, r.Find)
			if cap then
				return { Id = (string.gsub(r.Id, "%%1", cap)), Lane = r.Lane, Class = r.Class }
			end
		elseif string.find(low, r.Find, 1, true) then
			local id = r.Id
			if id == "team.fallen" then
				id = "team.fallen." .. low -- one per teammate
			end
			return { Id = id, Lane = r.Lane, Class = r.Class }
		end
	end
	if big then
		-- boss arrivals, enrage phases: threat headlines
		return { Id = "big:" .. low, Lane = "Headline", Class = "Critical" }
	end
	return { Id = "text:" .. low, Lane = "Notice", Class = "Info" }
end

-- Remote Notify payload { Text, Color, Big, Id?, Lane?, Class? } -> the right lane.
function UIState.FromServer(data: { [string]: any })
	if type(data) ~= "table" or type(data.Text) ~= "string" then
		return
	end
	local c = UIState.Classify(data.Text, data.Big == true)
	local id = type(data.Id) == "string" and data.Id or c.Id
	local lane = (data.Lane == "Headline" or data.Lane == "Notice") and data.Lane or c.Lane
	local class = (data.Class == "Critical" or data.Class == "Info") and data.Class or c.Class
	if lane == "Headline" then
		UIState.Headline({ Id = id, Title = data.Text, Sub = type(data.Sub) == "string" and data.Sub or "", Color = data.Color, Class = class })
	else
		UIState.Notice({ Id = id, Text = data.Text, Color = data.Color, Class = class })
	end
end

return UIState
