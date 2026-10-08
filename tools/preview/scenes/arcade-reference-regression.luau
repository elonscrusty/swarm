-- Re-enter HUD layout while its title/close controls are still being constructed,
-- as Roblox AutomaticSize notifications can do. Also check a first-run Play setup.
local C = lib("common")
C.lobby()
preview.startClient(false)
local Hud = preview.client("Hud")
local Kit = preview.client("UIKit")
local original = Kit.IconButton
local triggered = false
local constructionError = nil
Kit.IconButton = function(parent, opts)
	local ui = Hud.Elements()
	if not triggered and ui.Build and not ui.Status and opts.Name == "Close" then
		triggered = true
		local ok, err = pcall(Hud.Layout)
		if not ok then constructionError = tostring(err) end
	end
	return original(parent, opts)
end
preview.client("UIBuilder").Init({})
Kit.IconButton = original
C.settle(1)
assert(triggered, "must exercise a layout notification during HUD construction")
assert(constructionError == nil, "HUD layout during construction must wait for complete elements: " .. tostring(constructionError))
local profile = C.profile()
profile.Stats.Runs = 0
C.sendProfile(profile)
preview.client("LobbyScreen").Show("Play")
C.settle(1)
for _, name in ipairs({ "Solo", "Duo", "Trio", "Hero", "Arena", "Difficulty", "Curses", "Start" }) do
	local found = preview.findGui(function(g) return g:IsA("GuiButton") and g.Name == name and preview.isShown(g) end)
	assert(found[1], "first-run reference setup must expose " .. name)
end
local function card(name)
	return preview.findGui(function(g) return g:IsA("GuiButton") and g.Name == name and preview.isShown(g) end)[1]
end
if card("Arena").AbsolutePosition.X > card("Hero").AbsolutePosition.X then
	assert(math.abs(card("Arena").AbsolutePosition.Y - card("Hero").AbsolutePosition.Y) < 1, "Hero and World must share the first grid row")
	assert(card("Difficulty").AbsolutePosition.Y > card("Hero").AbsolutePosition.Y, "Difficulty must sit below Hero")
	assert(math.abs(card("Curses").AbsolutePosition.Y - card("Difficulty").AbsolutePosition.Y) < 1, "Difficulty and Curses must share the second grid row")
end
for _, name in ipairs({ "Sigils", "Endless", "Daily", "Weekly" }) do
	local extra = preview.findGui(function(g) return g:IsA("GuiButton") and g.Name == name and preview.isShown(g) end)
	assert(not extra[1], "additional setting must remain under Details: " .. name)
end
local details = preview.findGui(function(g) return g:IsA("GuiButton") and g.Name == "Details" and preview.isShown(g) end)[1]
preview.click(details)
C.settle(0.2)
local daily = preview.findGui(function(g) return g:IsA("GuiButton") and g.Name == "Daily" and preview.isShown(g) end)
assert(daily[1], "Details must keep additional settings accessible")
preview.click(details)
C.settle(0.2)
profile.Stats.Runs = 12
C.sendProfile(profile)
C.settle(0.2)
assert(card("Hero") and card("Arena") and card("Difficulty") and card("Curses"), "experienced accounts must retain the same reference controls")
local sent = nil
preview.remote("StartRun").OnServerEvent:Connect(function(_p, mode) sent = mode end)
local start = preview.findGui(function(g) return g:IsA("GuiButton") and g.Name == "Start" and preview.isShown(g) end)[1]
preview.click(start)
C.settle(0.2)
assert(sent == "Solo", "reference setup must preserve StartRun(Solo)")
preview.log("PASS construction relayout, first-run reference controls, Details, and Solo start")
