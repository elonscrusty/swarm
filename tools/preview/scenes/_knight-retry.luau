-- temp: a failed hero LoadAsset is retried (asset id broken for the first attempt only).
local MC = preview.shared("MeshCatalog")
local realId = MC.Models.Knight.AssetId
MC.Models.Knight.AssetId = 1
preview.setLoadLatency(0.3, 6)
preview.startServer()
local MS = preview.server("MeshService")
preview.advance(1.5)
preview.log(string.format("[retry] t=1.5 loaded=%s mayLoad=%s", tostring(MS.Get("Knight") ~= nil), tostring(MS.MayLoad("Knight"))))
MC.Models.Knight.AssetId = realId
local fired = false
MS.WhenReady({ "Knight" }, function() fired = true end)
preview.advance(30)
local p = MS.Progress()
preview.log(string.format("[retry] end loaded=%s whenReadyFired=%s failed=%d loaded=%d/%d", tostring(MS.Get("Knight") ~= nil), tostring(fired), p.Failed, p.Loaded, p.Total))
