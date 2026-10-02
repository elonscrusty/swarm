# Offline preview renderer (no Studio needed)

`tools/preview/` runs the **real game modules** headlessly against a mock Roblox API and
draws what they build: the 3D world with three.js and the GUI as Roblox would lay it out,
in headless Chromium. Use it for screenshots, layout checks on several devices, model
review in game colours and arena layout metrics. It is an approximation of Roblox:
honest and close, not a substitute for a Studio playtest.

## Quick start

```
bash tools/preview/setup.sh                       # once per machine (idempotent)
bash tools/preview/render.sh menu                 # → tools/preview/out/menu-pc.png
bash tools/preview/render.sh arena --device phone --out /tmp/arena.png
bash tools/preview/render.sh menu,arena --devices pc,phone,phone-portrait --outdir out/x
bash tools/preview/render.sh arena-map --set arena=Ruins --set runs=5 --print-metrics
bash tools/preview/render.sh --all                # every scene x every device → out/all
bash tools/preview/render.sh menu --ref HEAD      # a committed version (clean snapshot)
bash tools/preview/render.sh --check-meshes       # FBX pieces vs catalog offsets/sizes
```

Options: `--seed N` (default 1), `--studio` (RunService:IsStudio() = true, shows the DEV
button), `--set key=value` (scene arguments, e.g. `arena=Ruins`, `enemies=200`,
`meshes=uploaded` to show only really uploaded models), `--no-coreui` (hide the ghost of
Roblox's top-bar buttons), `--repo PATH` / `--ref GIT_REF` (render another checkout).
Each PNG gets its scene JSON next to it (`--outdir` / `--json`) and a `*.metrics.json`.

Setup installs Lune 0.10.4 into `/tmp/sh-tools/lune`, three.js (npm) and Google Fonts
into `tools/preview/.cache/fonts` (with measured advance widths). Chromium comes from the
global Playwright install (`/opt/pw-browsers`); never run `playwright install`.

## Scenes (`tools/preview/scenes/*.luau`)

| Scene | Shows |
|---|---|
| `menu` | lobby world + lighting, lobby home screen, camera at the lobby `MenuCamera` part; `--set save=failing\|memory` shows the "progress isn't being saved" notice |
| `characters`, `upgrades` | lobby screens, opened with the `OpenPanel` remote; characters: `--set inspect=Ranger` taps a hero, `--set owned=all` owns every hero (Queen Slayer done) |
| `settings`, `stats` | taps the button whose text is SETTINGS / STATS (stats is skipped with a note if the UI has none); `--set tab=achievements` opens the ACHIEVEMENTS tab |
| `countdown` | Duo countdown started by the player, a teammate joined (`SwarmState` attributes) |
| `arena` | `--set character=Ranger --set steadyaim=on\|off` shows another hero and the Steady Aim chip; Forest (or `--set arena=Ruins`) at 8:24, hero at the centre, 120 enemies, gems, pickups, chest, HUD with weapons / passives; the real CameraController run camera |
| `levelup`, `results`, `pause` | in-run overlays over the arena (`LevelUpOffer`, `RunResult`, the pause entry point); levelup builds real cards (stat lines, ranks, perks, hints): `--set cards=evolve`, `--set rerolls=0 --set skips=0 --set rerollsMax=0`; results shows the hero, build and REPLAY / MAIN MENU, `--set outcome=defeat` a Duo defeat during the Queen fight |
| `team` | Duo / Trio HUD (TeamUI): teammates are extra Players (`preview.addPlayer`) with real characters; one fallen with the world revive circle and the marker ring. `--set mode=Duo\|Trio`, `--set revive=0.55`, `--set far=on` (off-screen arrow), `--set me=down` (you are the one down), `--set choosing=on` (a teammate picks a card: the freeze line), `--set leave=on` (a teammate disconnects) |
| `tutorial` | a new player's first run (profile `TutorialDone = false`) with one tip showing: `--set tip=Move\|Attack\|Gems\|Portal\|Boss\|TeamRules\|Revive\|LevelUp`, `--set tips=off` |
| `stage-portal` | stage 2: the hero by the portal while it charges (charge ring, stage pill); `--set charge=0` idle portal, `--set look=Boss\|Surge\|Open` other portal states |
| `stage-arrow` | stage 2 at the centre after the hint time: stage pill and the edge arrow to the off-screen portal |
| `stage-choice` | the open portal's NEXT STAGE / RETURN TO LOBBY panel (`PortalOffer` remote) |
| `stage-sim` | boots the real server (`preview.startServer`) and plays the stage loop through the remotes (start, dev portal boss, surge, NEXT STAGE, travel, RETURN TO LOBBY), printing the state; a slow logic smoke test |
| `enemy-telegraphs` | the arena with every enemy warning at once (Spitter wind-up + acid marker, a glob in flight, Bomb Tick fuse ring, Rhino lunge lane, the three elite affixes with a fire patch) and the "New: Spitter" toast; `--set t=<s>` another moment |
| `boss` | the Scorpion Queen at one moment, `--set moment=entrance\|charge\|venom\|ring\|burrow\|summon\|stunned\|collapse`: her pose, the floor telegraph and the boss bar |
| `boss-sim` | boots the real server: enemy behaviours, elite affixes, a full Queen fight (entrance, cycle, phase 2, a kill mid-attack, collapse, surge) and travel cleanup, printing every state change; run with `--studio` |
| `models` | contact sheet of every catalog model in game colours, front 3/4 view (ViewportFrames) |
| `arena-map` | top-down orthographic arena with obstacles (red), the spawn clear radius and the 40/100/200 rings, plus metrics; `--set loot=1` adds the portal and the stage loot (chests, shrines, altar) |
| `loot` | stage 2 with the real LootSystem placement: the hero at a chest / shrine / altar (`--set focus=Small\|Large\|Golden\|Chance\|Bargain\|Guarded`, `--set altar=Guarded`, `--set gold=N`) with its prompt, the items strip, item popups, a sealed Bargain |
| `items` | the pause menu ITEMS list |

Scenes only use public entry points (`MapBuilder.BuildLobby / BuildArena`,
`MeshService.Init / Start`, `ModelBuilder.BuildCharacter / BuildEnemyShell /
ApplyEnemyLook / BuildGem / BuildPickup / BuildChest`), remotes (`ProfileSync`,
`Inventory`, `OpenPanel`, `LevelUpOffer`, `RunResult`, ...) and attributes
(`SwarmState` Phase / Countdown / Mode / RunTime ..., player InRun / HP / Level / XP ...).
The client starts exactly like Roblox: StarterPlayerScripts is copied to PlayerScripts
and `ClientMain` runs, so UIBuilder / LobbyScreen / CameraController / EnemyRenderer /
VFX are the real ones. Helpers: `scenes/lib/common.luau`, `scenes/lib/arena.luau`.
Every step is protected: a failing game module is printed with its stack and the scene
still renders whatever exists.

New scene: add `scenes/<name>.luau`; it gets the game globals plus `preview`
(`advance(seconds)`, `fireClient(remote, ...)`, `click(button)`, `findGui(text)`,
`shared(name)`, `server(name)`, `client(name)`, `startClient()`, `forceMeshesUploaded()`,
`addPlayer(name, userId)` (another Player in the server, for co-op scenes),
`overlay{...}`, `camera = {cf, fov, ortho}`, `metrics`, `render.background`).

## Metrics (`arena-map`)

`<out>.metrics.json` (or `--print-metrics`): obstacle count (circles / boxes), blocked
area = union of obstacle shapes rasterised at 0.5 studs inside the 400x400 play square,
% of the square, open area, obstacles (by centre) and blocked area per ring
(0-40, 40-100, 100-200, corners), trees / rocks, and part / MeshPart / light /
shadow-caster counts, triangle estimate (catalog tris per piece; primitives: block 12,
cylinder 64, ball 288) and instance counts. `arena` adds `metrics.swarm` (the same counts
for the full swarm scene). MapBuilder's unseeded `Random.new()` draws its seed from the
scene seed, so metrics are deterministic per `--seed`; `--set runs=N` builds the arena N
times in a row (like N server starts) and reports min / mean / max.

## How it works

1. `runtime/main.luau` (Lune): builds the DataModel from `default.project.json` (Rojo
   rules), runs the scene in a simulated scheduler (time only moves when the scene
   advances it; RenderStepped → waits → Heartbeat → tweens → deferred → GUI layout per
   frame) and writes scene JSON.
   * `mock/instance.luau`: Instance as userdata with properties and defaults from Lune's
     reflection database, type-checked writes, children / Parent, signals that fire
     (Changed, GetPropertyChangedSignal, ChildAdded, DescendantAdded, AncestryChanged,
     Destroying, AttributeChanged ...), attributes, tags, Clone (refs remapped), Destroy,
     WaitForChild (yields; errors after 10 simulated seconds). Unknown members fail
     loudly: `X is not a valid member of Class "Path"`.
   * `mock/classes/*`: DataModel / services (Players + one LocalPlayer, RunService,
     TweenService with Roblox easing, UserInputService per device, GuiService, StarterGui,
     TextService, InsertService, MarketplaceService / BadgeService / SocialService stubs,
     CollectionService, Debris, HttpService, DataStoreService in memory ...), parts, models
     (pivots, bounding boxes), joints (Motor6D / Weld / WeldConstraint move Part1),
     camera projection, lighting, remotes (FireServer logged; scenes deliver
     OnClientEvent).
   * `mock/layout.luau` + `mock/text.luau`: Roblox GUI layout and text (below).
   * `mock/meshes.luau`: `InsertService:LoadAsset` returns MeshParts named like the
     catalog pieces with the attribute `PreviewMeshRef = "<Category>/<Model>.fbx#<Piece>"`.
     Scenes count every catalog model as uploaded (`AssetId = 0` → a fake id) so new models
     show before they are uploaded.
   * Lune datatypes are used for all math; added: TweenInfo, Random (deterministic),
     RaycastParams, OverlapParams, Path2DControlPoint, DateTime. Fixed: Lune 0.10.4's
     `CFrame.lookAt` faces backwards and `ColorSequence.new(a, b)` repeats `a`; both are
     replaced, `CFrame.new(pos, lookAt)` is added.
2. `renderer/render.mjs` (Node + Playwright) opens `renderer/page/` in headless Chromium
   (SwiftShader WebGL) and screenshots it.

### GUI rules implemented (Luau, so game code reads the same AbsoluteSize)

ScreenGui area per device (DeviceSafeInsets / CoreUISafeInsets apply the device safe
area, `None` does not; unless IgnoreGuiInset the area starts below the 58 px top bar);
UDim2 Position / Size, AnchorPoint, SizeConstraint; UIScale (scales the object around its
anchor and everything inside; layouts use unscaled sizes); AutomaticSize; UIListLayout
(fill direction, Padding, alignments, SortOrder LayoutOrder / Name, Wraps,
HorizontalFlex / VerticalFlex + UIFlexItem basics); UIGridLayout (CellSize, CellPadding,
FillDirectionMaxCells, StartCorner, block alignment); UIPageLayout (first page);
UIPadding; UIAspectRatioConstraint; UISizeConstraint; UITextSizeConstraint; UICorner
(scale relative to the shorter side, clamped to a pill); UIStroke (Border: outer /
centre / inner ring following the corners; Contextual on text: text outline; thickness
scales with UIScale); UIGradient (colour and transparency sequences, Rotation, Offset;
multiplies background and text); ScrollingFrame canvas (CanvasSize, AutomaticCanvasSize,
CanvasPosition, scroll bars); CanvasGroup (GroupTransparency); ViewportFrame (its
children rendered with its CurrentCamera, Ambient, LightColor / LightDirection in a
second three.js pass); Path2D (cubic Béziers from control points, tangents as offsets,
Closed); Rotation (inherited by children); Visible; ClipsDescendants (not on rotated
objects, like Roblox); ZIndex with Sibling and Global ZIndexBehavior; ScreenGuis by
DisplayOrder; BillboardGuis projected from their Adornee (studs + pixels sizing) and drawn
under the ScreenGuis. Text: TextScaled (largest whole size 1-100 or the
UITextSizeConstraint range that fits, words not split), TextWrapped, X / Y alignment,
LineHeight, TextTransparency, TextStroke, TextTruncate, MaxVisibleGraphemes, RichText
(b, i, u, s, br, font color / size / face / weight / transparency, stroke, uppercase,
smallcaps, mark), legacy `Font` ↔ `FontFace`.

Fonts: Merriweather (Light/Regular/Bold/Black) and Source Sans 3 (the renamed Source
Sans Pro) are the same fonts Roblox uses. **Substitutes**: Gotham → Montserrat,
BuilderSans → Inter, Arial / Legacy → Arimo, Code → Inconsolata; any other family →
Source Sans 3 (each substitution is listed in the scene notes). Text is measured with the
same TTF files the browser draws (no kerning), so wrapping matches the picture.

### Devices

| Profile | Size (GUI px) | Pixel ratio | Input | Safe insets (L / R / T / B) |
|---|---|---|---|---|
| `pc` | 1920 x 1080 | 1 | mouse + keyboard | 0 |
| `laptop` | 1366 x 768 | 1 | mouse + keyboard | 0 |
| `phone` | 844 x 390 landscape | 2 | touch | 47 / 47 / 0 / 21 |
| `phone-portrait` | 390 x 844 | 2 | touch | 0 / 0 / 47 / 34 (top bar below the notch) |
| `tablet` | 1024 x 768 | 1.5 | touch | 0 / 0 / 0 / 20 |

The Roblox top bar is 58 px on every profile; GuiService:GetGuiInset() returns it.
A ghost of Roblox's menu and chat buttons is drawn at the top left (inside the safe area)
so layouts can be checked against them (`--no-coreui` hides it).

## What is approximated / known gaps

* **Lighting**: sun direction from ClockTime and GeographicLatitude (rises in +X at 6:00,
  noon sun tilted toward +Z for positive latitude; no season / earth tilt), sun colour =
  ColorShift_Top, hemisphere ambient from OutdoorAmbient / Ambient, PCF soft shadows from
  the sun only (CastShadow parts), point / spot lights without shadows (32 nearest the
  view), neutral tone mapping. Atmosphere → exponential fog + a two-colour gradient sky;
  Sky textures, clouds, SunRays and DepthOfField are not drawn; Bloom is a restrained
  UnrealBloom; ColorCorrection is applied to display colours.
* **Materials**: flat colours. SmoothPlastic / Plastic roughness 0.65, Metal metalness 0.6
  roughness 0.4, Neon emissive (glows through bloom), Glass transparent; every other
  material (Grass, Slate, Cobblestone, Wood ...) is a plain colour with roughness 0.9 -
  **no textures**. Decals / Textures and SurfaceGuis are not drawn. Terrain is not drawn.
* **Shapes**: Block, Ball (smallest axis), Cylinder (X axis, smaller of Y/Z), Wedge,
  CornerWedge (peak at +X/-Z, unverified), SpecialMesh Brick / Sphere / Cylinder / Head /
  Wedge / Torso (approximate shapes); MeshParts from the catalog FBX files, stretched to
  Size like Roblox. Other MeshIds (not in the catalog) are boxes.
* **Effects**: Fire → three glowing sprites; ParticleEmitter → a few static sprites;
  Highlight → fill + inverted-hull outline; Beam → flat camera-facing strip; Trails,
  Smoke, Sparkles are not drawn.
* **GUI**: images (rbxassetid / rbxasset) are striped placeholders tinted with
  ImageColor3; BillboardGuis are never occluded by geometry; UITableLayout is not laid
  out; the last row of a UIGridLayout follows the grid block (not re-centred).
  Roblox-exact text metrics (kerning, font hinting) differ by a pixel or two.
* **Runtime**: no physics (parts stay where code puts them; joints only follow when
  Part0 moves), raycasts and spatial queries hit nothing, remotes are delivered
  immediately, signals fire immediately (Roblox's default is deferred), sounds are
  silent, one LocalPlayer (scenes may add other Players with `preview.addPlayer`: they
  have characters and attributes but run no scripts). The full server (`GameServer`, DataStores, monetization) is
  not run by the scenes; `preview.startServer()` exists but needs more mocking.

## Checks

`bash tools/preview/render.sh --check-meshes` loads every FBX listed in
`meshes/catalog.json` and compares each piece's bounding-box centre and size in Roblox
axes with the catalog Offset / Size (Blender (x, y, z) → Roblox (-x, z, y), front = -Z).
It prints every mismatch or missing piece (exit code 1). The `models` scene is the visual
check: heroes and creatures must show their faces in the front 3/4 view.
