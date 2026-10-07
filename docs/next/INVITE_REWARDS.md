# Invite rewards (switch `InviteRewards`)

## What
Invite friends; cosmetic rewards only.
- **Invite:** PARTY > INVITE FRIENDS (existing button) and MORE > INVITE FRIENDS
  (`MenuInvite.lua`, same prompt: `CanSendGameInviteAsync`, then
  `SocialService:PromptGameInvite`).
- **New player:** a brand-new account that joins through an invite gets the
  **Friend Badge** nameplate (`Plate_Friend`). Wear it in the Store's Nameplates.
- **Inviter:** after the new player finishes their first clean run, the inviter gets:
  - the **Recruiter** title,
  - 1 point (`Stats.Recruits`),
  - the **Recruiter Trail** (`Trail_Recruiter`) at 3 points.

Server (`src/server/Modules/InviteRewards.lua`):
- Referral: only `Player:GetJoinData().ReferredByPlayerId`, never TeleportData / LaunchData.
  It is read once, on the first load of a save that had no earlier save (`Invite.New`, set by
  DataService), and never again (`Invite.Checked`). Self-referral is ignored.
- Credit: RunManager calls `OnRunCommitted` after its DEV-taint return. When the new player
  has `RunsNeeded` finished runs, the credit is sent once (`Invite.Sent`); a DEV-boosted
  profile never sends one.
  - The inviter is in this server: they are credited at once, and their save is written.
  - Otherwise: a pending record (the new player's id) is added under the inviter's key in the
    `SwarmInvites` DataStore (`_Studio` in Studio). The inviter's own server processes it on
    join and every 5 minutes, and removes it once their save with the credit is written.
- Exactly once: the inviter's save keeps the credited ids (`Invite.Credited`, capped at
  `MaxCredits`), so a record read twice, a retry or a second run never credits twice. That
  makes 1 credit per new player.
- Player attribute `Recruits` for the lobby.

Save (additive, no schema bump): `Invite = { New, Checked, ReferredBy, Sent, Runs, Credited }`
and `Stats.Recruits`.

## Config
- `Config.Features.InviteRewards = true`
- `Config.Invite = { Badge = "Plate_Friend", Title = "Title_Recruiter", Trail = "Trail_Recruiter",
  TrailAt = 3, RunsNeeded = 1, MaxCredits = 200, StoreName = "SwarmInvites", PollSeconds = 300 }`
- Keep `TrailAt` and StoreCatalog's `Trail_Recruiter` goal (`Earn.At = 3`) the same.

## Owner steps
None to switch it on.
- Test with two accounts on the live game: invite from PARTY or MORE, and join from the
  invite with a NEW account.
- Play one run: the inviter gets the "Recruiter" title, at once if in the same server,
  otherwise on their next join.

## PASS / BLOCKED
- A run counts only when it was won or lasted `Config.Invite.MinRunSeconds` (120 s), so
  joining and leaving at once never credits the inviter.
- Offline: `invite-regression` (run without `--studio`).
  - New saves only, the referral is read once, the Friend Badge, no self-referral.
  - No credit before a finished run, then one credit.
  - Exactly once: a second run, a duplicate record, a direct call.
  - Offline inviter: the pending record is processed on join and removed.
  - The trail at 3, the cap, bad ids.
  - DEV-boosted players and the switch off send nothing.
- Layout: `social` scene, `screen=Invite|More`.
- BLOCKED: real invites and `ReferredByPlayerId` (Roblox sets it only on the live game). The
  pending store on live DataStores across two servers.
