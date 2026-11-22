# Notes for Claude

TrinketDock: lightweight trinket menu for WoW Forever (Lua 5.1, modern C_Container/C_Item APIs). Two secure use buttons for inventory slots 13 and 14, a flyout to swap trinkets from the bags. Author and rights holder: Bencepo. All rights reserved, no open-source license.

## Layout

- `TrinketDock.lua`: everything (buttons, flyout, equipping, settings window, events).
- `Bindings.xml`: keybindings as `CLICK TrinketDockButton1/2:LeftButton`.
- `Libs/BencepoUI`: shared settings-window toolkit of all Bencepo addons; `opts.bugUrl` gives the "Report a bug" button. It must be the same file in each addon (canonical: minor 4, Nov 2026). Change it in one repo, bump the LibStub minor, copy it to the others: two different copies with the same minor make the result depend on load order.
- `media/logo.png`: project logo for CurseForge, Wago and the website (not packaged).

## Why it exists

Ben used ItemRack only for its trinket menu. SpikeSpotter showed ItemRack costing ~27 ms on every combat start/end and after item data loads (it rebuilds its quick-access snapshots), even with its events and queues off. TrinketDock must stay cheap: no work on combat events, no bag scans outside the flyout.

## Rules

- No background work. Bags are read only in `ShowFlyout`. Events: `PLAYER_EQUIPMENT_CHANGED` (13/14 only), `BAG_UPDATE_COOLDOWN`, `PLAYER_ENTERING_WORLD`, `PLAYER_REGEN_ENABLED` (only applies a layout change deferred from combat).
- Secure buttons: never move, scale, show or hide the dock in combat; `Layout()` defers itself to `PLAYER_REGEN_ENABLED`.
- Edit Mode (hooked via `EventRegistry` "EditMode.Enter/Exit"): a mover frame above the buttons takes the drag; with Edit Mode's Snap on the dock snaps to `EditModeManagerFrame.registeredSystemFrames`, the screen edges and centre lines. Edit Mode is never open in combat.
- Swapping uses `C_Container.PickupContainerItem` + `PickupInventoryItem`, out of combat only. In combat the flyout (insecure frames) still opens and `Equip` fills `queue[13|14]` = { link, icon }; `RunQueue` on `PLAYER_REGEN_ENABLED` finds the item by link and swaps. Ben wants this: queue in combat, swap right after.
- Use buttons are `type = "macro"` with `/use 13` / `/use 14`: `type = "item"` with the slot number did nothing in combat on Forever. Clicks registered `AnyUp` + `AnyDown` (keybindings send down). `/tdock debug` prints every click to chat.
- English only: UI texts and descriptions, no translations, no `Notes-xxXX` in the .toc. Settings in the BencepoUI window, not in Blizzard's options.
- CI runs luacheck and LuaLS with the WoW API annotations; LuaLS must report zero diagnostics or the release stops. New Blizzard globals go into `.luarc.json`.
- Release: new version heading at the top of `CHANGELOG.md` (`## 1.0.1`), push to `main`; the workflow tags, builds and uploads to CurseForge and Wago (secrets `CF_API_KEY`, `WAGO_API_TOKEN`). The release reaches players right away, so test changes in the game before pushing.
