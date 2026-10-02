--!nocheck
--[[
	R.luau - the preview runtime's shared table.

	Every mock module adds its pieces here (R.D datatypes, R.S scheduler, R.Signal,
	R.new / R.state for instances, R.classes, R.layout, R.text, ...), so modules can
	reference each other without require cycles. One process = one runtime.
]]

local R = {
	options = {}, -- device profile, seed, paths (filled by init)
	log = { errors = {}, warnings = {}, fired = {}, notes = {} },
}

-- Messages printed once with a repeat count (per-frame errors would flood the output).
local seen: { [string]: { count: number, entry: any } } = {}

local function record(kind: string, msg: string, extra: string?)
	local key = kind .. "|" .. msg
	local s = seen[key]
	if s then
		s.count += 1
		s.entry.count = s.count
		return
	end
	local entry = { kind = kind, message = msg, detail = extra, count = 1 }
	seen[key] = { count = 1, entry = entry }
	local list = kind == "error" and R.log.errors or (kind == "warn" and R.log.warnings or R.log.notes)
	table.insert(list, entry)
	if kind == "error" then
		print("\27[31m[preview:error]\27[0m " .. msg .. (extra and ("\n" .. extra) or ""))
	elseif kind == "warn" then
		print("\27[33m[preview:warn]\27[0m " .. msg)
	else
		print("[preview] " .. msg)
	end
end

function R.error(msg: string, traceback: string?)
	record("error", msg, traceback)
end

function R.warn(msg: string)
	record("warn", msg)
end

-- Notes: approximations / substitutions the renderer made (listed in the scene report).
function R.note(msg: string)
	local key = "note|" .. msg
	if seen[key] then
		return
	end
	seen[key] = { count = 1, entry = msg }
	table.insert(R.log.notes, msg)
end

return R
