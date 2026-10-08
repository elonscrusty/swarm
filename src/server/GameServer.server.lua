--[[
	GameServer.server.lua
	Bootstraps SWARM: creates the remotes, initialises every module in dependency order,
	then drives all per-frame systems from ONE Heartbeat connection.

	Frame order: RunManager (timer, deaths) → StageManager (portal, boss, surge, choice,
	travel) → EnemySpawner (spawns) → EnemyAI (movement,
	contact, grid rebuild) → WeaponSystem (firing, projectiles, sync) → XPSystem (gems,
	pickups) → ItemSystem (regen, shields, magnet pulses) → LootSystem (chest / shrine
	holds, the guarded altar) → CaravanEvent (the Lost Caravan defence) → LevelUpSystem (auto-pick timers) → AchievementService (run
	time / level milestones, once a second) → RunModifiers (curses / daily state for the
	lobby) → LeaderboardService (queued writes, cache refresh) → DamageNumbers (optional numbers, per player)
	→ Fx (effect batch flush).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Remotes)
local Config = require(Shared.Config)

-- Remotes must exist before any module connects to them.
Remotes.Setup()

local Modules = script.Parent:WaitForChild("Modules")

local ctx = {
	Config = Config,
	Remotes = Remotes,
}

-- Dependency order: data first, then world, then gameplay.
local ORDER = {
	"DataService",
	"DevAccess",
	"RunModifiers",
	"AccountService",
	"LeaderboardService",
	"MonetizationService",
	"GoldSystem",
	"StoreService", -- the cosmetic store: equip, gifts, earned looks (docs/features/STORE.md)
	"StarterBundle", -- one-per-account starter bundle product (docs/next/STARTER_BUNDLE.md)
	"GroupBonus", -- Roblox group member bonus at settlement + title (docs/next/GROUP_BONUS.md)
	"Prestige", -- prestige stars of maxed heroes, gold bonus at settlement (docs/next/PRESTIGE.md)
	"InviteRewards", -- invite referrals: cosmetic rewards, pending credits (docs/next/INVITE_REWARDS.md)
	"MeshService",
	"MapBuilder",
	"ModelBuilder",
	"XPSystem",
	"LevelUpSystem",
	"EnemySpawner",
	"EnemyAI",
	"WeaponSystem",
	"ItemSystem",
	"FinalStand", -- batch B: under-10% HP burst, once per stage (docs/next/FINAL_STAND.md)
	"LootSystem",
	"CaravanEvent",
	"SecretRoom", -- EXPLORE (feature 4): cracked wall + alcove (docs/features/EXPLORE.md)
	"Merchant", -- EXPLORE (feature 6): merchant cart, per-player stock for run gold
	"Rescue", -- EXPLORE (feature 8): lost villager escorted to the portal
	"MiniBoss", -- CHALLENGES (feature 3): a champion guards a big chest
	"TrialShrine", -- CHALLENGES (feature 5): Shrine of Trial
	"CursedChest", -- CHALLENGES (feature 7): cursed chest variant
	"WorldEvents", -- map events (feature 2): meteor shower, gold rush, fog
	"Weather", -- weather per world (feature 9)
	"StageManager",
	"RunManager",
	"PartyService",
	"ReviveThanks", -- THANKS! after a teammate revive (docs/next/REVIVE_THANKS.md)
	"RunServers", -- private run servers: lobby → run server → lobby teleports (live game only)
	"QuickResume", -- disconnected solo runs: hold, RESUME RUN card, settle on expiry (docs/next/QUICK_RESUME.md)
	"JournalService",
	"DiscoveryService", -- discovered weapons / passives / items / evolutions / synergies (card clues)
	"TeamPingService",
	"AchievementService",
	"DamageNumbers",
	"BugReportService",
	"Ultimate", -- hero ultimate (feature 13, HEROPOWER)
	"BuildPresets", -- favourite weapons / passives per hero (feature 14, HEROPOWER)
	"MetaService", -- META (features 1, 19, 21-25): Sigils, weekly / team boards, season, titles, collection, login streak
	"DailyQuests", -- daily quests (docs/next/DAILY_QUESTS.md)
	"ComebackGift", -- welcome-back gift (docs/next/COMEBACK_GIFT.md)
	"WeaponMastery", -- kills per weapon + mastery glow colours (feature 15, LOBBY)
	"TeamCombo", -- team combo meter + burst (feature 16, TEAM)
	"CoopBoss", -- co-op boss weak spot, BossAI variant hook (feature 18, TEAM)
	"HeroSong", -- the Bard's Rally Song team buff (feature 11, HEROES)
	"Walkthrough", -- interactive first-run walkthrough (docs/next/WALKTHROUGH.md)
}

for _, name in ipairs(ORDER) do
	ctx[name] = require(Modules:WaitForChild(name))
end
ctx.Fx = require(Modules:WaitForChild("Fx"))

for _, name in ipairs(ORDER) do
	local m = ctx[name]
	if m.Init then
		m.Init(ctx)
	end
end
for _, name in ipairs(ORDER) do
	local m = ctx[name]
	if m.Start then
		m.Start(ctx)
	end
end

-- Leaving: commit run stats first, then save + release the profile.
Players.PlayerRemoving:Connect(function(player)
	local ok, err = pcall(ctx.RunManager.OnPlayerRemoving, player)
	if not ok then
		warn("[GameServer] RunManager.OnPlayerRemoving: " .. tostring(err))
	end
	ctx.DataService.ReleasePlayer(player)
end)

ctx.DataService.ShutdownHook = function()
	ctx.RunManager.CommitAll()
end

-- The single server loop.
local STEPS = {
	{ "RunManager", ctx.RunManager.Step },
	{ "StageManager", ctx.StageManager.Step },
	{ "Walkthrough", ctx.Walkthrough.Step }, -- before EnemySpawner: its wave hold applies this frame
	{ "EnemySpawner", ctx.EnemySpawner.Step },
	{ "EnemyAI", ctx.EnemyAI.Step },
	{ "WeaponSystem", ctx.WeaponSystem.Step },
	{ "XPSystem", ctx.XPSystem.Step },
	{ "ItemSystem", ctx.ItemSystem.Step },
	{ "FinalStand", ctx.FinalStand.Step },
	{ "LootSystem", ctx.LootSystem.Step },
	{ "CaravanEvent", ctx.CaravanEvent.Step },
	{ "LevelUpSystem", ctx.LevelUpSystem.Step },
	{ "AchievementService", ctx.AchievementService.Step },
	{ "RunModifiers", ctx.RunModifiers.Step },
	{ "LeaderboardService", ctx.LeaderboardService.Step },
	{ "DamageNumbers", ctx.DamageNumbers.Step },
	{ "Ultimate", ctx.Ultimate.Step },
	{ "MetaService", ctx.MetaService.Step },
	{ "DailyQuests", ctx.DailyQuests.Step },
	{ "ComebackGift", ctx.ComebackGift.Step },
	{ "TeamCombo", ctx.TeamCombo.Step },
	{ "HeroSong", ctx.HeroSong.Step },
	{ "Fx", ctx.Fx.Step },
}
local lastError: { [string]: number } = {}

RunService.Heartbeat:Connect(function(dt)
	dt = math.min(dt, 0.1) -- a long hitch must not teleport everything
	for _, step in ipairs(STEPS) do
		local ok, err = pcall(step[2], dt)
		if not ok then
			-- keep the loop alive, but don't spam the output
			local now = os.clock()
			if now - (lastError[step[1]] or 0) > 5 then
				lastError[step[1]] = now
				warn(string.format("[GameServer] %s.Step error: %s", step[1], tostring(err)))
			end
		end
	end
end)

print(string.format("[SWARM] server ready (v%s)%s", Config.Version, ctx.DataService.IsMemoryOnly() and " - DataStores OFF, progress won't save" or ""))
