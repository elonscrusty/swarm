--[[
	CosmeticData.lua
	The cosmetics registry: every look a player can own, by kind, and how it is obtained.
	Data only (docs/features/FOUNDATION.md); the STORE and META features fill it and the
	server validates ownership. Nothing here changes a run's power.

	Kinds: Skin, Trail, Burst, Pet, Emote, Nameplate, Dais, Title.

	Entry: { Id, Kind, Name, Source, Condition?, StoreKey?, Character? }
	  Source = "Default"  everyone has it
	         | "Earned"   by play; Condition is the short text shown to the player
	         | "Store"    Robux; StoreKey names the Config.Monetization entry
	                      ("SkinPasses.Knight_Crimson", "Cosmetics.Trail_Ember"); an id of 0
	                      means the owner has not created it yet: the shop says "Coming soon"
	A cosmetic may be both earned and sold only if the earned path is real (Condition).

	Where the worn choice is saved: Skin → data.Skins[heroId], Title → data.Title,
	the other kinds → data.Cosmetics.Equipped[Kind]. Owned: data.Cosmetics.Owned (bought /
	earned ones), skins through their passes (MonetizationService.OwnedSkins), titles in
	data.Titles.Owned or from achievements / the level track.

	Existing skins and titles are listed here automatically from CharacterData,
	AchievementData and AccountData so the registry starts complete.
]]

local Config = require(script.Parent.Config)
local CharacterData = require(script.Parent.CharacterData)
local AchievementData = require(script.Parent.AchievementData)
local AccountData = require(script.Parent.AccountData)

local CosmeticData = {}

CosmeticData.Kinds = { "Skin", "Trail", "Burst", "Pet", "Emote", "Nameplate", "Dais", "Title" }

export type Entry = {
	Id: string,
	Kind: string,
	Name: string,
	Source: string, -- "Default" | "Earned" | "Store"
	Condition: string?,
	StoreKey: string?,
	Character: string?,
	Weapon: boolean?, -- a weapon mastery glow (feature 15): worn per weapon, not in a slot
}

CosmeticData.Items = {} :: { [string]: Entry }
CosmeticData.Order = {} :: { string }

-- Adds an entry (STORE / META call this from their data). Ids are unique across kinds.
function CosmeticData.Add(e: Entry)
	assert(table.find(CosmeticData.Kinds, e.Kind), "CosmeticData: unknown kind " .. tostring(e.Kind))
	assert(e.Source == "Default" or e.Source == "Earned" or e.Source == "Store", "CosmeticData: bad source for " .. e.Id)
	if not CosmeticData.Items[e.Id] then
		table.insert(CosmeticData.Order, e.Id)
	end
	CosmeticData.Items[e.Id] = e
end

------------------------------------------------------------------------------------------
-- Defaults ("None" for every slot kind)
------------------------------------------------------------------------------------------

for _, kind in ipairs({ "Trail", "Burst", "Pet", "Emote", "Nameplate", "Dais" }) do
	CosmeticData.Add({ Id = kind .. "_None", Kind = kind, Name = "None", Source = "Default" })
end

------------------------------------------------------------------------------------------
-- STORE items (StoreCatalog.lua: trails, bursts, pets, emotes, plates, dais themes)
------------------------------------------------------------------------------------------

for _, e in ipairs(require(script.Parent.StoreCatalog).Entries) do
	CosmeticData.Add(e)
end

------------------------------------------------------------------------------------------
-- Weapon mastery trail colours (feature 15, docs/features/LOBBY.md): earned per weapon by
-- kills with it (Config.WeaponMastery.Milestones). Weapon = true: worn per weapon through the
-- WEAPON MASTERY menu (SetMasteryGlow), never in the Equipped.Trail slot; the server derives
-- ownership from the save's WeaponMastery counts.
------------------------------------------------------------------------------------------

for _, m in ipairs(Config.WeaponMastery.Milestones) do
	CosmeticData.Add({ Id = m.Id, Kind = "Trail", Name = m.Name, Source = "Earned", Condition = string.format("%d kills with one weapon", m.Kills), Weapon = true })
end

------------------------------------------------------------------------------------------
-- Existing skins (skin passes, the Starter Pack trim)
------------------------------------------------------------------------------------------

local function sortedKeys(t: { [string]: any }): { string }
	local keys = {}
	for k in pairs(t) do
		table.insert(keys, k)
	end
	table.sort(keys)
	return keys
end

for _, id in ipairs(sortedKeys(CharacterData.Skins)) do
	local skin = CharacterData.Skins[id]
	CosmeticData.Add({
		Id = id,
		Kind = "Skin",
		Name = skin.Name,
		Source = "Store",
		-- the Starter Bundle skin has no store key of its own (the bundle is the product)
		StoreKey = skin.Pass == "StarterPack" and "GamePasses.StarterPack" or skin.Pass == "StarterBundle" and "StarterBundle.Skin" or ("SkinPasses." .. id),
		Character = skin.Character,
	})
end

------------------------------------------------------------------------------------------
-- Existing titles (achievements and the level track)
------------------------------------------------------------------------------------------

for _, id in ipairs(sortedKeys(AchievementData.Achievements)) do
	local def = AchievementData.Achievements[id]
	local title = def.Reward and def.Reward.Title
	if type(title) == "string" and not CosmeticData.Items["Title_" .. title] then
		CosmeticData.Add({ Id = "Title_" .. title, Kind = "Title", Name = title, Source = "Earned", Condition = "Achievement: " .. (def.Name or id) })
	end
end
for _, level in ipairs(AccountData.RewardLevels) do
	for _, r in ipairs(AccountData.Rewards[level]) do
		if r.Kind == "Title" and not CosmeticData.Items["Title_" .. r.Id] then
			CosmeticData.Add({ Id = "Title_" .. r.Id, Kind = "Title", Name = r.Id, Source = "Earned", Condition = "Account level " .. level })
		end
	end
end

------------------------------------------------------------------------------------------
-- META (docs/features/META.md): milestone / season / streak titles and nameplate frames,
-- all earned by play (MetaData)
------------------------------------------------------------------------------------------

for _, e in ipairs(require(script.Parent.MetaData).CosmeticEntries()) do
	if not CosmeticData.Items[e.Id] then
		CosmeticData.Add(e :: any)
	end
end

------------------------------------------------------------------------------------------
-- Queries
------------------------------------------------------------------------------------------

function CosmeticData.Get(id: string): Entry?
	return CosmeticData.Items[id]
end

-- Every entry of one kind, in registry order.
-- Is `skinId` a skin of one of the 11 hidden old heroes? Such skins stay in saves (owned ones keep
-- working) but are not offered in the Store or a skin picker. Unknown ids are not legacy.
function CosmeticData.IsLegacySkin(skinId: any): boolean
	local skin = type(skinId) == "string" and CharacterData.Skins[skinId] or nil
	if not skin then
		return false
	end
	local ok, ClassCatalog = pcall(function()
		return require((game:GetService("ReplicatedStorage") :: any):WaitForChild("SwarmV2"):WaitForChild("ClassCatalog"))
	end)
	return ok and (ClassCatalog :: any).IsLegacyId((skin :: any).Character) == true
end

function CosmeticData.OfKind(kind: string): { Entry }
	local out = {}
	for _, id in ipairs(CosmeticData.Order) do
		local e = CosmeticData.Items[id]
		if e.Kind == kind then
			table.insert(out, e)
		end
	end
	return out
end

-- The Robux id behind a Store entry (0 = not created yet / not a store item).
function CosmeticData.StoreId(id: string): number
	local e = CosmeticData.Items[id]
	if not e or e.Source ~= "Store" or type(e.StoreKey) ~= "string" then
		return 0
	end
	local group, key = string.match(e.StoreKey, "^(%w+)%.(.+)$")
	local t = group and (Config.Monetization :: any)[group]
	local value = type(t) == "table" and t[key] or nil
	return type(value) == "number" and value or 0
end

-- True for a Store entry the owner has not created yet (shown as "Coming soon").
function CosmeticData.ComingSoon(id: string): boolean
	local e = CosmeticData.Items[id]
	return e ~= nil and e.Source == "Store" and CosmeticData.StoreId(id) == 0
end

return CosmeticData
