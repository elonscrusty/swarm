--[[
	DamageText.lua
	Optional floating damage numbers (Settings > Damage numbers, off by default).

	The server (DamageNumbers.lua) sums this player's hits per enemy a few times a second
	and sends them only while the setting is on. Here they become small numbers over the
	enemies, with hard limits so a swarm never turns into a wall of text:
	  * one number per enemy: a new hit on an enemy whose number is still fresh
	    (MergeSeconds) adds to it and pops it again instead of making a second one
	  * at most MaxNewPerFrame new numbers per frame (the rest wait a frame or two, then
	    are dropped if they are too old) and at most MaxLabels on screen (the oldest goes)
	  * crits are gold, larger and end with "!" (never colour alone)
	Reduced effects: numbers don't rise or pop, they just fade.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local EnemyRenderer = require(script.Parent.EnemyRenderer)
local ClientSettings = require(script.Parent.ClientSettings)

local DamageText = {}

local D = Config.DamageNumbers
local P = Theme.Palette
local player = Players.LocalPlayer

type Label = { Gui: BillboardGui, Text: TextLabel, Stroke: UIStroke, Id: number, Amount: number, Crit: boolean, Born: number, Hit: number, Base: Vector3 }

local folder: Folder? = nil
local anchor: BasePart? = nil -- every number hangs off this part at the world origin
local live: { Label } = {}
local spare: { Label } = {}
local byEnemy: { [number]: Label } = {}
local pending: { { Id: number, Amount: number, Crit: boolean, At: number } } = {}

local function format(n: number): string
	if n >= 10000 then
		return string.format("%.1fk", n / 1000)
	end
	return tostring(math.floor(n + 0.5))
end

local function newLabel(): Label
	local gui = Instance.new("BillboardGui")
	gui.Name = "DamageNumber"
	gui.Size = UDim2.fromOffset(90, 30)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 220
	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui.Adornee = anchor
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Size = UDim2.fromScale(1, 1)
	t.FontFace = Theme.Font.Number
	t.TextScaled = false
	t.TextSize = 18
	t.TextColor3 = P.ivory_100
	t.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Color = P.slate_950
	stroke.Thickness = 2
	stroke.Transparency = 0.15
	stroke.Parent = t
	gui.Parent = folder
	return { Gui = gui, Text = t, Stroke = stroke, Id = 0, Amount = 0, Crit = false, Born = 0, Hit = 0, Base = Vector3.zero }
end

local function release(l: Label)
	l.Gui.Enabled = false
	if byEnemy[l.Id] == l then
		byEnemy[l.Id] = nil
	end
	table.insert(spare, l)
end

local function style(l: Label)
	l.Text.Text = format(l.Amount) .. (l.Crit and "!" or "")
	l.Text.TextColor3 = l.Crit and P.gold_300 or P.ivory_100
	l.Text.TextSize = l.Crit and 22 or 18
end

local function spawnLabel(id: number, amount: number, crit: boolean, now: number): boolean
	local pos = EnemyRenderer.Position(id)
	if not pos then
		return false
	end
	local l = table.remove(spare) or newLabel()
	if #live >= D.MaxLabels then
		local oldest = table.remove(live, 1)
		if oldest then
			release(oldest)
		end
	end
	l.Id, l.Amount, l.Crit, l.Born, l.Hit = id, amount, crit, now, now
	-- a little sideways jitter so neighbours don't stack perfectly
	l.Base = pos + Vector3.new((math.random() - 0.5) * 1.2, 2.2, (math.random() - 0.5) * 0.6)
	l.Gui.StudsOffsetWorldSpace = l.Base
	l.Gui.Enabled = true
	style(l)
	table.insert(live, l)
	byEnemy[id] = l
	return true
end

local function onNumbers(data: any)
	if type(data) ~= "table" or ClientSettings.Get("DamageNumbers") ~= true or player:GetAttribute("InRun") ~= true then
		return
	end
	local now = os.clock()
	for i = 1, #data - 2, 3 do
		local id, amount, crit = tonumber(data[i]), tonumber(data[i + 1]), data[i + 2] == 1
		if id and amount and amount > 0 then
			local l = byEnemy[id]
			if l and now - l.Hit < D.MergeSeconds then
				-- merge into the number still on screen
				l.Amount += amount
				l.Crit = l.Crit or crit
				l.Hit = now
				l.Born = math.max(l.Born, now - 0.15)
				style(l)
			else
				table.insert(pending, { Id = id, Amount = amount, Crit = crit, At = now })
			end
		end
	end
end

local function step()
	local now = os.clock()
	-- new numbers, a few per frame
	local made = 0
	while #pending > 0 and made < D.MaxNewPerFrame do
		local p = table.remove(pending, 1)
		if p and now - p.At < 0.3 then
			local l = byEnemy[p.Id]
			if l and now - l.Hit < D.MergeSeconds then
				l.Amount += p.Amount
				l.Crit = l.Crit or p.Crit
				l.Hit = now
				style(l)
			elseif spawnLabel(p.Id, p.Amount, p.Crit, now) then
				made += 1
			end
		end
	end
	-- anything left too long is dropped (never a backlog)
	for i = #pending, 1, -1 do
		if now - pending[i].At >= 0.3 then
			table.remove(pending, i)
		end
	end
	local reduced = ClientSettings.Reduced()
	for i = #live, 1, -1 do
		local l = live[i]
		local age = now - l.Born
		if age >= D.LifeSeconds then
			table.remove(live, i)
			release(l)
		else
			local u = age / D.LifeSeconds
			if not reduced then
				l.Gui.StudsOffsetWorldSpace = l.Base + Vector3.new(0, u * 1.8, 0)
				local pop = math.max(0, 1 - (now - l.Hit) / 0.12)
				l.Text.TextSize = (l.Crit and 22 or 18) * (1 + 0.25 * pop)
			end
			local fade = math.clamp((u - 0.6) / 0.4, 0, 1)
			l.Text.TextTransparency = fade
			l.Stroke.Transparency = 0.15 + 0.85 * fade
		end
	end
end

-- Removes every number (run end, setting switched off).
function DamageText.Clear()
	for i = #live, 1, -1 do
		release(live[i])
	end
	table.clear(live)
	table.clear(pending)
end

function DamageText.Init()
	local f = Instance.new("Folder")
	f.Name = "SwarmDamageNumbers"
	f.Parent = workspace
	folder = f
	local a = Instance.new("Part")
	a.Name = "Anchor"
	a.Anchored = true
	a.CanCollide = false
	a.CanQuery = false
	a.CanTouch = false
	a.Transparency = 1
	a.Size = Vector3.new(0.1, 0.1, 0.1)
	a.CFrame = CFrame.new()
	a.Parent = f
	anchor = a
	Remotes.Get("DamageNumbers").OnClientEvent:Connect(onNumbers)
	RunService.RenderStepped:Connect(function()
		if #live > 0 or #pending > 0 then
			step()
		end
	end)
	player:GetAttributeChangedSignal("InRun"):Connect(function()
		if player:GetAttribute("InRun") ~= true then
			DamageText.Clear()
		end
	end)
	ClientSettings.OnChanged(function(key, value)
		if key == "DamageNumbers" and value ~= true then
			DamageText.Clear()
		end
	end)
end

return DamageText
