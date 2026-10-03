-- Real result UI: bounded, latest-first damage review and wrapped mobile layout.
local C = lib("common")
C.lobby()
C.startClient()
C.sendProfile()
C.setState({ Phase = "Results" })
C.setPlayer({ InRun = true, Alive = false })
local history = {}
for i = 1, 8 do table.insert(history, { Cause = "Hit " .. i, Damage = i + 0.2, Time = 90 + i }) end
local data = { Won = false, Portal = false, Time = 100, Kills = 42, Gold = 25, GoldEarned = 100, GoldLost = 75,
	Difficulty = "Standard", DeathCause = "Scorpion Queen claw strike", Level = 5, Damage = 300, Arena = "Forest (Duo)",
	Mode = "Duo", CharacterId = "Mage", Build = {}, BossKills = 0, BossFight = true, Seconds = 25,
	StagesCleared = 0, Stage = 1, Items = {}, DamageHistory = history }
C.fire("RunResult", data)
C.settle(0.5)
local label = assert(preview.findGui("Settlement")[1], "settlement must exist")
assert(string.find(label.Text, "Recent damage (latest first):", 1, true))
assert(not string.find(label.Text, "Hit 2", 1, true), "older than six hits must be excluded")
assert(string.find(label.Text, "Hit 8", 1, true) < string.find(label.Text, "Hit 3", 1, true), "latest damage appears first")
assert(string.find(label.Text, "-9 HP", 1, true), "damage rounds visibly upward")
assert(label.Size.Y.Offset >= 8 * (label.TextSize + 5), "result text grows for all damage rows")
data.Won, data.Portal = true, true
C.fire("RunResult", data)
C.settle(0.1)
assert(not string.find(label.Text, "Recent damage", 1, true), "victory hides death review")
data.Won, data.Portal = false, false
C.fire("RunResult", data)
C.settle(0.5)
preview.log("PASS damage review ordering, six-hit limit, victory hiding and responsive text height")
