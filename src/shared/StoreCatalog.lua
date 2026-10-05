--[[
	StoreCatalog.lua (Config.Features.Store; docs/features/STORE.md)
	The cosmetic store's own items: trails, death bursts, pets, emotes, nameplate frames and
	lobby dais themes, plus the hero early unlocks and the store sections. CosmeticData adds
	every entry here to the registry at load, so the shop, the equip remote and the visuals
	all read the same list. Data only (no require of CosmeticData: it requires this module).

	Nothing here changes a run: looks only. Store items are developer products (or, for the
	Supporter plate, the Supporter game pass) whose ids live in Config.Monetization
	(Cosmetics / CosmeticPasses / HeroUnlocks); an id of 0 shows "Coming soon". Prices always
	come from MarketplaceService:GetProductInfo, never from this file.

	Earned items carry Earn = { Stat = <data.Stats key>, At = n } or { Level = n } (account
	level). The server grants them into data.Cosmetics.Owned when the save meets the goal
	(StoreService); the shop shows the same goal with progress.
]]

local AccountData = require(script.Parent.AccountData)

local StoreCatalog = {}

-- Kinds the store equips (data.Cosmetics.Equipped keys) and the player attribute that
-- carries the worn id to every client (StoreFx draws them).
StoreCatalog.Slots = { "Trail", "Burst", "Pet", "Emote", "Nameplate", "Dais" }
StoreCatalog.Attr = {
	Trail = "CosTrail",
	Burst = "CosBurst",
	Pet = "CosPet",
	Emote = "CosEmote",
	Nameplate = "CosPlate",
	Dais = "CosDais",
}

-- Shop sections, in order (MenuStore). Kind = the CosmeticData kind listed there.
StoreCatalog.Sections = {
	{ Id = "Skins", Title = "Skins", Kind = "Skin", Icon = "sparkle" },
	{ Id = "Trails", Title = "Trails", Kind = "Trail", Icon = "arrowFast" },
	{ Id = "Bursts", Title = "Death bursts", Kind = "Burst", Icon = "VolatileSpore" },
	{ Id = "Pets", Title = "Pets", Kind = "Pet", Icon = "heart" },
	{ Id = "Emotes", Title = "Emotes and poses", Kind = "Emote", Icon = "people2" },
	{ Id = "Plates", Title = "Nameplates", Kind = "Nameplate", Icon = "flag" },
	{ Id = "Dais", Title = "Lobby dais", Kind = "Dais", Icon = "area" },
	{ Id = "Supporter", Title = "Supporter", Icon = "crown" },
	{ Id = "Heroes", Title = "Hero early unlocks", Icon = "helmet" },
	{ Id = "Gift", Title = "Gift", Icon = "gift" },
}

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

--[[
	Entries (CosmeticData shape + Look / Earn / Desc). Look:
	  Trail      Color, Color2 (tail), Width
	  Burst      Color (tint), Mix (0..1 how much of the tint replaces the creature colour),
	             Neon (glowing chunks), Colors (confetti: chunks cycle through these)
	  Pet        Shape (StoreFx builder), Color, Color2
	  Emote      Icon (Icons name), Color, Pose ("Wave" | "Cheer" | "Flex" | "Bow")
	  Nameplate  Color, Color2, Glow
	  Dais       Color (stone), Color2 (trim), Material, Glow
]]
StoreCatalog.Entries = {
	-- Trails
	{ Id = "Trail_Ember", Kind = "Trail", Name = "Ember Trail", Source = "Store", StoreKey = "Cosmetics.Trail_Ember", Desc = "A warm ember streak behind your hero.", Look = { Color = rgb(255, 122, 44), Color2 = rgb(255, 214, 96), Width = 1.1 } },
	{ Id = "Trail_Frost", Kind = "Trail", Name = "Frost Trail", Source = "Store", StoreKey = "Cosmetics.Trail_Frost", Desc = "A cold blue mist behind your hero.", Look = { Color = rgb(130, 205, 255), Color2 = rgb(236, 250, 255), Width = 1.1 } },
	{ Id = "Trail_Royal", Kind = "Trail", Name = "Royal Trail", Source = "Store", StoreKey = "Cosmetics.Trail_Royal", Desc = "Violet and gold, fit for a crown.", Look = { Color = rgb(168, 108, 255), Color2 = rgb(255, 212, 92), Width = 1.2 } },
	{ Id = "Trail_Leaf", Kind = "Trail", Name = "Leaf Trail", Source = "Earned", Earn = { Stat = "Runs", At = 25 }, Desc = "Green leaves swirl behind you.", Look = { Color = rgb(118, 196, 92), Color2 = rgb(214, 240, 150), Width = 1.0 } },
	{ Id = "Trail_Star", Kind = "Trail", Name = "Starlight Trail", Source = "Earned", Earn = { Level = 15 }, Desc = "A pale starlit line.", Look = { Color = rgb(240, 236, 255), Color2 = rgb(150, 170, 255), Width = 0.9 } },
	-- Death bursts (how enemy deaths burst on YOUR screen; HitFeel draws them)
	{ Id = "Burst_Confetti", Kind = "Burst", Name = "Confetti Burst", Source = "Store", StoreKey = "Cosmetics.Burst_Confetti", Desc = "Foes pop into bright confetti.", Look = { Color = rgb(255, 120, 170), Mix = 1, Colors = { rgb(255, 92, 120), rgb(255, 212, 80), rgb(96, 210, 255), rgb(140, 230, 120), rgb(200, 140, 255) } } },
	{ Id = "Burst_Void", Kind = "Burst", Name = "Void Burst", Source = "Store", StoreKey = "Cosmetics.Burst_Void", Desc = "Foes crack into glowing violet shards.", Look = { Color = rgb(150, 80, 255), Mix = 0.75, Neon = true } },
	{ Id = "Burst_Frost", Kind = "Burst", Name = "Frost Burst", Source = "Store", StoreKey = "Cosmetics.Burst_Frost", Desc = "Foes shatter like ice.", Look = { Color = rgb(170, 225, 255), Mix = 0.8, Neon = true } },
	{ Id = "Burst_Gold", Kind = "Burst", Name = "Gold Burst", Source = "Earned", Earn = { Stat = "TotalKills", At = 25000 }, Desc = "Foes burst into gold flakes.", Look = { Color = rgb(255, 205, 72), Mix = 0.8, Neon = false } },
	-- Pets (follow the hero; no stats, no pickup help)
	{ Id = "Pet_Fox", Kind = "Pet", Name = "Ember Fox", Source = "Store", StoreKey = "Cosmetics.Pet_Fox", Desc = "A little fox that trots after you.", Look = { Shape = "Fox", Color = rgb(232, 112, 46), Color2 = rgb(250, 238, 220) } },
	{ Id = "Pet_Owl", Kind = "Pet", Name = "Snow Owl", Source = "Store", StoreKey = "Cosmetics.Pet_Owl", Desc = "A round owl that flies at your shoulder.", Look = { Shape = "Owl", Color = rgb(236, 238, 245), Color2 = rgb(255, 196, 64) } },
	{ Id = "Pet_Drake", Kind = "Pet", Name = "Little Drake", Source = "Store", StoreKey = "Cosmetics.Pet_Drake", Desc = "A tiny dragon on small wings.", Look = { Shape = "Drake", Color = rgb(70, 160, 110), Color2 = rgb(255, 200, 90) } },
	{ Id = "Pet_Slime", Kind = "Pet", Name = "Moss Slime", Source = "Earned", Earn = { Stat = "Wins", At = 10 }, Desc = "A friendly slime that hops along.", Look = { Shape = "Slime", Color = rgb(120, 200, 90), Color2 = rgb(40, 60, 40) } },
	{ Id = "Pet_Wisp", Kind = "Pet", Name = "Lantern Wisp", Source = "Earned", Earn = { Stat = "BestStage", At = 6 }, Desc = "A floating lantern light.", Look = { Shape = "Wisp", Color = rgb(255, 214, 120), Color2 = rgb(120, 90, 60) } },
	-- Emotes and poses (shown over your hero; the lobby and the run)
	{ Id = "Emote_Wave", Kind = "Emote", Name = "Wave", Source = "Earned", Earn = { Stat = "Runs", At = 1 }, Desc = "Say hello.", Look = { Icon = "people2", Color = rgb(255, 230, 160), Pose = "Wave" } },
	{ Id = "Emote_Cheer", Kind = "Emote", Name = "Cheer", Source = "Store", StoreKey = "Cosmetics.Emote_Cheer", Desc = "A burst of stars and a cheer.", Look = { Icon = "sparkle", Color = rgb(255, 212, 80), Pose = "Cheer" } },
	{ Id = "Emote_Flex", Kind = "Emote", Name = "Victory Flex", Source = "Store", StoreKey = "Cosmetics.Emote_Flex", Desc = "Show the swarm who won.", Look = { Icon = "trophy", Color = rgb(255, 170, 70), Pose = "Flex" } },
	{ Id = "Emote_Bow", Kind = "Emote", Name = "Bow", Source = "Earned", Earn = { Stat = "Wins", At = 3 }, Desc = "A polite bow.", Look = { Icon = "crown", Color = rgb(220, 200, 255), Pose = "Bow" } },
	-- Nameplate frames (the plate over your hero)
	{ Id = "Plate_Gold", Kind = "Nameplate", Name = "Gilded Plate", Source = "Store", StoreKey = "Cosmetics.Plate_Gold", Desc = "A gold frame around your name.", Look = { Color = rgb(255, 206, 84), Color2 = rgb(120, 82, 20) } },
	{ Id = "Plate_Ember", Kind = "Nameplate", Name = "Ember Plate", Source = "Store", StoreKey = "Cosmetics.Plate_Ember", Desc = "A red-hot frame around your name.", Look = { Color = rgb(255, 110, 60), Color2 = rgb(110, 30, 20) } },
	{ Id = "Plate_Ivy", Kind = "Nameplate", Name = "Ivy Plate", Source = "Earned", Earn = { Level = 10 }, Desc = "Green vines around your name.", Look = { Color = rgb(130, 200, 100), Color2 = rgb(30, 60, 30) } },
	{ Id = "Plate_Supporter", Kind = "Nameplate", Name = "Supporter Plate", Source = "Store", StoreKey = "CosmeticPasses.Supporter", Desc = "A glowing gold plate. Comes with the Supporter pass.", Look = { Color = rgb(255, 222, 120), Color2 = rgb(150, 96, 20), Glow = true } },
	-- META (docs/features/META.md): earned on the free season track and the login streak.
	-- MetaService puts them in Cosmetics.Owned (no Earn goal here), worn like any plate.
	{ Id = "Nameplate_Ember", Kind = "Nameplate", Name = "Ember Frame", Source = "Earned", Condition = "Season tier 5", Desc = "A season frame of warm embers.", Look = { Color = rgb(240, 130, 70), Color2 = rgb(90, 36, 20) } },
	{ Id = "Nameplate_Frost", Kind = "Nameplate", Name = "Frost Frame", Source = "Earned", Condition = "Season tier 15", Desc = "A season frame of cold light.", Look = { Color = rgb(140, 200, 255), Color2 = rgb(24, 52, 86) } },
	{ Id = "Nameplate_Royal", Kind = "Nameplate", Name = "Royal Frame", Source = "Earned", Condition = "Season tier 25", Desc = "A violet season frame.", Look = { Color = rgb(190, 140, 255), Color2 = rgb(56, 32, 96) } },
	{ Id = "Nameplate_Dawn", Kind = "Nameplate", Name = "Dawn Frame", Source = "Earned", Condition = "Login streak of 14 days", Desc = "For showing up, day after day.", Look = { Color = rgb(255, 214, 120), Color2 = rgb(96, 64, 24) } },
	-- Lobby dais themes (under your hero in the menu)
	{ Id = "Dais_Marble", Kind = "Dais", Name = "Marble Dais", Source = "Earned", Earn = { Stat = "Wins", At = 5 }, Desc = "White marble with a gold edge.", Look = { Color = rgb(236, 232, 224), Color2 = rgb(214, 172, 70), Material = "Marble" } },
	{ Id = "Dais_Obsidian", Kind = "Dais", Name = "Obsidian Dais", Source = "Store", StoreKey = "Cosmetics.Dais_Obsidian", Desc = "Black glass with violet light.", Look = { Color = rgb(30, 26, 40), Color2 = rgb(160, 100, 255), Material = "Glass", Glow = true } },
	{ Id = "Dais_Sunfire", Kind = "Dais", Name = "Sunfire Dais", Source = "Store", StoreKey = "Cosmetics.Dais_Sunfire", Desc = "Warm stone ringed with fire light.", Look = { Color = rgb(150, 70, 40), Color2 = rgb(255, 170, 60), Material = "Slate", Glow = true } },
	{ Id = "Dais_Grove", Kind = "Dais", Name = "Grove Dais", Source = "Earned", Earn = { Stat = "BestStage", At = 8 }, Desc = "Mossy stone with small flowers.", Look = { Color = rgb(96, 120, 80), Color2 = rgb(250, 220, 120), Material = "Slate" } },
}

-- The heroes that may be unlocked early with Robux. Only heroes that are ALSO earned by
-- play (HeroEarnable: an achievement or a gold price) are ever offered; a hero not in CharacterData
-- yet shows "Coming soon".
StoreCatalog.HeroUnlocks = { "Archer", "Bard", "Golem" }

-- True for a hero definition that is earned by play: an achievement unlock or a gold
-- price (gold comes from runs). The store only sells an early unlock of such a hero.
function StoreCatalog.HeroEarnable(def: any): boolean
	if type(def) ~= "table" then
		return false
	end
	local unlock = def.Unlock
	if type(unlock) == "table" and type(unlock.Achievement) == "string" then
		return true
	end
	return type(def.Cost) == "number" and def.Cost > 0
end

-- The Supporter pass (Config.Monetization.CosmeticPasses.Supporter).
StoreCatalog.Supporter = {
	Name = "Supporter",
	Desc = "A gold SUPPORTER badge, a glowing nameplate and a lobby banner. Looks only.",
	Plate = "Plate_Supporter",
}

local byId: { [string]: any } = {}
for _, e in ipairs(StoreCatalog.Entries) do
	byId[e.Id] = e
end

function StoreCatalog.Get(id: string): any
	return byId[id]
end

-- Current progress toward an Earn goal: (have, need). data = a save or the lobby profile
-- (both carry Stats and Account.XP).
function StoreCatalog.Progress(earn: any, data: any): (number, number)
	if type(earn) ~= "table" or type(data) ~= "table" then
		return 0, 1
	end
	if earn.Level then
		local account = type(data.Account) == "table" and data.Account or {}
		local level = AccountData.LevelFor(tonumber(account.XP) or 0)
		return level, earn.Level
	end
	local stats = type(data.Stats) == "table" and data.Stats or {}
	return math.floor(tonumber(stats[earn.Stat]) or 0), earn.At or 1
end

-- True when the save meets the entry's Earn goal.
function StoreCatalog.Earned(id: string, data: any): boolean
	local e = byId[id]
	if not e or e.Source ~= "Earned" or type(e.Earn) ~= "table" then
		return false
	end
	local have, need = StoreCatalog.Progress(e.Earn, data)
	return have >= need
end

local STAT_TEXT = {
	Runs = "Play %s runs",
	Wins = "Win %s runs",
	TotalKills = "Defeat %s foes",
	BestStage = "Reach stage %s",
}

local function commas(n: number): string
	local s = tostring(math.floor(n))
	while true do
		local k
		s, k = string.gsub(s, "^(-?%d+)(%d%d%d)", "%1,%2")
		if k == 0 then
			break
		end
	end
	return s
end

-- Short goal text ("Win 10 runs", "Reach account level 15").
function StoreCatalog.ConditionText(earn: any): string
	if type(earn) ~= "table" then
		return ""
	end
	if earn.Level then
		return "Reach account level " .. earn.Level
	end
	if earn.Stat == "Runs" and earn.At == 1 then
		return "Play your first run"
	end
	return string.format(STAT_TEXT[earn.Stat] or (tostring(earn.Stat) .. " %s"), commas(earn.At or 0))
end

-- The Earned entries get their Condition text from the goal (CosmeticData shows it).
for _, e in ipairs(StoreCatalog.Entries) do
	if e.Source == "Earned" and not e.Condition then
		e.Condition = StoreCatalog.ConditionText(e.Earn)
	end
end

return StoreCatalog
