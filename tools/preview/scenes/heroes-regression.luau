-- heroes-regression: the hero roster after the redesign against the real server.
--   solo (default):
--     1) roster: CharacterData.Order is the 12 classes (RunConfig.Classes.Order); the 11 old
--        heroes (Archer / Bard / Golem of feature 11 included) are hidden but keep their
--        Characters entries (docs/redesign/DECISIONS.md 2026-10-08 and C1)
--     2) a hidden hero is never bought (BuyCharacter), selected or upgraded: gold untouched
--     3) an old save keeps its unlock, hero upgrades and selection; its run plays the
--        default class (RunConfig.Classes.MapLegacyToDefault)
--   --set coop=on: the Rally Song code (HeroSong) on a Duo run (Bard + Knight forced on the
--     run players): the mate in range gets the full song, out of range none, two Bards never stack
-- Every check errors on failure.
local Players = game:GetService("Players")
local me = Players.LocalPlayer
local A = preview.args
local coop = A.coop == "on"
if coop then
	preview.addPlayer("Mate2", 2)
	local T = preview.teleport()
	T.placeId, T.privateServerId, T.privateServerOwnerId = 4242, "ps-heroes", 0
	local ticket = { SwarmRun = { V = 1, Mode = "Duo", Members = { 1, 2 }, Starter = 1, Arena = "Forest" } }
	T.joinData[1] = ticket
	T.joinData[2] = ticket
end
local Config = preview.shared("Config")
Config.Features.NewHeroes = true
local CharacterData = preview.shared("CharacterData")
CharacterData.SetNewHeroes(true)
local Meta = preview.shared("MetaUpgradeData")
local WeaponData = preview.shared("WeaponData")
local MeshCatalog = preview.shared("MeshCatalog")
local NEW = { "Archer", "Bard", "Golem" }

preview.startServer()
preview.advance(2)
local RM = preview.server("RunManager")
local DS = preview.server("DataService")
local WS = preview.server("WeaponSystem")
local Song = preview.server("HeroSong")
local MB = preview.server("ModelBuilder")

local function near(a: number, b: number, what: string)
	assert(math.abs(a - b) < 1e-6, what .. ": " .. tostring(a) .. " vs " .. tostring(b))
end

if coop then
	----------------------------------------------------------------------------------
	-- co-op: the song reaches the mate in range, not out of range, and never stacks
	----------------------------------------------------------------------------------
	for _, p in ipairs(Players:GetPlayers()) do
		local d = assert(DS.GetData(p), "profile")
		d.OwnedCharacters.Bard = true
		d.SelectedCharacter = p == me and "Bard" or "Knight"
	end
	preview.advance(3)
	local rps = RM.GetRunPlayers()
	assert(#rps == 2, "duo run players: " .. #rps)
	local bard, mate
	for _, r in ipairs(rps) do
		r.InvulnUntil = 1e9
		if r.Player == me then bard = r else mate = r end
	end
	if bard.CharacterId ~= "Bard" then
		-- the run may keep the lobby pick from before: set the heroes the test needs
		bard.CharacterId = "Bard"
	end
	local v = Song.Value(bard)
	near(v, 0.12 + 0.02 * (bard.Meta and bard.Meta.Signature or 0), "song value")
	local share = CharacterData.Characters.Bard.Song.SelfShare
	local radius = CharacterData.Characters.Bard.Song.Radius
	local base = bard.Root.Position
	mate.Root.CFrame = CFrame.new(base + Vector3.new(radius - 4, 0, 0))
	Song.Refresh()
	near(mate.SongBuff, v, "mate in range: full song")
	near(bard.SongBuff, v * share, "the Bard: its own share")
	assert(mate.Player:GetAttribute("SongBuff") == math.floor(v * 100 + 0.5), "mate badge attribute")
	mate.Root.CFrame = CFrame.new(base + Vector3.new(radius + 6, 0, 0))
	Song.Refresh()
	near(mate.SongBuff, 0, "mate out of range: no song")
	assert(mate.Player:GetAttribute("SongBuff") == nil, "mate badge cleared")
	-- two Bards side by side: each keeps the best single value (no stacking)
	mate.CharacterId = "Bard"
	mate.Root.CFrame = CFrame.new(base + Vector3.new(3, 0, 0))
	Song.Refresh()
	near(mate.SongBuff, v, "two Bards: the mate gets one song")
	assert(bard.SongBuff <= math.max(v, Song.Value(mate)) + 1e-9, "two Bards never stack")
	-- a downed / dead Bard sings nothing
	mate.CharacterId = "Knight"
	bard.Alive = false
	Song.Refresh()
	near(mate.SongBuff, 0, "a dead Bard gives no song")
	bard.Alive = true
	preview.log("PASS co-op Rally Song: in range, out of range, no stacking, dead Bard")
	return
end

local data = assert(DS.GetData(me), "profile missing")
local RunConfig = preview.require(game:GetService("ReplicatedStorage").SwarmV2.Run.RunConfig)
local LEGACY = { "Knight", "Mage", "Rogue", "Priest", "Ranger", "Alchemist", "Engineer", "Necromancer", "Archer", "Bard", "Golem" }

------------------------------------------------------------------------------------------
-- 1) roster: the twelve classes are listed; the 11 old heroes (Archer / Bard / Golem too)
--    are hidden, their entries kept so old saves still load (docs/redesign/DECISIONS.md)
------------------------------------------------------------------------------------------
assert(#CharacterData.Order == 12 and #RunConfig.Classes.Order == 12, "12 classes listed: " .. #CharacterData.Order)
for i, id in ipairs(RunConfig.Classes.Order) do
	assert(CharacterData.Order[i] == id, "class order " .. i .. ": " .. tostring(CharacterData.Order[i]))
	assert(CharacterData.Characters[id], "class entry: " .. id)
end
for _, id in ipairs(LEGACY) do
	assert(not table.find(CharacterData.Order, id), "old hero hidden from Order: " .. id)
	assert(CharacterData.Characters[id], "old hero entry kept for saves: " .. id)
end
assert(CharacterData.Default == RunConfig.Classes.Default, "default class: " .. tostring(CharacterData.Default))
preview.log("PASS roster: the 12 classes listed, the 11 old heroes hidden, their entries kept")

------------------------------------------------------------------------------------------
-- 2) a hidden hero is never bought, selected or upgraded (gold untouched)
------------------------------------------------------------------------------------------
data.Gold = 65000
for _, id in ipairs(NEW) do
	data.OwnedCharacters[id] = nil
	preview.remote("BuyCharacter"):FireServer(id)
	preview.advance(0.6)
	assert(not data.OwnedCharacters[id] and data.Gold == 65000, "hidden hero not sold: " .. id)
end
data.OwnedCharacters.Golem = true -- an unlock bought before the redesign
local selected = data.SelectedCharacter
preview.remote("SelectCharacter"):FireServer("Golem")
preview.advance(0.6)
assert(data.SelectedCharacter == selected, "hidden hero not selectable")
preview.remote("BuyHeroUpgrade"):FireServer("Golem", "MaxHP", 0)
preview.advance(0.6)
assert(data.Gold == 65000 and not (data.HeroUpgrades.Golem and data.HeroUpgrades.Golem.MaxHP), "hidden hero not upgraded")
preview.log("PASS hidden heroes: never bought, selected or upgraded")

------------------------------------------------------------------------------------------
-- 3) an old save: unlock, upgrades and selection stay untouched; its run plays the default
------------------------------------------------------------------------------------------
data.SelectedCharacter = "Golem"
data.HeroUpgrades.Golem = { MaxHP = 2 }
local migrated = DS.Migrate(data)
assert(migrated.OwnedCharacters.Golem == true, "old unlock kept")
assert(migrated.HeroUpgrades.Golem and migrated.HeroUpgrades.Golem.MaxHP == 2, "old hero upgrades kept")
assert(migrated.SelectedCharacter == "Golem", "old selection left as it is")
preview.remote("StartRun"):FireServer("Solo")
preview.advance(3)
local rp = assert(RM.GetRunPlayer(me), "run player missing")
rp.InvulnUntil = 1e9
assert(rp.CharacterId == RunConfig.Classes.Default, "a saved old hero plays the default class: " .. tostring(rp.CharacterId))
RM.AbandonRun(rp)
preview.advance(Config.Run.ResultsSeconds + 2)
assert(not RM.IsParticipant(me), "back in the lobby")
assert(data.OwnedCharacters.Golem == true and data.SelectedCharacter == "Golem" and data.HeroUpgrades.Golem.MaxHP == 2, "after the run: old save fields untouched")
preview.log("PASS old saves: unlock, upgrades and selection kept; the run plays " .. RunConfig.Classes.Default)
