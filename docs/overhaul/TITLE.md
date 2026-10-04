# TITLE: title screen / main menu (master prompt section 5, screen 01)

Owner role: TITLE. Issues: UI-12, UI-47, UI-48, UI-49, UI-50, UI-51, UI-52, UI-53, UI-54, UI-55,
ART-19, ART-23 (docs/overhaul/ISSUE_REGISTER.md). Everything below was checked offline (type check,
preview renderer, Lune regression). Nothing here is verified in Studio, on a device or live in
multiplayer.

## What was inspected

- Approved reference `01_Approved_UI/01_Title.png`, the review notes (01 section, "Further menu and
  copy details", "Lobby and navigation"), frames long/016s and long/040s.
- The 2026-10-04 home (`LobbyScreen.lua` "One big PLAY": hero pill with arrows, HEROES / SHOP / MORE
  dock, PLAY = instant SOLO start, SOLO selector), `MenuPlay.lua`, `MenuMore.lua`,
  `MenuCharacters.lua`, `MenuUpgrades.lua` (HERO UPGRADES card), `CameraController.lua` menu shot,
  `MapBuilder.BuildLobby` + `LIGHTING.Lobby` (moonlit Necromancer night, violet soul glow, moon).

## Changes

### Home (`src/client/LobbyScreen.lua`)
Rebuilt to 01_Title, keeping the plumbing (first-join auto run + cover, notice dots, countdown /
run-in-progress queue panel, party READY, gold chip on sub-screens, loading pill, entrance and
ambient animation, Settings = the existing modal):
- Top left: the painted logo, under it the hero caption (gold rule + diamond, letter-spaced serif)
  = the selected hero and its **equipped** skin from the profile ("KNIGHT · GOLD TRIM"; Default
  skin shows the name only). Tap opens CHARACTERS.
- Left: the gold PLAY plate (existing `ui/home/home_PlayButton` art + drawn fallback). PLAY now opens
  the run-setup step (no instant start). Under it "Choose your mode next."; once something is picked
  it reads e.g. "DUO · ENDLESS · change it next"; a party member reads "Your party leader picks the
  mode and starts." and gets the READY toggle under it.
- Top right: account pill (hero badge, account LV from `MenuTrack.Account`, gold; tap = ACCOUNT LEVEL)
  and a PARTY button ("Party 2/3" in a party, invite badge, notice dot).
- Bottom: Characters / Shop / Worlds / Daily (title case, gold separators, soft dark band), bottom
  right a small MORE (Stats, Ranks, Account Level, Journal, Achievements, Party, Settings, Report a
  bug, DEV for allowlisted devs only; the server still checks every DEV command) and the cog.
- Removed from home: hero arrows (switch heroes in Characters), the SOLO selector, the dock plate.
- BACK now returns to the screen a screen was opened from (Worlds from home → home, World row on the
  run-setup step → the step, Stats from MORE → MORE); falls back to the old PARENT table.
- Portrait: pill + party, logo + caption, hero, PLAY + line, bottom row with MORE and the cog.

### Run-setup step (`src/client/MenuPlay.lua`)
Left: SOLO / DUO / TRIO, a rule line that states who starts and what the size means (solo starts at
once; Duo/Trio without a party = a countdown others in the server can JOIN; a party plays its own
size; a member's START becomes READY / UNREADY), START. Right (scrolls if it does not fit): HERO
(hero + skin, opens Characters), WORLD ("Playing here · next: Desert unlocks at best stage 5"),
DIFFICULTY (locked tier named with what clears it), CURSES, ENDLESS (switch with "No portal win:
stages go on. Own leaderboard."), DAILY CHALLENGE ("One scored try · used when it starts · resets in
Xh" / "Scored try used · practice only"), LAST RUN + RETRY. Members / fixed-size parties cannot pick
another size (toast says why). No mode behaviour was invented: every button sends the same remotes as
before (StartRun, SetDifficulty, SetEndless, Party Ready).

### Characters (`src/client/MenuCharacters.lua`)
- Sticky strip on top of the details panel, outside the scroll: "EQUIPPED KNIGHT" or "PREVIEW RANGER ·
  you play the Knight until you select another" (and "previewing skin X" for a skin preview).
- Hero upgrade list starts with "RANGER'S UPGRADES · only for the Ranger · paid with gold".
- Locked ranks explain themselves with the real rule (`MetaUpgradeData.RequiredMastery`):
  "Rank 7 needs Ranger mastery 4 (now 3)". The mastery block states purchased rank vs cap vs max:
  max mastery 10, each mastery level = 2 more ranks of every stat upgrade up to its own max, the
  trait needs mastery 2/4/6..., plus the current stat and trait caps (`HeroCap`).
- One cumulative line "Bought this visit: Max HP LV 3 · Might LV 2" under the rows; rows update from
  the server's ProfileSync (BUYING... until then).
- Camera: MenuHeroX centres the hero in the gap between the panels.

### Shop (`src/client/MenuUpgrades.lua`)
HERO UPGRADES card: shorter sentence ("Each hero has its own stat and trait upgrades, bought in
Characters.") and a description box with one spare line and a more generous width estimate (UI-54).
PERMANENT (account-wide) / SHOP (Robux) tabs and the OPEN CHARACTERS route already separate the three
purchase kinds (UI-55, kept). Native purchase prompts untouched.

### Lobby 3D
- `CameraController.lua`: new camera attribute `MenuHeroX` (0..1) pans the menu shot so the hero
  stands right of centre (home 0.6, portrait 0.5); eased like `MenuHeroY`.
- `MapBuilder.lua` lobby: dusk instead of night (ClockTime 17.8, warm horizon atmosphere, lavender
  ambient), the moon replaced by a setting sun on the left treeline with halos and a faint horizon
  glow, softer dusk clouds, fewer stars, violet soul light/wisps replaced by a warm sunset fill and
  gold dais motes; key light slightly lower (ART-18/23: less white/gold blow-out).
- Knight Gold Trim: Showcase already shows the equipped skin; the home caption names it.

## Tests (offline)
See the "Verification" section at the end (filled in from the runs).

## Remaining differences / risks
- Gold Trim skin data (`CharacterData.Skins.GoldTrim`, not TITLE-owned) turns the Knight's cape and
  plume gold; 01_Title shows a red cape/plume with gold trim (ART-19). Owner/art decision; not changed.
- The 01 reference footer "TITLE CONCEPT · EXAMPLE VALUES" is intentionally not drawn.
- Hero switching arrows are gone from home (Characters only), by the reference.
- The NoticeDots "More" dot still aggregates Daily / Party / Achievements / Track although Daily and
  Party now also sit on home (a dot can show in two places).
- Server success toasts for lobby purchases still stack (see FOR OTHERS); the screen itself now shows
  one cumulative line.
- Real dusk sky look in Studio depends on Roblox's sky/atmosphere; the preview draws a simple gradient.
