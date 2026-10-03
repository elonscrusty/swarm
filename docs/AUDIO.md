# Audio verification and playback checks

The recovered branch already contains the music tracks and crossfade mixer. The polish pass preserves their asset IDs. Public Roblox toolbox metadata was checked on 2026-10-02 through `https://apis.roblox.com/toolbox-service/v1/items/details?assetIds=1836939228,9047425352,1838623501`.

| Use | Asset | Title / artist | Duration | Metadata |
|---|---|---|---|---|
| Lobby | [1836939228](https://create.roblox.com/store/asset/1836939228) | Celtic Adventures / Bob Bradley | 136 seconds | APMOfficial, audio, published, free |
| Battle | [9047425352](https://create.roblox.com/store/asset/9047425352) | Drums of Battle / Gabriel Saban | 167 seconds | APMOfficial, audio, published, free |
| Boss | [1838623501](https://create.roblox.com/store/asset/1838623501) | Hell Ride / Thomas Parisch | 141 seconds | APMOfficial, audio, published, free |

All three responses identify verified creator APMOfficial, user ID 7462718749, audio type ID 3, and public visibility status 0. The raw response is preserved in the chat workspace at `work/audio-metadata.json`. This check confirms the listed metadata; it does not prove that an experience can currently load or play each asset.

Other existing effect IDs and their inherited attribution comments are retained. They were not independently reverified in this pass. The low-health heartbeat reuses the existing Roblox built-in `rbxasset://sounds/collide.wav` at low pitch and volume, so it requires no new upload or purchased audio. Effects volume controls it.

## Required live checks

- In Studio and on the owner's phone, hear lobby, battle and boss tracks with no asset-access errors.
- Travel between phases rapidly; crossfades do not leave overlapping full-volume tracks, and returning battle music resumes.
- Set Music and Effects to zero separately; the corresponding channels become silent.
- In a dense fight, danger warnings remain audible over hits, deaths and low-health feedback.
- Exit or die repeatedly; no old warning or heartbeat continues outside its run.
- With Reduced Effects on, low-health danger remains readable without an animated flash.

Offline audio simulation checks mixer state, voice caps, ducking and crossfades. It is silent and cannot substitute for listening in Roblox.
