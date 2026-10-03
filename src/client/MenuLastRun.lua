--[[
	MenuLastRun.lua
	The lobby home's LAST RUN card: one compact row (result and stage, hero / mode /
	difficulty / time, kills and gold kept) built from the saved profile's LastRun (RunManager writes it
	when a run ends, DataService sanitises it, ProfileSync carries it) and a RETRY button.

	RETRY is the same validated start as the SOLO / DUO / TRIO buttons: it fires the
	StartRun remote with a mode name and the server decides (RunManager.startRun: lobby
	phase, party leader / READY rules through PartyService.StartBlocked, run servers,
	the current character, difficulty, curses and the ENDLESS switch). The client only
	explains in advance what it can see: a party member cannot start, a party plays its
	own size, the Daily has its own screen. LobbyScreen places the card (relayout) and
	hides it while a countdown or a run replaces the mode buttons.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local CharacterData = require(Shared:WaitForChild("CharacterData"))
local DifficultyData = require(Shared:WaitForChild("DifficultyData"))
local UIKit = require(script.Parent.UIKit)
local MenuParty = require(script.Parent.MenuParty)

local MenuLastRun = {}
local C, P = Theme.Color, Theme.Palette

export type Card = {
	Frame: Frame,
	Has: () -> boolean, -- the profile has a last run to show
	Refresh: (profile: { [string]: any }?) -> (),
	SetWidth: (w: number) -> (),
}

-- "Stage 3" for a run that ended on stage 3 (0 = never reached one).
local function stageText(last: { [string]: any }): string
	local stage = tonumber(last.Stage) or 0
	return stage > 0 and ("Stage " .. stage) or "Stage 1"
end

function MenuLastRun.Build(parent: Instance, ctx: { [string]: any }): Card
	local holder, face = UIKit.Surface(parent, {
		Name = "LastRun",
		Radius = Theme.Radius.M,
		Transparency = 0.12,
		Edge = C.PanelEdge,
		EdgeTransparency = Theme.Alpha.Edge,
		Visible = false,
	})
	local profile: { [string]: any }? = nil
	local buttonW = 112
	-- three short lines: the result, the run (hero / mode / difficulty / time), the haul
	local column = UIKit.new("Frame", { Name = "Text", BackgroundTransparency = 1, Position = UDim2.fromOffset(16, 0), Size = UDim2.new(1, -(16 + buttonW + 22), 1, 0) }, face)
	local lineH = { UIKit.TS(12) + 4, UIKit.TS(14) + 4, UIKit.TS(13) + 4 }
	local textH = lineH[1] + lineH[2] + lineH[3] + 2
	local title = UIKit.text(column, "Label", "", {
		Name = "Title",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, -textH / 2 + lineH[1] / 2),
		Size = UDim2.new(1, 0, 0, lineH[1]),
		TextColor3 = P.gold_300,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, 12)
	local sub = UIKit.text(column, "Small", "", {
		Name = "Summary",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, -textH / 2 + lineH[1] + 1 + lineH[2] / 2),
		Size = UDim2.new(1, 0, 0, lineH[2]),
		TextColor3 = P.ivory_100,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, 14)
	local haul = UIKit.text(column, "Small", "", {
		Name = "Haul",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, textH / 2 - lineH[3] / 2),
		Size = UDim2.new(1, 0, 0, lineH[3]),
		TextColor3 = P.ivory_300,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, 13)

	local function toast(str: string, color: Color3?)
		if ctx.Toast then
			ctx.Toast(str, color)
		end
	end

	-- RETRY: the mode of the last run through the same remote as the mode buttons, with the
	-- party rules the server would answer with explained first (it still decides).
	local function retry()
		local last = profile and profile.LastRun
		if type(last) ~= "table" then
			return
		end
		local mode = type(last.Mode) == "string" and last.Mode or "Solo"
		if mode == "Daily" then
			-- the Daily's scored try / practice is decided on its own screen (its START button
			-- is the validated path for it)
			ctx.ShowScreen("Daily")
			toast("Your last run was the Daily Challenge: start it from here.", P.gold_300)
			return
		end
		if not table.find(Config.Modes.Order, mode) then
			-- a mode no longer offered in the lobby (old saves): the closest start is SOLO
			toast(string.format("%s runs are no longer offered: starting SOLO instead.", string.upper(mode)), P.gold_300)
			mode = "Solo"
		end
		local party = MenuParty.Summary()
		if party.Count > 0 then
			if not party.Leader then
				toast("Your party leader starts the runs (or leave the party).", P.gold_300)
				return
			end
			local partyMode = MenuParty.PartyMode()
			if partyMode and partyMode ~= mode then
				local def = (Config.Modes :: any)[partyMode]
				toast(string.format("Your party of %d plays %s: starting that instead.", party.Count, string.upper(def and def.DisplayName or partyMode)), P.gold_300)
				mode = partyMode
			end
		end
		local now = DifficultyData.Selected(profile)
		if last.Difficulty ~= now and DifficultyData.Tiers[now] then
			toast(string.format("Difficulty is set to %s now (your last run was %s).", string.upper(DifficultyData.Tiers[now].Name), string.upper(tostring(last.Difficulty))), P.gold_300)
		end
		Remotes.Get("StartRun"):FireServer(mode)
	end

	local button = UIKit.Button(face, {
		Kind = "Outline",
		Title = "RETRY",
		Icon = "cycle",
		IconSize = 20,
		TitleStyle = "Label",
		TitleSize = 14,
		Align = "Center",
		Name = "Retry",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.fromOffset(buttonW, Theme.Size.TapMin),
		OnClick = retry,
	})

	local function refresh(p: { [string]: any }?)
		profile = p
		local last = p and p.LastRun
		if type(last) ~= "table" then
			return
		end
		local won = last.Won == true
		local fell = not won and type(last.DeathCause) == "string"
		local modeDef = (Config.Modes :: any)[last.Mode]
		local modeName = modeDef and modeDef.DisplayName or tostring(last.Mode or "Solo")
		if won then
			title.Text = UIKit.track("LAST RUN · VICTORY")
			title.TextColor3 = P.gold_300
		elseif fell then
			title.Text = UIKit.track(string.upper("LAST RUN · FELL ON " .. stageText(last)))
			title.TextColor3 = P.crimson_300
		else
			title.Text = UIKit.track(string.upper("LAST RUN · LEFT ON " .. stageText(last)))
			title.TextColor3 = P.ivory_300
		end
		local hero = CharacterData.Characters[last.CharacterId]
		local tier = DifficultyData.Tiers[last.Difficulty]
		sub.Text = table.concat({
			hero and hero.Name or "Hero",
			modeName,
			tier and tier.Name or "Standard",
			UIKit.formatTime(tonumber(last.Time) or 0),
		}, " · ")
		local parts = {
			UIKit.formatNumber(tonumber(last.Kills) or 0) .. " kills",
			"+" .. UIKit.formatNumber(tonumber(last.Gold) or 0) .. " gold",
		}
		haul.Text = table.concat(parts, " · ")
	end

	return {
		Frame = holder,
		Has = function(): boolean
			return profile ~= nil and type(profile.LastRun) == "table"
		end,
		Refresh = refresh,
		SetWidth = function(w: number)
			-- narrow cards (phones) keep RETRY to its icon-less core and give the text room
			local bw = w < 420 and 92 or 112
			if bw ~= buttonW then
				buttonW = bw
				button.Instance.Size = UDim2.fromOffset(bw, Theme.Size.TapMin)
				button.SetIcon(bw >= 112 and "cycle" or nil)
				column.Size = UDim2.new(1, -(16 + bw + 22), 1, 0)
			end
		end,
	}
end

return MenuLastRun
