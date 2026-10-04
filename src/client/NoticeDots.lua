--[[
	NoticeDots.lua
	Small glowing gold dots that point players at something new on the lobby: the HEROES,
	SHOP and MORE tiles on the home screen, and the matching rows inside MORE.

	Each dot id has a "reason key" (a string listing what is new, "" = nothing). A dot
	shows while its key is not empty and differs from the key the player last saw; viewing
	the screen / row marks the current key seen, so the dot only comes back when something
	NEW appears (another hero becomes affordable, a new achievement, the next day's daily).
	"Seen" lives in this client session only (no save field, no schema change). Things
	that were already true at the first profile of a session (old achievements, the
	account level) are the baseline and never dot.

	Event-driven: Refresh runs on ProfileSync and when the party invite count changes; no
	per-frame work. The halo pulse is a single looping tween per visible dot, played only
	while the dot is shown; with reduced effects the dot is static.

	Ids: Heroes, Shop, More (home tiles); Daily, Party, Achievements, Track (MORE rows).
]]

local TweenService = game:GetService("TweenService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Theme = require(Shared:WaitForChild("Theme"))
local CharacterData = require(Shared:WaitForChild("CharacterData"))
local MetaUpgradeData = require(Shared:WaitForChild("MetaUpgradeData"))
local AccountData = require(Shared:WaitForChild("AccountData"))
local UIKit = require(script.Parent.UIKit)
local ClientSettings = require(script.Parent.ClientSettings)
local ClientPerformance = require(script.Parent.ClientPerformance)
local MenuDaily = require(script.Parent.MenuDaily)

local NoticeDots = {}

local P = Theme.Palette
local new = UIKit.new

type Dot = { Frame: Frame, Halo: Frame, Scale: UIScale, Tween: Tween? }

local dots: { [string]: { Dot } } = {}
local keys: { [string]: string } = {}
local seen: { [string]: string } = {}
local MORE_ROWS = { "Daily", "Party", "Achievements", "Track" }

-- session baseline (first profile): only what changes after it counts as new
local baseline: { Ach: { [string]: boolean }, Owned: { [string]: boolean }, Level: number }? = nil
local lastProfile: { [string]: any }? = nil
local lastInvites = 0

local function reduced(): boolean
	return ClientSettings.Reduced() or ClientPerformance.Reduced()
end

local stopPulse: (Dot) -> ()

local function startPulse(d: Dot)
	stopPulse(d)
	if reduced() then
		d.Scale.Scale = 1.2
		d.Halo.BackgroundTransparency = 0.6
		return
	end
	d.Scale.Scale = 1
	d.Halo.BackgroundTransparency = 0.45
	local info = TweenInfo.new(1.4, Enum.EasingStyle.Sine, Enum.EasingDirection.Out, -1, false)
	local t = TweenService:Create(d.Scale, info, { Scale = 1.9 })
	local t2 = TweenService:Create(d.Halo, info, { BackgroundTransparency = 1 })
	t:Play()
	t2:Play()
	d.Tween = t
	;(d :: any).Tween2 = t2
end

stopPulse = function(d: Dot)
	if d.Tween then
		d.Tween:Cancel()
		d.Tween = nil
	end
	local t2 = (d :: any).Tween2
	if t2 then
		t2:Cancel()
		;(d :: any).Tween2 = nil
	end
end

local function apply(id: string)
	local on = (keys[id] or "") ~= "" and keys[id] ~= seen[id]
	for _, d in ipairs(dots[id] or {}) do
		if d.Frame.Visible ~= on then
			d.Frame.Visible = on
			if on then
				startPulse(d)
			else
				stopPulse(d)
			end
		end
	end
end

-- Puts a dot on `parent` (top-right corner by default). props override the frame's.
function NoticeDots.Attach(id: string, parent: Instance, props: { [string]: any }?): Frame
	local size = 12
	local f = new("Frame", {
		Name = "NoticeDot",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -12, 0, 12),
		Size = UDim2.fromOffset(size, size),
		ZIndex = 5,
		Visible = false,
	}, parent)
	local halo = new("Frame", {
		Name = "Halo",
		BackgroundColor3 = P.gold_300,
		BackgroundTransparency = 0.5,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1.6, 1.6),
		ZIndex = 5,
	}, f)
	UIKit.corner(halo, 999)
	local scale = Instance.new("UIScale")
	scale.Parent = halo
	local core = new("Frame", {
		Name = "Core",
		BackgroundColor3 = P.gold_300,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 6,
	}, f)
	UIKit.corner(core, 999)
	UIKit.stroke(core, P.gold_900, 1.5, 0.2)
	if props then
		for k, v in pairs(props) do
			(f :: any)[k] = v
		end
	end
	dots[id] = dots[id] or {}
	table.insert(dots[id], { Frame = f, Halo = halo, Scale = scale })
	apply(id)
	return f
end

local function setKey(id: string, key: string)
	keys[id] = key
	apply(id)
end

-- MORE tile: the unseen rows' keys together.
local function updateMore()
	local parts = {}
	for _, id in ipairs(MORE_ROWS) do
		local k = keys[id] or ""
		if k ~= "" and k ~= seen[id] then
			table.insert(parts, id .. "=" .. k)
		end
	end
	setKey("More", table.concat(parts, ";"))
end

-- The player looked at this screen / row: its current reasons are seen.
function NoticeDots.MarkSeen(id: string)
	seen[id] = keys[id] or ""
	apply(id)
	if table.find(MORE_ROWS, id) then
		updateMore()
	end
end

function NoticeDots.Visible(id: string): boolean
	return (keys[id] or "") ~= "" and keys[id] ~= seen[id]
end

local function sortedJoin(list: { string }): string
	table.sort(list)
	return table.concat(list, ",")
end

-- Recomputes every dot from the profile (ProfileSync) and the party invite count.
function NoticeDots.Refresh(p: { [string]: any }?, invites: number?)
	p = p or lastProfile
	lastProfile = p
	lastInvites = invites or lastInvites
	if not p then
		return
	end
	local gold = tonumber(p.Gold) or 0
	local owned = type(p.OwnedCharacters) == "table" and p.OwnedCharacters or {}
	local ach = type(p.Achievements) == "table" and type(p.Achievements.Unlocked) == "table" and p.Achievements.Unlocked or {}
	local level = type(p.Account) == "table" and tonumber(p.Account.Level) or 1
	if not baseline then
		local b = { Ach = {}, Owned = {}, Level = level or 1 }
		for id in pairs(ach) do
			b.Ach[id] = true
		end
		for id, v in pairs(owned) do
			b.Owned[id] = v == true
		end
		baseline = b
	end
	local base = baseline :: any

	-- HEROES: a hero buyable with current gold, a hero an achievement just unlocked, a
	-- Hero Mastery upgrade the selected hero can buy
	local heroes = {}
	for _, id in ipairs(CharacterData.Order) do
		local def = CharacterData.Characters[id]
		if def then
			local own = owned[id] == true
			if not own and not def.Unlock and (def.Cost or 0) > 0 and gold >= def.Cost then
				table.insert(heroes, "buy:" .. id)
			elseif own and def.Unlock and not base.Owned[id] then
				table.insert(heroes, "new:" .. id)
			end
		end
	end
	local sel = type(p.SelectedCharacter) == "string" and p.SelectedCharacter or CharacterData.Default
	if owned[sel] == true then
		local hx = type(p.Heroes) == "table" and type(p.Heroes[sel]) == "table" and p.Heroes[sel].XP or 0
		local mastery = MetaUpgradeData.MasteryFor(hx)
		local track = type(p.HeroUpgrades) == "table" and type(p.HeroUpgrades[sel]) == "table" and p.HeroUpgrades[sel] or {}
		for _, up in ipairs(MetaUpgradeData.HeroOrder()) do
			if MetaUpgradeData.HeroDef(sel, up) then
				local lv = math.floor(tonumber(track[up]) or 0)
				local cost = MetaUpgradeData.HeroCostOf(sel, up, lv)
				if cost and lv + 1 <= MetaUpgradeData.HeroCap(mastery, up, sel) and gold >= cost then
					table.insert(heroes, "up:" .. sel .. ":" .. up .. ":" .. lv)
				end
			end
		end
	end
	setKey("Heroes", sortedJoin(heroes))

	-- SHOP: an account upgrade (Revive / Reroll / Skip) the player can afford
	local shop = {}
	local meta = type(p.Meta) == "table" and p.Meta or {}
	for _, id in ipairs(MetaUpgradeData.AccountOrder) do
		local lv = tonumber(meta[id]) or 0
		local cost = MetaUpgradeData.CostOf(id, lv)
		if cost and gold >= cost then
			table.insert(shop, id .. ":" .. lv)
		end
	end
	setKey("Shop", sortedJoin(shop))

	-- MORE rows
	local used = MenuDaily.Status(p)
	setKey("Daily", (type(p.Daily) == "table" and not used) and ("day:" .. tostring(MenuDaily.Today())) or "")
	setKey("Party", lastInvites > 0 and ("inv:" .. lastInvites) or "")
	local newAch = {}
	for id in pairs(ach) do
		if not base.Ach[id] then
			table.insert(newAch, id)
		end
	end
	setKey("Achievements", sortedJoin(newAch))
	local rewards = (level or 1) > base.Level and #AccountData.RewardsBetween(base.Level, level :: number) > 0
	setKey("Track", rewards and ("lv:" .. tostring(level)) or "")
	updateMore()
end

-- The party invite count changed (LobbyScreen watches MenuParty.Summary).
function NoticeDots.SetInvites(n: number)
	if n ~= lastInvites then
		NoticeDots.Refresh(nil, n)
	end
end

-- Reduced effects switched: restart / freeze the visible pulses.
ClientSettings.OnChanged(function(key)
	if key ~= "ReducedEffects" then
		return
	end
	for _, list in pairs(dots) do
		for _, d in ipairs(list) do
			if d.Frame.Visible then
				startPulse(d)
			end
		end
	end
end)

return NoticeDots
