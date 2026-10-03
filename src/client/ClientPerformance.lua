-- Reduce decoration after sustained slow frames; never change danger cues or saved settings.
local ClientPerformance = {}
local reduced = false
local average = 1 / 60
local slowFor, recoveredFor = 0, 0
local started = false

function ClientPerformance.Step(dt: number)
	if dt <= 0 or dt ~= dt then
		return
	end
	dt = math.min(dt, 0.25)
	average += (dt - average) * math.min(1, dt * 2)
	if not reduced then
		slowFor = average > 1 / 30 and slowFor + dt or 0
		if slowFor >= 3 then
			reduced, recoveredFor = true, 0
		end
	else
		recoveredFor = average < 1 / 45 and recoveredFor + dt or 0
		if recoveredFor >= 8 then
			reduced, slowFor = false, 0
		end
	end
end

function ClientPerformance.Reduced(): boolean
	return reduced
end

function ClientPerformance.Scale(): number
	return reduced and 0.5 or 1
end

function ClientPerformance.Init()
	if started then
		return
	end
	started = true
	game:GetService("RunService").RenderStepped:Connect(ClientPerformance.Step)
end

return ClientPerformance
