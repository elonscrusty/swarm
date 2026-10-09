--!strict
--[[
	SwarmV2/Run/RunUIConfig.lua  (ReplicatedStorage.SwarmV2.Run.RunUIConfig)
	OWNER: stream F (run UI). This is RunConfig.UI (RunConfig requires it), kept in its own file so
	the other streams' sections in RunConfig.lua never collide with it.

	Every number the run HUD, the upgrade cards, the inventory, the map, the interact prompt, the
	downed / spectate screens and the results read lives here. Colours are RunTheme (client).
	Positions are fractions of the safe area unless a name says Px; RunLayout turns them into
	rectangles and clamps them to the safe bounds.
]]

local UI = {}

------------------------------------------------------------------------------------------
-- Layout starting points (brief "Chat 2 handoff: gameplay HUD and run screens")
------------------------------------------------------------------------------------------
UI.Layout = {
	Enabled = true, -- false: the previous HUD placement (tests of the old layout)
	-- safe-area content margins (design px): the brief's 24 desktop / 12 mobile
	MarginDesktop = 24,
	MarginPhone = 12,
	-- phone starting positions: { fractionX, fractionY } of the safe area
	Phone = {
		Health = { 0.05, 0.05 }, -- top-left corner of the health plate
		Timer = { 0.50, 0.05 }, -- top-centre of the timer
		Map = { 0.82, 0.17 }, -- top-centre of the minimap
		Party = { 0.04, 0.25 }, -- top-left corner of the party stack
		Stick = { 0.16, 0.84 }, -- centre of the resting joystick
		Jump = { 0.86, 0.74 }, -- centre of JUMP
		Dash = { 0.82, 0.87 }, -- centre of DASH
	},
	-- touch control sizes in device points (what the thumb meets), not design px
	StickPx = 112,
	JumpPx = 64,
	DashPx = 64,
	RevivePx = 84, -- the touch REVIVE button above JUMP (device points)
	StickSnap = 1.5, -- a touch within this many resting radii of the resting stick starts it there
	TouchMin = 48, -- no touch target is smaller
	Gap = 8, -- smallest space kept between two HUD pieces
}

------------------------------------------------------------------------------------------
-- Equipment rows (weapons + passives)
------------------------------------------------------------------------------------------
UI.Slots = { Weapons = 4, Passives = 4 } -- used when the Inventory payload names no slot counts
UI.MaxRank = 5 -- rank pips per tile
UI.TileDesktop = 56
UI.TilePhone = 44

------------------------------------------------------------------------------------------
-- Run clock + objective strip
------------------------------------------------------------------------------------------
UI.OvertimeAt = 900 -- seconds: the timer says OVERTIME from here (15:00)
UI.BeaconAt = 750 -- seconds: the beacon opens (12:30); only used for the "opens in" line of Survive
UI.BeaconRadius = 35 -- studs: the charge radius (for the "stand in the ring" hint)
UI.BeaconActivateRadius = 20 -- studs: one living hero this close activates it
UI.ArrowEdge = 56 -- px: how far the beacon edge arrow stays from the screen edge
UI.ChargeStallSeconds = 1.2 -- BeaconCharge not rising for this long (while Charge) reads as paused

------------------------------------------------------------------------------------------
-- Minimap + big map
------------------------------------------------------------------------------------------
UI.Map = {
	ViewStuds = 200, -- studs across the small map
	RevealRadius = 80, -- studs around every team member that become known ground
	CellStuds = 12, -- the revealed-ground grid
	RevealHz = 4, -- reveal updates per second
	RasterBudget = 400, -- ground parts rasterised per frame while the arena layout is read
	RasterCells = 24000, -- ... and at most this many cell tests per frame
	BigFraction = 0.8, -- the big map's share of the short screen side
	BigKey = Enum.KeyCode.M,
	-- Cliffwood plan size when no tagged ground is found (arena name Cliffwood)
	FallbackSize = 1100,
}

------------------------------------------------------------------------------------------
-- Upgrade cards
------------------------------------------------------------------------------------------
UI.Cards = {
	Live = true, -- compact docked cards that never freeze the screen (false: the previous full-screen panel)
	SqueezeCardWidth = 150, -- narrowest a card gets when the panel must fit between the touch controls
	BodyPoints = 16, -- the body lines (current -> next) come out at this many points on a phone
	ArmSeconds = 0.35, -- a key / click held from play never confirms a card before this
	TouchArmSeconds = 0.6,
	TouchHoldSeconds = 0.6, -- a card tap must be a whole tap, lifted within this
	TouchSlop = 24, -- px a tap may drift
	DefaultSeconds = 10, -- when the payload names no deadline
	MaxCardWidth = 300,
	MinCardWidth = 168,
	RerollKey = Enum.KeyCode.R,
	-- rarity: symbol shape + word (never colour alone)
	Rarity = {
		Common = { Label = "Common", Order = 1 },
		Uncommon = { Label = "Uncommon", Order = 2 },
		Rare = { Label = "Rare", Order = 3 },
		Epic = { Label = "Epic", Order = 4 },
		Evolution = { Label = "Evolution", Order = 5 },
	},
	-- the older server rarity names the existing cards still carry
	LegacyRarity = { Legendary = "Evolution", Common = "Common", Rare = "Rare", Epic = "Epic", Uncommon = "Uncommon" },
	CategoryLabel = {
		WeaponUpgrade = "Weapon upgrade",
		PassiveUpgrade = "Passive upgrade",
		NewWeapon = "New weapon",
		NewPassive = "New passive",
		Evolution = "Evolution",
		Heal = "Heal",
	},
	-- the older server card types
	LegacyCategory = {
		WeaponUp = "WeaponUpgrade",
		PassiveUp = "PassiveUpgrade",
		WeaponNew = "NewWeapon",
		PassiveNew = "NewPassive",
		Evolve = "Evolution",
		Heal = "Heal",
		Gold = "Heal",
	},
}

------------------------------------------------------------------------------------------
-- Interact prompt (E / button / tap)
------------------------------------------------------------------------------------------
UI.Interact = {
	Key = Enum.KeyCode.E,
	PadButton = Enum.KeyCode.ButtonX,
	ReviveRange = 8, -- studs: matches the hold-revive range
	BeaconRange = 20,
	ChestRange = 9,
	ReviveHold = 3,
	BeaconHold = 1.0,
	ChestHold = 0.4,
	Poll = 0.15, -- seconds between target searches
	-- remote folder + names the prompt calls when present (stream D / E1 / E2 add them):
	-- ReplicatedStorage.SwarmV2Net.Run.<name>:FireServer(kind, targetId, holding)
	RemoteFolder = "Run",
	RemoteName = "Interact",
}

------------------------------------------------------------------------------------------
-- Downed / spectate
------------------------------------------------------------------------------------------
UI.Downed = {
	BleedSeconds = 20, -- the ring's full scale when the payload gives none
	ReviveSeconds = 3,
	InterruptedShow = 1.6, -- seconds the "Interrupted" state stays
	RevivedShow = 1.8,
}

------------------------------------------------------------------------------------------
-- Results
------------------------------------------------------------------------------------------
UI.Results = {
	SaveLabels = {
		Pending = "Pending save...",
		Saved = "Saved",
		Failed = "Save failed. This run may not be stored.",
		NotSaved = "Not saved: saving is unavailable on this server.",
	},
}

return UI
