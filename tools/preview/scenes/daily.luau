-- daily: the lobby DAILY CHALLENGE screen (today's route, curses, bonus, your attempt).
--   --set used=on   today's scored attempt is used (score shown, PRACTICE button)
local C = lib("common")
C.lobby()
C.startClient()
local CurseData = C.shared("CurseData")
local day = CurseData and CurseData.DayOf(os.time()) or 0
local used = preview.args.used == "on"
C.setState({ DailyDay = day })
C.sendProfile(C.profile({
	Daily = {
		Day = day,
		Used = used,
		Score = used and CurseData.DailyScore(3, 552, 700) or 0,
		Plays = used and 1 or 0,
		BestScore = CurseData.DailyScore(4, 801, 900),
		BestDay = day - 3,
	},
	Account = { XP = 2350 },
}))
C.settle(1)
local button = C.findText("^%s*DAILY", "GuiButton")
if button then
	preview.click(button)
else
	preview.warn("daily scene: no DAILY button")
end
C.settle(2)
if used and preview.args.rank then
	local score = CurseData.DailyScore(3, 552, 700)
	local rank = tonumber(preview.args.rank)
	C.fire("LeaderboardData", { Board = "Daily", Day = day, Status = "ok", Age = 0, MyRank = rank, MyBest = score, Rows = { { Me = true, Rank = rank, Value = score } } })
	C.settle(1)
end

-- --set travel=on: the go-home notice (bottom-right) over the open Daily screen: it shows and ticks
-- live, GO NOW / STAY send the same remotes as before, the panel stays clear of it, and the notice
-- goes away with the attribute (--set details=on also opens "How scoring works").
if preview.args.details == "on" then
	local toggle = C.findText("^%s*How scoring works", "GuiButton") or preview.findGui(function(o) return o.Name == "ScoringToggle" end)[1]
	if toggle then
		preview.click(toggle)
		C.settle(0.5)
	else
		preview.log("FAIL daily scene: no scoring toggle")
	end
end
if preview.args.travel == "on" then
	local sent = {}
	preview.remote("TravelHome").OnServerEvent:Connect(function(_p, arg)
		table.insert(sent, tostring(arg))
	end)
	local TO = preview.client("TravelOverlay")
	TO.Init()
	C.setPlayer({ TravelHomeIn = 11 })
	C.settle(1)
	local d = TO.Debug()
	preview.log((d.Banner and "PASS" or "FAIL") .. " notice visible", d.BannerText)
	preview.log((d.BannerText == "Return to lobby in 11s" and "PASS" or "FAIL") .. " notice text")
	C.setPlayer({ TravelHomeIn = 10 })
	C.settle(1)
	preview.log((TO.Debug().BannerText == "Return to lobby in 10s" and "PASS" or "FAIL") .. " notice ticks live", TO.Debug().BannerText)
	local panel = preview.findGui(function(o) return o.Name == "Panel" and o.Parent and o.Parent.Name == "Daily" end)[1]
	local note = preview.findGui(function(o) return o.Name == "HomeBanner" end)[1]
	if panel and note then
		local pb, nt = panel.AbsolutePosition.Y + panel.AbsoluteSize.Y, note.AbsolutePosition.Y
		preview.log((pb <= nt and "PASS" or "FAIL") .. " daily panel clear of the notice", string.format("panel bottom %.0f, notice top %.0f", pb, nt))
	else
		preview.log("WARN could not find the daily panel / notice for the overlap check")
	end
	local function inNotice(name: string)
		return preview.findGui(function(o)
			return o.Name == name and o:FindFirstAncestor("HomeBanner") ~= nil
		end)[1]
	end
	local go, stay = inNotice("GoNow"), inNotice("Stay")
	if go and stay then
		preview.click(go)
		C.settle(0.6)
		preview.click(stay)
		C.settle(0.3)
		preview.log((table.concat(sent, ",") == "Go,Stay" and "PASS" or "FAIL") .. " GO NOW / STAY remotes", table.concat(sent, ","))
	else
		preview.log("FAIL notice buttons missing")
	end
	C.setPlayer({ TravelHomeIn = 9 })
	C.settle(0.5)
	preview.log("render held on the notice at 9s")
end
