--[[
	scenes/lib/encounter.luau - helpers for the enemy / boss telegraph scenes: enemy bodies
	made like EnemySpawner.Spawn (pooled shell, ApplyEnemyLook, Elite / Affix / Shield /
	Act / Type attributes) so the real EnemyRenderer poses them, and warnings sent through
	the real FxBatch remote exactly as the server's Fx.Warn packs them (Telegraphs.lua).
]]

local C = lib("common")
local E = {}

local nextIndex = 400

-- An enemy body of `typeId` standing at floor point `pos`, facing `face` (a floor point).
function E.enemy(s, typeId: string, pos: Vector3, face: Vector3?, attrs: { [string]: any }?)
	local EnemyData = C.shared("EnemyData")
	local Config = s.Config
	local def = EnemyData and EnemyData.Enemies[typeId]
	if not def or not s.ModelBuilder then
		preview.warn("encounter: no enemy " .. typeId)
		return nil
	end
	local folder = workspace:FindFirstChild("SwarmEnemies") or Instance.new("Folder")
	folder.Name = "SwarmEnemies"
	folder.Parent = workspace
	nextIndex += 1
	local a = attrs or {}
	local elite = a.Elite == true
	local sizeMult = elite and Config.Enemies.EliteSizeMult or 1
	local model, body = C.try("BuildEnemyShell", s.ModelBuilder.BuildEnemyShell, nextIndex, folder)
	if not model or not body then
		return nil
	end
	C.try("ApplyEnemyLook", s.ModelBuilder.ApplyEnemyLook, body, def, elite, sizeMult)
	local height = (def.FlyHeight or 0) + def.Size.Y * sizeMult / 2
	local c = Vector3.new(pos.X, Config.ArenaOrigin.Y + height, pos.Z)
	local look = face and Vector3.new(face.X - pos.X, 0, face.Z - pos.Z) or Vector3.new(0, 0, 1)
	body.CFrame = CFrame.lookAt(c, c + (look.Magnitude > 0.1 and look.Unit or Vector3.new(0, 0, 1)))
	body:SetAttribute("Elite", elite)
	body:SetAttribute("Affix", a.Affix)
	body:SetAttribute("Shield", a.Affix == "Shielded")
	body:SetAttribute("Act", a.Act)
	body:SetAttribute("Type", typeId)
	return body
end

local warnId = 0
-- One FxBatch with these warnings: each { kind, ... } like Fx.Warn(kind, ...).
function E.warn(list: { { any } })
	local w = {}
	for _, item in ipairs(list) do
		warnId += 1
		local entry = { warnId, item[1] }
		for i = 2, #item do
			entry[i + 1] = item[i]
		end
		table.insert(w, entry)
	end
	C.fire("FxBatch", { w = w })
end

return E
