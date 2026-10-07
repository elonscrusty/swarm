--[[
	BugSnapshotData.lua
	Shared rules for the automatic bug report snapshot (Config.Features.BugReportPlus,
	docs/next/BUG_REPORT_PLUS.md). The client (BugSnapshot) gathers it, the server
	(BugReportService) cleans it again with CleanSnapshot and stores it next to the report,
	and the DEV inbox (DevInbox) shows it with Lines.

	Nothing in a snapshot is free text from a player: every field is a known id, an enum
	name from a fixed list, or a clamped number. The one exception is the client's recent
	warning / error lines (LogService): the server trims them, removes player names and runs
	them through the Roblox text filter before they are stored (BugReportService).

	Pure helpers (no Roblox services), so a regression can drive them directly.
]]

local Config = require(script.Parent.Config)
local CharacterData = require(script.Parent.CharacterData)
local WeaponData = require(script.Parent.WeaponData)
local PassiveData = require(script.Parent.PassiveData)

local BugSnapshotData = {}

BugSnapshotData.MaxLogs = 10 -- newest client warnings / errors kept
BugSnapshotData.MaxLogLength = 200 -- characters per log line
BugSnapshotData.MaxBuild = 8 -- weapons / passives kept per list
BugSnapshotData.HourLimit = 3 -- reports per player per rolling hour (server, all servers)
BugSnapshotData.HourWindow = 3600 -- seconds
BugSnapshotData.InboxRows = 20 -- DEV inbox: latest reports per page (with snapshots)

-- UIState primaries (UIState.Priority) plus "None" (HUD / lobby, no panel open).
BugSnapshotData.Panels = {
	"None", "Travel", "Results", "Revive", "LevelUp", "Portal", "Reward", "Items", "Pause", "DevInbox",
}
BugSnapshotData.TextSizes = { "Medium", "Large", "Larger", "Largest" } -- Enum.PreferredTextSize names
BugSnapshotData.Inputs = { "Touch", "KeyboardMouse", "Gamepad", "Unknown" }
BugSnapshotData.Devices = { "Phone", "Tablet", "Desktop", "Console", "VR", "Unknown" }
BugSnapshotData.LogKinds = { "Warn", "Error" }

function BugSnapshotData.On(): boolean
	return Config.FeatureOn("BugReportPlus")
end

local function int(v: any, lo: number, hi: number): number?
	if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
		return nil
	end
	return math.clamp(math.floor(v), lo, hi)
end

local function oneOf(v: any, list: { string }, fallback: string?): string?
	if type(v) == "string" and table.find(list, v) then
		return v
	end
	return fallback
end

-- { { Id, Level, Evolved? } } with only known ids, clamped levels and no repeats.
function BugSnapshotData.CleanBuild(list: any, kind: string): { { [string]: any } }
	local out = {}
	if type(list) ~= "table" then
		return out
	end
	local defs: { [string]: any } = kind == "Weapon" and WeaponData.Weapons or PassiveData.Passives
	local seen: { [string]: boolean } = {}
	for i = 1, math.min(#list, 24) do
		local e = list[i]
		if #out >= BugSnapshotData.MaxBuild then
			break
		end
		if type(e) == "table" and type(e.Id) == "string" and defs[e.Id] ~= nil and not seen[e.Id] then
			seen[e.Id] = true
			local maxLevel = kind == "Weapon" and WeaponData.MaxLevel or PassiveData.MaxLevelOf(e.Id)
			local row: { [string]: any } = { Id = e.Id, Level = int(e.Level, 1, maxLevel) or 1 }
			if kind == "Weapon" and e.Evolved == true and type(defs[e.Id].Evolution) == "table" then
				row.Evolved = true
			end
			table.insert(out, row)
		end
	end
	return out
end

--[[
	One log line: valid UTF-8 only, printable ASCII kept (anything else becomes "?"), runs
	of spaces collapse, trimmed to MaxLogLength. nil when nothing is left.
]]
function BugSnapshotData.CleanLogText(s: any): string?
	if type(s) ~= "string" then
		return nil
	end
	s = string.sub(s, 1, BugSnapshotData.MaxLogLength * 4)
	s = string.gsub(s, "[^\32-\126]", "?")
	s = string.gsub(s, "%s+", " ")
	s = string.gsub(s, "^%s+", "")
	s = string.gsub(s, "%s+$", "")
	s = string.sub(s, 1, BugSnapshotData.MaxLogLength)
	return s ~= "" and s or nil
end

function BugSnapshotData.CleanLogs(list: any): { { [string]: any } }
	local out = {}
	if type(list) ~= "table" then
		return out
	end
	local n = math.min(#list, BugSnapshotData.MaxLogs)
	for i = 1, n do
		local e = list[i]
		if type(e) == "table" then
			local t = BugSnapshotData.CleanLogText(e.Text)
			if t then
				table.insert(out, { Kind = oneOf(e.Kind, BugSnapshotData.LogKinds, "Warn"), Text = t })
			end
		end
	end
	return out
end

-- Every occurrence of each name (plain match, 3+ characters) becomes "[player]".
function BugSnapshotData.RedactNames(s: string, names: { string }): string
	for _, name in ipairs(names) do
		if type(name) == "string" and #name >= 3 then
			local lower = string.lower(s)
			local needle = string.lower(name)
			local parts = {}
			local i = 1
			while true do
				local a, b = string.find(lower, needle, i, true)
				if not a then
					break
				end
				table.insert(parts, string.sub(s, i, a - 1))
				table.insert(parts, "[player]")
				i = b + 1
			end
			table.insert(parts, string.sub(s, i))
			s = table.concat(parts)
		end
	end
	return s
end

--[[
	The snapshot as stored: only known keys, ids from the game's data, names from fixed
	lists and clamped numbers. Logs are cleaned here too; the server filters them after.
]]
function BugSnapshotData.CleanSnapshot(raw: any): { [string]: any }
	local out: { [string]: any } = {}
	if type(raw) ~= "table" then
		return out
	end
	out.Panel = oneOf(raw.Panel, BugSnapshotData.Panels, "None")
	out.Stage = int(raw.Stage, 0, 999)
	out.Wave = int(raw.Wave, 0, 9999)
	local arena = raw.Arena
	out.Arena = (type(arena) == "string" and type(Config.Arenas[arena]) == "table") and arena or nil
	local hero = raw.Hero
	out.Hero = (type(hero) == "string" and CharacterData.Characters[hero] ~= nil) and hero or nil
	out.Level = int(raw.Level, 0, 9999)
	out.Weapons = BugSnapshotData.CleanBuild(raw.Weapons, "Weapon")
	out.Passives = BugSnapshotData.CleanBuild(raw.Passives, "Passive")
	out.Device = oneOf(raw.Device, BugSnapshotData.Devices, "Unknown")
	out.ScreenW = int(raw.ScreenW, 0, 10000)
	out.ScreenH = int(raw.ScreenH, 0, 10000)
	out.TextSize = oneOf(raw.TextSize, BugSnapshotData.TextSizes, nil)
	out.Input = oneOf(raw.Input, BugSnapshotData.Inputs, "Unknown")
	out.Fps = int(raw.Fps, 0, 999)
	out.PlaceVersion = int(raw.PlaceVersion, 0, 1e9)
	out.Logs = BugSnapshotData.CleanLogs(raw.Logs)
	if raw.LogsDropped == true then
		out.LogsDropped = true -- the server's text filter failed, so the lines were not kept
	end
	return out
end

--[[
	Rolling-hour rate limit: `recent` is a list of unix times of saved reports. Returns
	whether one more fits, and the list trimmed to the window (the caller appends `now`
	when it saves).
]]
function BugSnapshotData.HourCheck(recent: any, now: number): (boolean, { number })
	local kept = {}
	if type(recent) == "table" then
		for i = 1, math.min(#recent, 50) do
			local t = recent[i]
			if type(t) == "number" and t == t and t <= now and now - t < BugSnapshotData.HourWindow then
				table.insert(kept, t)
			end
		end
	end
	table.sort(kept)
	while #kept > BugSnapshotData.HourLimit do
		table.remove(kept, 1)
	end
	return #kept < BugSnapshotData.HourLimit, kept
end

-- The run as the server knows it: { Wave, Weapons, Passives } from a RunManager run player.
function BugSnapshotData.ServerBuild(rp: any): { [string]: any }
	local out: { [string]: any } = {}
	if type(rp) ~= "table" then
		return out
	end
	local weapons = {}
	if type(rp.WeaponOrder) == "table" and type(rp.Weapons) == "table" then
		for _, id in ipairs(rp.WeaponOrder) do
			local w = rp.Weapons[id]
			if type(w) == "table" then
				table.insert(weapons, { Id = id, Level = w.Level, Evolved = w.Evolved == true })
			end
		end
	end
	local passives = {}
	if type(rp.PassiveOrder) == "table" and type(rp.Passives) == "table" then
		for _, id in ipairs(rp.PassiveOrder) do
			table.insert(passives, { Id = id, Level = rp.Passives[id] })
		end
	end
	out.Weapons = BugSnapshotData.CleanBuild(weapons, "Weapon")
	out.Passives = BugSnapshotData.CleanBuild(passives, "Passive")
	return out
end

local function buildLine(list: any, kind: string): string
	local parts = {}
	if type(list) == "table" then
		local defs: { [string]: any } = kind == "Weapon" and WeaponData.Weapons or PassiveData.Passives
		for _, e in ipairs(list) do
			local def = type(e) == "table" and defs[e.Id]
			if def then
				local name = def.Name
				if e.Evolved and type(def.Evolution) == "table" and def.Evolution.Name then
					name = def.Evolution.Name
				end
				table.insert(parts, string.format("%s %d", tostring(name or e.Id), tonumber(e.Level) or 1))
			end
		end
	end
	return #parts > 0 and table.concat(parts, ", ") or "-"
end

--[[
	Readable lines for the DEV inbox. `snap` is a cleaned snapshot; `server` (optional) is
	the server's own { Wave, Weapons, Passives } and wins over the client's build.
]]
function BugSnapshotData.Lines(snap: any, server: any): { string }
	local lines = {}
	if type(snap) ~= "table" then
		return lines
	end
	local where = { "Panel " .. tostring(snap.Panel or "None") }
	if type(snap.Stage) == "number" and snap.Stage > 0 then
		table.insert(where, "stage " .. snap.Stage)
	end
	local wave = (type(server) == "table" and type(server.Wave) == "number") and server.Wave or snap.Wave
	if type(wave) == "number" and wave > 0 then
		table.insert(where, "wave " .. wave)
	end
	if type(snap.Arena) == "string" then
		local a = Config.Arenas[snap.Arena]
		table.insert(where, type(a) == "table" and tostring(a.DisplayName or snap.Arena) or snap.Arena)
	end
	if type(snap.Hero) == "string" then
		local c = CharacterData.Characters[snap.Hero]
		table.insert(where, (c and tostring(c.Name or snap.Hero) or snap.Hero) .. (type(snap.Level) == "number" and snap.Level > 0 and (" Lv " .. snap.Level) or ""))
	end
	table.insert(lines, table.concat(where, " · "))
	local useServer = type(server) == "table" and type(server.Weapons) == "table" and #server.Weapons > 0
	local src = useServer and server or snap
	local tag = useServer and "Build (server): " or "Build (client): "
	table.insert(lines, tag .. buildLine(src.Weapons, "Weapon") .. " | " .. buildLine(src.Passives, "Passive"))
	table.insert(lines, string.format(
		"%s %sx%s · text %s · %s · %s fps · place v%s",
		tostring(snap.Device or "Unknown"),
		tostring(snap.ScreenW or "?"),
		tostring(snap.ScreenH or "?"),
		tostring(snap.TextSize or "?"),
		tostring(snap.Input or "Unknown"),
		tostring(snap.Fps or "?"),
		tostring(snap.PlaceVersion or "?")
	))
	local logs = type(snap.Logs) == "table" and snap.Logs or {}
	if #logs == 0 then
		table.insert(lines, snap.LogsDropped == true and "Log: dropped (text filter failed)" or "Log: no recent warnings or errors")
	else
		for _, e in ipairs(logs) do
			table.insert(lines, string.format("[%s] %s", tostring(e.Kind), tostring(e.Text)))
		end
	end
	return lines
end

return BugSnapshotData
