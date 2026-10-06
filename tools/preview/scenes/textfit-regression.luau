-- textfit-regression: the player's Roblox Text size setting on a phone (docs/MOBILE_FIX.md).
-- Run on iphone (Largest by default, the owner's phone):
--   lune run tools/preview/runtime/main.luau -- --scene textfit-regression --device iphone --out <json>
-- Checks, as PASS / FAIL lines:
--   * TextFit is on and settles (nothing pending) after the lobby screens open
--   * every managed label either fits or is back at its designed size (no cut text from growth)
--   * some labels did grow (the setting is honoured where there is room)
--   * the CHARACTERS header clears Roblox's top-bar buttons (TopbarInset X space)
--   * the home ACCOUNT pill sits in the top-bar row, not below it
--   * the Arenas list gets a scroll hint
--   * at Medium (--set textsize=Medium) TextFit adds nothing
local C = lib("common")
C.lobby()
C.startClient()
local p = C.profile({ Gold = 20927, Account = { XP = 2350 } })
p.Stats.BestStage = 4
C.sendProfile(p)
C.settle(2)
local fails = 0
local function check(ok: boolean, label: string, detail: string?)
	if not ok then
		fails += 1
	end
	preview.log(string.format("%s %s%s", ok and "PASS" or "FAIL", label, detail and (" (" .. detail .. ")") or ""))
end
local TextFit = preview.client("TextFit")
local LS = preview.client("LobbyScreen")
local medium = preview.args.textsize == "Medium"

local function audit(screenName: string)
	local frame = preview.findGui(function(g)
		return g:IsA("Frame") and g.Name == screenName and g.Parent and g.Parent.Name == "Screens"
	end)[1]
	local managed, grown, bad = 0, 0, {}
	if frame then
		for _, d in ipairs(frame:GetDescendants()) do
			if (d:IsA("TextLabel") or d:IsA("TextButton")) and preview.isShown(d) and d.Text ~= "" then
				local own = d:FindFirstChild("TextFit")
				if own then
					managed += 1
					local designed = math.floor(d.TextSize + 0.5)
					if own.MaxTextSize > designed then
						grown += 1
						if not d.TextFits then
							table.insert(bad, d.Name .. " '" .. string.sub(d.Text, 1, 24) .. "'")
						end
					end
				end
			end
		end
	end
	return managed, grown, bad
end

-- counted while each screen is shown (audit only sees shown labels)
local totalGrown = 0
for _, name in ipairs({ "Party", "Daily", "Arenas", "Characters", "Play", "Track" }) do
	LS.Show(name)
	C.settle(1.5)
	local managed, grown, bad = audit(name)
	totalGrown += grown
	if medium then
		check(managed == 0, name .. ": TextFit idle at Medium", managed .. " managed")
	else
		check(managed > 0, name .. ": labels are managed", managed .. " managed, " .. grown .. " grown")
		check(#bad == 0, name .. ": every grown label fits", table.concat(bad, ", "))
	end
end
local stats = TextFit.Stats()
check(stats.Pending == 0, "TextFit settled", stats.Watched .. " watched, " .. stats.Pending .. " pending")
if not medium then
	check(totalGrown > 0, "the setting is honoured where there is room", totalGrown .. " labels above their design size")
end

-- top-bar clearance (the device's TopbarInset X space)
LS.Show("Characters")
C.settle(1.5)
local back = preview.findGui(function(g)
	return g:IsA("GuiButton") and g.Name == "Back" and preview.isShown(g) and g:FindFirstAncestor("Characters") ~= nil
end)[1]
local dev = preview.device
local clear = 0
for _, b in ipairs(dev.coreButtons or {}) do
	clear = math.max(clear, b.x + b.w)
end
if back then
	local fx = preview.findGui(function(g) return g:IsA("ScreenGui") and g.Name == "SwarmFx" end)[1]
	local x = back.AbsolutePosition.X - (fx and fx.AbsolutePosition.X or 0)
	check(clear == 0 or x >= clear or back.AbsolutePosition.Y - (fx and fx.AbsolutePosition.Y or 0) >= 56, "CHARACTERS BACK clears the Roblox buttons", string.format("x %.0f, buttons end %.0f", x, clear))
else
	check(false, "CHARACTERS BACK found")
end
LS.Show("Home")
C.settle(1.5)
local pill = preview.findGui(function(g) return g:IsA("GuiButton") and g.Name == "AccountPill" and preview.isShown(g) end)[1]
if pill then
	local fx = preview.findGui(function(g) return g:IsA("ScreenGui") and g.Name == "SwarmFx" end)[1]
	local y = pill.AbsolutePosition.Y - (fx and fx.AbsolutePosition.Y or 0)
	check(not dev.topbarSafeSpace or y < 40, "home ACCOUNT pill in the top-bar row", string.format("top %.0f", y))
end
LS.Show("Arenas")
C.settle(1.5)
local hint = preview.findGui(function(g) return g.Name:match("Hint$") ~= nil and g:IsA("Frame") and g:FindFirstAncestor("Arenas") ~= nil end)[1]
check(hint ~= nil, "Arenas list has a scroll hint")
LS.Show("Home")
C.settle(0.5)
preview.log(fails == 0 and "PASS textfit-regression" or ("FAIL textfit-regression: " .. fails .. " failed"))
