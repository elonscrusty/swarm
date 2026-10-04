local process = require("@lune/process")
local Mock = require("./preview/runtime/mock")
local R, S = Mock.R, Mock.S
local preview = Mock.boot({ device = "pc", seed = 1, repo = process.cwd, root = process.cwd .. "/tools/preview", fontMetrics = nil })
local ok, err = S.runMain(function()
	preview.startClient(false)
	preview.shared("Remotes").Setup()
	local config = preview.shared("Config")
	config.Sounds.Click.MinGap = 0
	config.Audio.Categories.UI.MaxVoices = 3
	local audio = preview.client("Audio")
	audio.Init()
	audio.Play("Click")
	audio.Play("Click")
	audio.Play("Click")
	R.services.SoundService:FindFirstChild("Click2"):Stop()
	audio.Play("Click")
	local seen = {}
	for _, voice in ipairs(audio.Voices()) do
		assert(not seen[voice.Name], "restarting a pooled sound must replace its old voice record")
		seen[voice.Name] = true
	end
	audio.StopEffects()
	assert(#audio.Voices() == 0, "stopping effects clears the tracked voices")
	print("PASS pooled audio voice uniqueness and cleanup")
	-- critical sounds outrank filler and get the reserved voices
	config.Audio.MaxVoices = 6
	for _, n in ipairs({ "Hit", "EnemyDeath", "GemPickup", "Coin", "Item", "Tip", "BossWarn" }) do
		config.Sounds[n].MinGap = 0
	end
	for _, n in ipairs({ "Hit", "EnemyDeath", "GemPickup", "Coin", "Item", "Tip" }) do
		audio.Play(n)
	end
	assert(#audio.Voices() <= 6 - 3, "filler must leave the reserve free")
	audio.Play("BossWarn")
	local boss = false
	for _, v in ipairs(audio.Voices()) do
		boss = boss or v.Name:match("^BossWarn") ~= nil
	end
	assert(boss, "a boss warning must play in a crowded mix")
	assert(config.Sounds.EliteSpawn and config.Sounds.EliteSpawn.Category == "Warning", "EliteSpawn is a Warning")
	print("PASS critical warnings get reserved voices")
end, 2)
assert(ok, err)
