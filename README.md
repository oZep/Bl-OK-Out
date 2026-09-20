# Block Out — Godot 4 Implementation Guide

This package gives you a working server-authoritative multiplayer skeleton
for the "Block Out" rulebook you provided. All the *rules logic* is fully
implemented and ready to use; the *scenes* need to be assembled once in the
Godot editor (5–10 minutes, instructions below) because scene files are
risky to hand-write outside the editor.

## 0. Why this architecture (read this first)

Block Out is a **hidden information** game: Player 1 can't see Color A
blocks, Player 2 can't see Color B blocks. That means you cannot use
Godot's normal high-level multiplayer patterns (`MultiplayerSynchronizer`,
broadcasting one shared game state to everyone) — those send the *same*
data to both peers, which would let either player inspect network traffic
or memory and see the blocks they're not supposed to know about.

Instead:

- **The server (host) holds the one true board** — every block, both
  colors, in `GameState.gd`'s `blocks` array.
- After *every* action, the server calls
  `GameState.get_state_for_player(player)` **twice** — once per player —
  each call returning a **censored snapshot** containing only that
  player's visible/discovered blocks and their own margin-tracker counts.
- Those two different snapshots are unicast with `rpc_id()` to the
  correct peer only (`NetworkManager._receive_state`).
- Clients only ever render `GameState.local_view` — the snapshot they were
  sent. They never see `GameState.blocks` directly (on a client, that
  array is simply never populated).

This is the single most important thing to preserve if you extend this
project — any shortcut that sends the full board to both clients breaks
the whole game.

## 1. Project setup

1. Install Godot **4.2 or later**.
2. Create a new empty project (or use the folder this zip came in as your
   project folder directly — `project.godot` is already set up with the
   two required autoloads).
3. **Install the GodotSteam addon** (this is the piece that talks to
   Steamworks — it is NOT bundled in this zip, it's a compiled
   GDExtension you must add yourself):
   - Download the release matching your Godot version from
     https://github.com/GodotSteam/GodotSteam/releases (or search
     "GodotSteam" in the Godot Asset Library from inside the editor).
   - Copy its `addons/godotsteam/` folder into this project's `res://addons/`.
   - It also ships a `steam_api64.dll` / `libsteam_api.so` / `libsteam_api.dylib`
	 for your platform — make sure that lands next to your project /
	 exported binary per that addon's own install instructions.
   - Go to **Project > Project Settings > Plugins** and enable GodotSteam.
   - Restart the editor once after enabling it.
4. Make sure the **Steam client** is installed, running, and logged in on
   your machine before running the game — `SteamAPI_Init` fails otherwise.
5. `steam_appid.txt` (already included in this zip, containing `480`)
   must sit next to `project.godot` when running from the editor, and
   next to the exported executable when running a build. This lets Steam
   initialize even though it wasn't launched by the Steam client.
6. Confirm in **Project > Project Settings > Autoload** that you see:
   - `GameState` → `res://autoloads/GameState.gd`
   - `NetworkManager` → `res://autoloads/NetworkManager.gd`
7. Folder layout:
   ```
   res://
	 project.godot
	 steam_appid.txt      (contains "480")
	 addons/godotsteam/   <- you add this (step 3)
	 autoloads/
	   GameState.gd        (full rules engine — see section 3, untouched by Steam)
	   NetworkManager.gd   (Steam lobby + SteamMultiplayerPeer, RPCs, fog-of-war broadcast)
	 scripts/
	   Block.gd            (class_name Block — one obstacle)
	   MainMenu.gd
	   Board.gd
	 scenes/
	   MainMenu.tscn        <- you build this (step 2)
	   Board.tscn           <- you build this (step 2)
   ```

### Why App ID 480?

480 ("Spacewar") is Valve's public test App ID — anyone can use it for
development without registering a real app on Steamworks first. Its one
special perk that's actually useful here: Steam normally refuses to run a
second instance of the same App ID under one logged-in account, but 480
is explicitly exempted, so you can run two copies of this project on one
PC/account to test host + client against each other. Swap
`NetworkManager.STEAM_APP_ID` for your real App ID (and get a proper
`steam_appid.txt` / Steamworks app page) before shipping — 480 games
cannot be sold or have real player data associated with them.

## 2. Building the two scenes

### `scenes/MainMenu.tscn`

Root node: **Control** (full rect). Attach `scripts/MainMenu.gd` to it.
Child tree:

```
Control (script: MainMenu.gd)
└─ VBoxContainer  (name it "VBox")
   ├─ Label            (text: "Block Out")
   ├─ Label            (name: "StatusLabel", text: "")
   ├─ Button           (name: "HostButton", text: "Host Game (Create Lobby)")
   ├─ Button           (name: "InviteButton", text: "Invite Friend (Steam Overlay)")
   ├─ LineEdit         (name: "LobbyIdField", placeholder text: "Paste Lobby ID to join")
   └─ Button           (name: "JoinButton", text: "Join Lobby")
```

Node **names must match exactly** (`VBox`, `StatusLabel`, `HostButton`,
`InviteButton`, `LobbyIdField`, `JoinButton`) — `MainMenu.gd` looks them
up with `@onready var x = $VBox/...`.

Flow: **Host** creates a Steam lobby, then either clicks **Invite Friend**
(opens the Steam overlay's normal friend-invite dialog — the friend just
clicks "Join Game" and `NetworkManager` picks that up automatically via
`Steam.join_requested`) or reads out the numeric Lobby ID shown in
`StatusLabel` for the other player to paste into `LobbyIdField` and press
**Join Lobby**.

### `scenes/Board.tscn`

Root node: **Control** (full rect). Attach `scripts/Board.gd` to it.
Child tree:

```
Control (script: Board.gd)
├─ VBoxContainer  (name: "VBox")
│  ├─ StatusLabel? -> no, see below, order matters for the paths used:
│  ├─ BoardArea   (VBoxContainer, name: "BoardArea")
│  │  ├─ TopMargin   (HBoxContainer, name: "TopMargin")
│  │  ├─ Grid        (GridContainer, name: "Grid")
│  │  └─ (SideMargin actually needs to sit beside Grid — see note below)
│  ├─ StatusLabel (Label, name: "StatusLabel")
│  └─ Controls    (HBoxContainer, name: "Controls")
│     ├─ Button (name: "BtnLeft",  text: "<")
│     ├─ Button (name: "BtnUp",    text: "^")
│     ├─ Button (name: "BtnDown",  text: "v")
│     ├─ Button (name: "BtnRight", text: ">")
│     └─ Button (name: "BtnPush",  text: "Push")
└─ ConfirmationDialog (name: "BreakDialog", ok_button_text: "Use Break Token",
                        cancel_button_text: "No, end turn")
```

Note on `SideMargin`: for a true row-margin display you want it to the
*left* of `Grid`, not above/below. The simplest robust layout: make
`BoardArea` an **HBoxContainer** instead of VBoxContainer, put
`SideMargin` (a `VBoxContainer`) as `Grid`'s sibling before it, and wrap
`TopMargin` + `Grid` together in their own inner VBoxContainer:

```
BoardArea (HBoxContainer)
├─ SideMargin (VBoxContainer)
└─ GridColumn (VBoxContainer)
   ├─ TopMargin (HBoxContainer)
   └─ Grid (GridContainer, columns will be set to 8 in code)
```

Either arrangement works with `Board.gd` as written — it only cares that
`$VBox/BoardArea/Grid`, `$VBox/BoardArea/TopMargin`, and
`$VBox/BoardArea/SideMargin` resolve to *some* Grid/HBox/VBox container.
If you nest an extra `GridColumn` layer as shown above, update those three
`@onready` paths in `Board.gd` to match (e.g.
`$VBox/BoardArea/GridColumn/Grid`).

Everything inside `Grid` (the 64 cell buttons) and inside `TopMargin` /
`SideMargin` (the 8+8 count labels) is created **procedurally** in
`Board.gd`'s `_ready()` — don't add cell buttons by hand.

## 3. Rules → code map

| Rulebook section | Where it lives |
|---|---|
| 8×8 grid, coordinates | `GameState.BOARD_SIZE`, Vector2i(x,y) convention documented at top of `GameState.gd` |
| Crown start/target squares | `p1_start`, `p1_target`, `p2_start`, `p2_target` |
| Color A invisible to P1 / Color B invisible to P2 | `Block.is_visible_to()` |
| Margin trackers | `GameState._margin_counts()` |
| Coin flip for first turn | `setup_new_game()` (`rng.randi_range(0,1)`) |
| Move: continuous sliding until blocked | `GameState.try_move()` |
| Hitting a hidden block reveals it | `blk.discovered_by[player] = true` inside `try_move()` |
| Break Token destroys the block you just hit | `GameState.resolve_break_decision()` |
| Push: 1 space away, once per block ever, not onto Crowns | `GameState.try_push()` |
| Win condition | `GameState._check_victory()` |
| Fog of war over the network | `GameState.get_state_for_player()` + `NetworkManager._broadcast_full_state()` |

## 4. Testing locally (two instances)

1. Make sure Steam is running and you're logged in.
2. In the Godot editor, open **Debug > Run Multiple Instances** and set it
   to run **2 instances**, or just export/run the project twice from two
   separate terminal windows.
3. In instance A, click **Host Game (Create Lobby)**. Once
   `NetworkManager.lobby_ready` fires, `StatusLabel` shows the Lobby ID.
4. In instance B, paste that Lobby ID into the field and click
   **Join Lobby**. (Because this is App ID 480, both instances can be
   logged into the *same* Steam account at once — no second account
   needed just to test.)
5. Both windows should switch to the board once connected. Try moving —
   each window will only ever show its own player's blocks and margin
   numbers, which you can verify by comparing the two windows side by
   side (they should differ where blocks are hidden to one side).

Playing with an actual friend over the internet works the same way,
except step 4 is normally replaced by them clicking **Invite Friend** on
your end and "Join Game" from their Steam friends list/overlay
notification — no manual IP/port forwarding needed, since
`SteamMultiplayerPeer` routes traffic over Steam's relay network (SDR),
which also handles NAT traversal for you.

## 5. Known simplifications / good next steps

- The exact method names/signatures on `Steam` and `SteamMultiplayerPeer`
  (`steamInitEx`, `createLobby`, `getLobbyOwner`, `create_host`, etc.)
  can drift slightly between GodotSteam releases. If something doesn't
  compile, check the version's own docs/demo project for the current
  signatures — the logic and call order here will still be correct, only
  a method name might need adjusting.
- Lobby type is `LOBBY_TYPE_FRIENDS_ONLY`; switch to `LOBBY_TYPE_PUBLIC`
  plus `Steam.requestLobbyList()`/`Steam.lobby_match_list` if you want a
  public server-browser-style lobby list instead of invite/Lobby-ID only.
- No reconnect/resume-on-disconnect handling — `opponent_left` is emitted
  but nothing currently acts on it besides updating status; you'll likely
  want to bounce both players back to the main menu.
- No turn timer.
- No visual distinction for a block that's been discovered-but-not-yet-
  pushed vs. one that was always visible to you — add that in
  `Board._redraw_board()` if it matters for your UX (the data is right
  there in `blk.discovered_by`, just not currently surfaced to the
  client's censored snapshot as a separate flag — you'd add a
  `"discovered"` field to `Block.to_public_dict()` if you want it).
- `BLOCKS_PER_COLOR` (10 per color, 20 total) is a placeholder — tune it,
  or make it a lobby setting sent from the host before `setup_new_game()`.
- No animations/sound; cells are plain `Button`s for clarity. Swap in
  `TextureButton`/sprites once the logic is verified working.
- Board generation is uniform-random; if you want the margin numbers to
  be a genuinely solvable Minesweeper-style deduction puzzle rather than
  pure gameplay flavor, you'll want a dedicated level-generation pass
  with a solvability check instead of `_random_free_square()`.
# Bl-OK-Out
