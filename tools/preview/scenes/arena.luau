-- arena: Forest arena (--set arena=Ruins for the other one) at 8:24 into a run, the
-- hero at the centre, 120 mixed enemies (EnemyRenderer models), gems, pickups and the HUD
-- with several weapons / passives. Camera: the real CameraController run camera.
local A = lib("arena")
local C = lib("common")
local s = A.build({})
C.settle(3)
preview.metrics.swarm = preview.worldCounts()
preview.metrics.enemies = s.enemyCount
