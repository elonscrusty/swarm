--[[
	BugReportData.lua
	Shared rules for player bug reports (client form, server BugReportService, DEV inbox).
	Nothing here is secret: the DEV allowlist lives on the server only
	(ServerScriptService.Modules.DevAllowlist).

	Pure helpers (no Roblox services) so both sides clean text and context the same way.
	The server never trusts what the client sends: it cleans everything again with these
	helpers, re-derives the run context itself and keeps the client's numbers apart.
]]

local BugReportData = {}

BugReportData.MaxLength = 500 -- characters of the report text
BugReportData.MinLength = 8 -- shorter than this is not a usable report
BugReportData.CooldownSeconds = 60 -- one report per player per minute (all servers)
BugReportData.PerDay = 10 -- reports per player per UTC day (all servers)
BugReportData.PageSize = 8 -- DEV inbox rows per page

-- DataStore names; Studio uses its own stores so test reports never mix with live ones.
BugReportData.StoreName = "SwarmBugReports_v1"
BugReportData.IndexName = "SwarmBugIndex_v1"
BugReportData.StudioSuffix = "_Studio"

-- Categories shown on the form (Id is stored, Title is shown).
BugReportData.Categories = {
	{ Id = "Gameplay", Title = "Game" },
	{ Id = "Visual", Title = "Visual" },
	{ Id = "Performance", Title = "Lag" },
	{ Id = "Controls", Title = "Input" },
	{ Id = "Other", Title = "Other" },
}

-- Inbox statuses (only a DEV can change them).
BugReportData.Statuses = { "New", "Seen", "Fixed", "WontFix" }
BugReportData.StatusTitles = { New = "New", Seen = "Seen", Fixed = "Fixed", WontFix = "Won't fix" }

BugReportData.Devices = { "Phone", "Tablet", "Desktop", "Console", "VR", "Unknown" }

function BugReportData.IsCategory(id: any): boolean
	if type(id) ~= "string" then
		return false
	end
	for _, c in ipairs(BugReportData.Categories) do
		if c.Id == id then
			return true
		end
	end
	return false
end

function BugReportData.IsStatus(s: any): boolean
	return type(s) == "string" and table.find(BugReportData.Statuses, s) ~= nil
end

-- Report ids are "<unix ms>_<userId>" (the server makes them).
function BugReportData.IsReportId(id: any): boolean
	return type(id) == "string" and #id <= 40 and string.match(id, "^%d+_%d+$") ~= nil
end

--[[
	Cleans report text: must be valid UTF-8, control characters (except new lines) become
	spaces, runs of blank lines collapse, ends are trimmed. Returns the text, or nil and a
	reason the player can read.
]]
function BugReportData.CleanText(raw: any): (string?, string?)
	if type(raw) ~= "string" then
		return nil, "Write what happened first."
	end
	if #raw > BugReportData.MaxLength * 4 then -- 4 bytes per character at most
		return nil, string.format("Keep it under %d characters.", BugReportData.MaxLength)
	end
	if utf8.len(raw) == nil then
		return nil, "That text has characters we can't read."
	end
	local s = string.gsub(raw, "\r\n?", "\n")
	s = string.gsub(s, "[\0-\9\11-\31\127]", " ")
	s = string.gsub(s, "\n%s*\n[%s\n]*", "\n\n")
	s = string.gsub(s, "^%s+", "")
	s = string.gsub(s, "%s+$", "")
	local n = utf8.len(s) or 0
	if n < BugReportData.MinLength then
		return nil, "Add a few more words so we can find the bug."
	end
	if n > BugReportData.MaxLength then
		return nil, string.format("Keep it under %d characters.", BugReportData.MaxLength)
	end
	return s, nil
end

-- A short safe token: letters, digits, dot, dash, underscore; nil when empty or wrong type.
function BugReportData.Token(v: any, maxLen: number): string?
	if type(v) ~= "string" then
		return nil
	end
	local s = string.sub(string.gsub(v, "[^%w%.%-_]", ""), 1, maxLen)
	return s ~= "" and s or nil
end

-- A whole number in [lo, hi]; nil when not a finite number.
function BugReportData.Int(v: any, lo: number, hi: number): number?
	if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
		return nil
	end
	return math.clamp(math.floor(v), lo, hi)
end

--[[
	What the client reported about itself, cleaned: only known keys, short tokens and
	clamped numbers. Stored apart from the server's own context ("Client" field) and
	shown as "client says" in the inbox.
]]
function BugReportData.CleanClientContext(ctx: any): { [string]: any }
	local out: { [string]: any } = {}
	if type(ctx) ~= "table" then
		return out
	end
	local device = BugReportData.Token(ctx.Device, 12)
	out.Device = (device and table.find(BugReportData.Devices, device)) and device or "Unknown"
	out.Version = BugReportData.Token(ctx.Version, 16)
	out.Stage = BugReportData.Int(ctx.Stage, 0, 999)
	out.Level = BugReportData.Int(ctx.Level, 0, 9999)
	out.Arena = BugReportData.Token(ctx.Arena, 24)
	out.Character = BugReportData.Token(ctx.Character, 24)
	out.Screen = BugReportData.Token(ctx.Screen, 12) -- "1280x720"
	return out
end

-- "Stage 2 · Swamp · Ranger · Lv 14" style line from a context table (missing parts skipped).
function BugReportData.ContextLine(c: { [string]: any }?): string
	if type(c) ~= "table" then
		return ""
	end
	local parts = {}
	if c.InRun == false then
		table.insert(parts, "Lobby")
	elseif type(c.Stage) == "number" and c.Stage > 0 then
		table.insert(parts, "Stage " .. tostring(c.Stage))
	end
	for _, key in ipairs({ "Arena", "Character" }) do
		if type(c[key]) == "string" and c[key] ~= "" then
			table.insert(parts, c[key])
		end
	end
	if type(c.Level) == "number" and c.Level > 0 then
		table.insert(parts, "Lv " .. tostring(c.Level))
	end
	if type(c.Device) == "string" then
		table.insert(parts, c.Device)
	end
	if type(c.Version) == "string" then
		table.insert(parts, "v" .. c.Version)
	end
	return table.concat(parts, " · ")
end

return BugReportData
