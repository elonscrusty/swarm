-- heroes-regression: HEROES (feature 11, docs/features/HEROES.md) against the real server.
--   solo (default):
--     1) data: Archer / Bard / Golem in Order and Characters with the switch on; start
--        weapon released, gold price on an existing tier, Store key at Id 0, signature,
--        second skill, ultimate, uploaded mesh with the hero rig, part-built fallback
--     2) unlock: BuyCharacter refuses without gold, buys with it, never twice
--     3) runs: each new hero starts with its weapon and its trait in the stat sheet
--     4) Rally Song solo: the Bard buffs itself at SelfShare, server-side; weapon damage
--        goes up by the same factor; the SongBuff attribute is published and cleared
--     5) switch off: the heroes leave Order / Characters, buying is refused, a saved
--        selection falls back to the Knight without losing the unlock
--   --set coop=on: a Duo run (Bard + Knight): the mate in range gets the full song, out of
--     range none, two Bards never stack
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

------------------------------------------------------------------------------------------
-- 1) data
------------------------------------------------------------------------------------------
local TIERS = { [10000] = true, [20000] = true, [30000] = true }
for _, id in ipairs(NEW) do
	local def = assert(CharacterData.Characters[id], "in Characters: " .. id)
	assert(table.find(CharacterData.Order, id), "in Order: " .. id)
	assert(table.find(WeaponData.Order, def.StartWeapon), "start weapon is released: " .. id)
	assert(def.Unlock == nil and TIERS[def.Cost], "earned by gold on an existing tier: " .. id)
	local path = assert(def.StoreKey, "store key: " .. id)
	local node: any = Config.Monetization
	for key in string.gmatch(path, "[^%.]+") do
		node = node[key]
	end
	assert(node == 0, "early unlock id is 0 (coming soon): " .. id)
	assert(Meta.Signature[id] and Meta.TraitValue(id, 0), "signature: " .. id)
	assert(CharacterData.SecondSkills[id] and CharacterData.Ultimates[id], "second skill + ultimate: " .. id)
	assert(CharacterData.UltimateFor(id) == CharacterData.Ultimates[id], "own ultimate, not the fallback: " .. id)
	local mesh = assert(MeshCatalog.Models[id], "mesh in the catalog: " .. id)
	assert(mesh.AssetId and mesh.AssetId > 0, "mesh uploaded: " .. id)
	assert(mesh.Joints and mesh.Joints.Neck and mesh.Joints.LeftShoulder, "hero rig joints: " .. id)
	local bones = {}
	for _, piece in ipairs(mesh.Pieces) do
		if piece.Bone == piece.Name then
			bones[piece.Name] = true
		end
	end
	for _, b in ipairs({ "Torso", "Head", "LeftArm", "RightArm", "LeftLeg", "RightLeg" }) do
		assert(bones[b], id .. " mesh bone piece " .. b)
	end
	assert(MB.ClassGear[id], "part-built fallback gear: " .. id)
	assert(#CharacterData.SkinsFor(id) >= 2, "Default + Gold Trim skins: " .. id)
end
assert(#CharacterData.Order == 11, "11 heroes with the switch on")
preview.log("PASS data: 3 heroes, tiers, store keys, signature/second/ultimate, meshes")

------------------------------------------------------------------------------------------
-- 2) unlock with gold
------------------------------------------------------------------------------------------
data.Gold = 5000
preview.remote("BuyCharacter"):FireServer("Archer")
preview.advance(0.5)
assert(not data.OwnedCharacters.Archer and data.Gold == 5000, "refused without gold")
data.Gold = 65000
for _, id in ipairs(NEW) do
	local before = data.Gold
	preview.remote("BuyCharacter"):FireServer(id)
	preview.advance(0.5)
	assert(data.OwnedCharacters[id] == true, "bought: " .. id)
	assert(data.Gold == before - CharacterData.Characters[id].Cost, "paid its price: " .. id)
	preview.remote("BuyCharacter"):FireServer(id)
	preview.advance(0.5)
	assert(data.Gold == before - CharacterData.Characters[id].Cost, "never bought twice: " .. id)
end
preview.log("PASS unlock: refused without gold, bought once at its tier")

------------------------------------------------------------------------------------------
-- 3) runs with each hero
------------------------------------------------------------------------------------------
local function startRun(hero: string)
	preview.remote("SelectCharacter"):FireServer(hero)
	preview.advance(0.3)
	assert(data.SelectedCharacter == hero, "selected " .. hero)
	preview.remote("StartRun"):FireServer("Solo")
	preview.advance(3)
	local rp = assert(RM.GetRunPlayer(me), "run player missing")
	rp.InvulnUntil = 1e9
	return rp
end
local function endRun(rp)
	RM.AbandonRun(rp)
	preview.advance(Config.Run.ResultsSeconds + 2)
	assert(not RM.IsParticipant(me), "back in the lobby")
end

local knight = startRun("Knight")
local kStats = table.clone(knight.Stats)
endRun(knight)

local rp = startRun("Archer")
assert(rp.WeaponOrder[1] == "Crossbow", "Archer starts with the Crossbow")
assert(rp.Stats.CooldownMult < kStats.CooldownMult - 0.05, "Quick Draw lowers the cooldown")
endRun(rp)

rp = startRun("Golem")
assert(rp.WeaponOrder[1] == "Earthsplitter", "Golem starts with the Earthsplitter")
assert(rp.Stats.MaxHP > kStats.MaxHP * 1.2, "Stone Body: +25% max HP")
assert(rp.Stats.Armor == kStats.Armor + 1, "Stone Body: +1 armor")
assert(rp.Stats.Speed < kStats.Speed, "Stone Body: slower")
endRun(rp)
preview.log("PASS runs: Archer Crossbow + Quick Draw, Golem Earthsplitter + Stone Body")

------------------------------------------------------------------------------------------
-- 4) Rally Song, solo
------------------------------------------------------------------------------------------
rp = startRun("Bard")
assert(rp.WeaponOrder[1] == "WarHorn", "Bard starts with the War Horn")
preview.advance(1)
local v = Song.Value(rp)
local share = CharacterData.Characters.Bard.Song.SelfShare
near(rp.SongBuff or 0, v * share, "solo Bard buffs itself at SelfShare")
assert(rp.SongBuff > 0 and rp.SongBuff < v, "solo buff is smaller than the team buff")
assert(me:GetAttribute("SongBuff") == math.floor(v * share * 100 + 0.5), "SongBuff attribute (whole percent)")
local w = rp.Weapons[rp.WeaponOrder[1]]
local withSong = WS.WeaponStats(rp, w).damage
local saved = rp.SongBuff
rp.SongBuff = 0
local without = WS.WeaponStats(rp, w).damage
rp.SongBuff = saved
near(withSong / without, 1 + saved, "weapon damage x (1 + song)")
-- the client can't change it: the value is recomputed from server state every tick
rp.SongBuff = 5
Song.Refresh()
near(rp.SongBuff, v * share, "recomputed on the server")
-- switch off mid-run: the buff and the badge go away
Config.Features.NewHeroes = false
Song.Refresh()
near(rp.SongBuff, 0, "switch off: no song")
assert(me:GetAttribute("SongBuff") == nil, "switch off: badge cleared")
Config.Features.NewHeroes = true
Song.Refresh()
endRun(rp)
Song.Refresh()
assert(me:GetAttribute("SongBuff") == nil, "badge cleared after the run")
preview.log("PASS Rally Song solo: self share, damage factor, server-side, cleared")

------------------------------------------------------------------------------------------
-- 5) switch off
------------------------------------------------------------------------------------------
data.SelectedCharacter = "Golem"
Config.Features.NewHeroes = false
CharacterData.SetNewHeroes(false)
assert(#CharacterData.Order == 8 and not CharacterData.Characters.Archer, "off: back to 8 heroes")
data.Gold = 50000
data.OwnedCharacters.Archer = nil
preview.remote("BuyCharacter"):FireServer("Archer")
preview.advance(0.5)
assert(not data.OwnedCharacters.Archer and data.Gold == 50000, "off: buying refused")
local migrated = DS.Migrate(data)
assert(migrated.SelectedCharacter == "Knight", "off: selection falls back to the Knight")
assert(migrated.OwnedCharacters.Golem == true, "off: the unlock is kept")
CharacterData.SetNewHeroes(true)
Config.Features.NewHeroes = true
assert(#CharacterData.Order == 11, "on again: 11 heroes")
preview.log("PASS switch off: hidden, not buyable, selection safe, unlock kept")
