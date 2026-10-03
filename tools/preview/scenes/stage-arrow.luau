-- stage-arrow: stage 2 at the arena centre right after the portal reveal: the stage pill
-- ("STAGE 2 · Find the portal"), the edge-of-screen arrow with the distance pointing at the
-- portal (off screen), the minimap marker pinned to the map's edge and the beacon pillar
-- rising over the portal in the distance. --set reveal=0 shows the pre-reveal HUD.
local A = lib("arena")
local C = lib("common")
local reveal = tonumber(preview.args.reveal) or 1
A.build({ enemies = 80, seconds = 400, portal = true, portalState = "Idle", stage = 2, portalHint = true, portalReveal = reveal })
C.settle(2.5)
-- --set wave=N: wave N arrives (Config.Waves): the big "WAVE N" banner, the red edge glow
-- on its side and "WAVE N" on the stage pill; --set wavenext=S instead shows the breather
-- ("WAVE N IN 0:0S" on the pill, no banner); --set wavesides=north,east picks the sides
local wave = tonumber(preview.args.wave)
if wave then
	local nextIn = tonumber(preview.args.wavenext)
	if nextIn then
		C.setState({ Wave = wave - 1, WaveNext = 400 + nextIn })
		C.settle(0.8)
	else
		local sides = preview.args.wavesides or "north"
		C.setState({ Wave = wave, WaveNext = 0, WaveSides = sides, WaveAngle = -math.pi / 2, WaveBig = wave % 5 == 0, WaveSeq = 1 })
		C.settle(0.75)
	end
end
