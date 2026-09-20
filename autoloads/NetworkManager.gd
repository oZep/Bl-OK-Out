extends Node

signal players_ready
signal connection_failed
signal opponent_left
signal lobby_ready(lobby_id: int) # emitted once our lobby exists and can be shared/invited to

const STEAM_APP_ID := 480
const MAX_PLAYERS := 2
const VIRTUAL_PORT := 0 # arbitrary; must match between create_host/create_client

var peer: SteamMultiplayerPeer
var peer_to_player: Dictionary = {}  # Godot multiplayer unique id -> game player number (1 or 2)
var my_player_id: int = 0
var game_started: bool = false
var steam_initialized: bool = false
var current_lobby_id: int = 0


func _ready() -> void:
	_init_steam()
	Steam.lobby_created.connect(_on_steam_lobby_created)
	Steam.lobby_joined.connect(_on_steam_lobby_joined)
	Steam.join_requested.connect(_on_steam_join_requested)


func _process(_delta: float) -> void:
	if steam_initialized:
		Steam.run_callbacks()


func _init_steam() -> void:
	# steam_appid.txt containing "480" must sit next to the project /
	# exported executable so Steam can find it when not launched via Steam
	# itself (the editor counts as "not launched via Steam").
	OS.set_environment("SteamAppId", str(STEAM_APP_ID))
	OS.set_environment("SteamGameId", str(STEAM_APP_ID))

	var init_result: Dictionary = Steam.steamInitEx(STEAM_APP_ID, true)
	steam_initialized = init_result.get("status", -1) == 0
	if not steam_initialized:
		push_error("Steam failed to initialize: %s" % init_result.get("verbal", "unknown error"))


# ---------------------------------------------------------------------------
# HOSTING: create a Steam lobby, then open the actual peer once it exists.
# ---------------------------------------------------------------------------
func host_game() -> void:
	if not steam_initialized:
		connection_failed.emit()
		return
	Steam.createLobby(Steam.LOBBY_TYPE_FRIENDS_ONLY, MAX_PLAYERS)


func _on_steam_lobby_created(connect_result: int, lobby_id: int) -> void:
	if connect_result != 1: # 1 == k_EResultOK
		connection_failed.emit()
		return
	current_lobby_id = lobby_id
	Steam.setLobbyJoinable(lobby_id, true)
	Steam.setLobbyData(lobby_id, "game", "block_out")

	peer = SteamMultiplayerPeer.new()
	var err: int = peer.create_host(VIRTUAL_PORT)
	if err != OK:
		push_error("SteamMultiplayerPeer.create_host failed: %s" % err)
		connection_failed.emit()
		return
	multiplayer.multiplayer_peer = peer
	my_player_id = 1
	peer_to_player[multiplayer.get_unique_id()] = 1
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

	lobby_ready.emit(lobby_id)


## Opens the Steam overlay's "invite a friend" dialog for our current lobby.
func open_invite_overlay() -> void:
	if current_lobby_id != 0:
		Steam.activateGameOverlayInviteDialog(current_lobby_id)


# ---------------------------------------------------------------------------
# JOINING: either the user pastes a Lobby ID, or Steam tells us they
# accepted a friend's invite / clicked "Join Game" from the friends list.
# ---------------------------------------------------------------------------
func join_lobby(lobby_id: int) -> void:
	if not steam_initialized:
		connection_failed.emit()
		return
	Steam.joinLobby(lobby_id)


func _on_steam_join_requested(lobby_id: int, _friend_id: int) -> void:
	join_lobby(lobby_id)


func _on_steam_lobby_joined(lobby_id: int, _permissions: int, _locked: bool, response: int) -> void:
	if response != Steam.CHAT_ROOM_ENTER_RESPONSE_SUCCESS:
		connection_failed.emit()
		return

	current_lobby_id = lobby_id
	var host_steam_id: int = Steam.getLobbyOwner(lobby_id)

	if host_steam_id == Steam.getSteamID():
		# We ARE the host — this fires for our own lobby too. host_game()
		# already opened our peer, so there's nothing else to do here.
		return

	peer = SteamMultiplayerPeer.new()
	var err: int = peer.create_client(host_steam_id, VIRTUAL_PORT)
	if err != OK:
		push_error("SteamMultiplayerPeer.create_client failed: %s" % err)
		connection_failed.emit()
		return
	multiplayer.multiplayer_peer = peer
	my_player_id = 2
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.server_disconnected.connect(func(): opponent_left.emit())
	multiplayer.connection_failed.connect(func(): connection_failed.emit())


# ---------------------------------------------------------------------------
# Shared connection lifecycle (same as the ENet version).
# ---------------------------------------------------------------------------
func _on_peer_connected(id: int) -> void:
	peer_to_player[id] = 2
	if peer_to_player.size() == MAX_PLAYERS:
		GameState.setup_new_game()
		game_started = true
		_broadcast_full_state()
		players_ready.emit()


func _on_peer_disconnected(id: int) -> void:
	opponent_left.emit()


func _on_connected_to_server() -> void:
	pass # wait for the first _receive_state call; see below


func _broadcast_full_state() -> void:
	for pid in peer_to_player.keys():
		var player_num: int = peer_to_player[pid]
		var state := GameState.get_state_for_player(player_num)
		if pid == multiplayer.get_unique_id():
			GameState.apply_remote_state(state)
		else:
			_receive_state.rpc_id(pid, state)


func sync_state() -> void:
	_broadcast_full_state()


# ---------------------------------------------------------------------------
# Server -> one client: a censored snapshot. Godot's multiplayer API keeps
# the "peer id 1 == server" convention for custom peers too (GodotSteam's
# SteamMultiplayerPeer follows it), so rpc_id(1, ...) below always reaches
# whoever is hosting, exactly like the ENet version did.
# ---------------------------------------------------------------------------
@rpc("authority", "call_remote", "reliable")
func _receive_state(state: Dictionary) -> void:
	GameState.apply_remote_state(state)
	if not game_started:
		game_started = true
		players_ready.emit()


# ---------------------------------------------------------------------------
# Public API used by the UI — unchanged from the ENet version.
# ---------------------------------------------------------------------------
func request_move(direction: Vector2i) -> void:
	if multiplayer.is_server():
		GameState.try_move(my_player_id, direction)
		sync_state()
	else:
		submit_move.rpc_id(1, direction)


func request_push(block_pos: Vector2i) -> void:
	if multiplayer.is_server():
		GameState.try_push(my_player_id, block_pos)
		sync_state()
	else:
		submit_push.rpc_id(1, block_pos)


func request_break_decision(use_break: bool) -> void:
	if multiplayer.is_server():
		GameState.resolve_break_decision(my_player_id, use_break)
		sync_state()
	else:
		submit_break_decision.rpc_id(1, use_break)


@rpc("any_peer", "call_remote", "reliable")
func submit_move(direction: Vector2i) -> void:
	if not multiplayer.is_server():
		return
	var player_num: int = peer_to_player.get(multiplayer.get_remote_sender_id(), 0)
	if player_num == 0:
		return
	GameState.try_move(player_num, direction)
	sync_state()


@rpc("any_peer", "call_remote", "reliable")
func submit_push(block_pos: Vector2i) -> void:
	if not multiplayer.is_server():
		return
	var player_num: int = peer_to_player.get(multiplayer.get_remote_sender_id(), 0)
	if player_num == 0:
		return
	GameState.try_push(player_num, block_pos)
	sync_state()


@rpc("any_peer", "call_remote", "reliable")
func submit_break_decision(use_break: bool) -> void:
	if not multiplayer.is_server():
		return
	var player_num: int = peer_to_player.get(multiplayer.get_remote_sender_id(), 0)
	if player_num == 0:
		return
	GameState.resolve_break_decision(player_num, use_break)
	sync_state()
