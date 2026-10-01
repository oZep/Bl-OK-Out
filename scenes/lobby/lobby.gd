extends Node
class_name Lobby

@export var player_scene: PackedScene
@export var multiplayer_spawner: MultiplayerSpawner
@export var players_container: Node3D
@onready var lobby_info_button: Button = %LobbyInfoButton
@onready var lobby_info_copy_label: Label = %LobbyInfoCopyLabel

@onready var main_menu: MainMenuUI = %MainMenuUI
@onready var steam_friends_list: Panel = %SteamFriendsList
@onready var in_game_ui: Control = %InGameUI

var _current_lobby: String:
	get: return Online.LOCAL_SERVER_ADDRESS if not Online.steam_lobby_id else str(Online.steam_lobby_id)

func _setup_multiplayer_spawner() -> void:
	multiplayer_spawner.spawn_function = _add_player
	multiplayer_spawner.add_spawnable_scene(player_scene.resource_path)
	
func _ready() -> void:
	_update_lobby_info_button()
	_setup_multiplayer_spawner()
	
	Online.server_disconnected.connect(_handle_failed_connection)
	Online.connection_failed.connect(_handle_failed_connection)
	
	main_menu.host_online_requested.connect(_on_host_online_requested)
	main_menu.host_local_requested.connect(_on_host_local_requested)
	
	main_menu.join_requested.connect(_on_join_requested)
	main_menu.quit_requested.connect(_on_quit_requested)
	multiplayer.peer_disconnected.connect(_remove_peer)
	Online.player_connected.connect(_on_player_connected)
	Online.player_disconnected.connect(_on_player_disconnected)
	toggle_ui(true)

func toggle_ui(should_show_menu: bool, is_loading: bool = false) -> void:
	if should_show_menu:
		main_menu.show_menu()
		steam_friends_list.hide()
		if is_loading: in_game_ui.show()
		else: in_game_ui.hide()
	else:
		main_menu.hide_menu()
		in_game_ui.show()
	main_menu.loading = is_loading

func _update_lobby_info_button() -> void: lobby_info_button.text = "IP/Lobby ID: \n\n%s" % _current_lobby

func _handle_failed_connection() -> void: _on_disconnected.call_deferred()

func _on_disconnected() -> void:
	_update_lobby_info_button.call_deferred()
	for child in players_container.get_children(): if not child is MultiplayerSpawner: child.queue_free()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	toggle_ui(true)

func _on_player_connected(player_data: PlayerData) -> void:
	_update_lobby_info_button()
	if not multiplayer.multiplayer_peer or multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
		return
	if multiplayer.is_server():
		multiplayer_spawner.spawn(player_data.to_dict())
	multiplayer_spawner.spawn(player_data.to_dict())
	
func _on_player_disconnected(player_data: PlayerData) -> void:
	var player_node: Node = players_container.get(str(player_data.multiplayer_id))
	if is_instance_valid(player_node): player_node.queue_free()

func _on_host_local_requested() -> void:
	toggle_ui(true, true)
	var error := Online.host_local_lobby()
	match error:
		Online.ErrorCodes.SUCCESS:
			steam_friends_list.hide()
			toggle_ui(false)
			_update_lobby_info_button.call_deferred()
		_:
			steam_friends_list.show()
			toggle_ui(true)
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _on_host_online_requested() -> void:
	toggle_ui(true, true)
	var error := await Online.host_steam_lobby()
	match error:
		Online.ErrorCodes.SUCCESS:
			_update_lobby_info_button.call_deferred()
			toggle_ui(false)
		_:
			toggle_ui(true)

func _on_join_requested(address: String) -> void:
	if not address: address = Online.LOCAL_SERVER_ADDRESS
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	toggle_ui(true, true)
	var error: Online.ErrorCodes
	if address == Online.LOCAL_SERVER_ADDRESS: error = await Online.join_local_lobby()
	else: error = await Online.join_steam_lobby(address as int)
	match error:
		Online.ErrorCodes.SUCCESS:
			toggle_ui(false)
		_:
			toggle_ui(true)

func _add_player(player_data_dict: Dictionary) -> Node:
	toggle_ui(false, main_menu.loading)
	var player_data := PlayerData.from_dict(player_data_dict)
	var id: int = player_data.multiplayer_id
	if players_container.has_node(str(id)): return
	var player: PlayerCharacter = player_scene.instantiate()
	player.name = str(id)
	player.position = get_spawn_point()
	player.reset_physics_interpolation()
	PlayerData.apply_data_to_node(player_data,player)
	return player

func get_spawn_point() -> Vector3:
	var spawn_point = Vector2.from_angle(randf() * 2 * PI) * 5 # spawn radius
	return Vector3(spawn_point.x, 0, spawn_point.y)

func _remove_peer(id: int) -> void:
	if not multiplayer.is_server() or not players_container.has_node(str(id)):
		return
	var player_node = players_container.get_node(str(id))
	if player_node:
		player_node.queue_free()

func _on_quit_requested() -> void:
	Online.leave_lobby()
	get_tree().quit()

func _input(event: InputEvent) -> void:
	if Input.is_action_just_pressed("ui_cancel"):
		if main_menu.visible: return
		if in_game_ui.visible: in_game_ui.hide()
		else:
			if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE: Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			if Online.steam_lobby_id: steam_friends_list.show()
			else: steam_friends_list.hide()
			in_game_ui.show()
	elif event.is_action_pressed("toggle_fullscreen"):
		var current_mode = DisplayServer.window_get_mode()
		if current_mode == DisplayServer.WINDOW_MODE_WINDOWED: DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		else: DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	
func _on_exit_lobby_button_pressed() -> void: 
	Online.leave_lobby()

func _on_lobby_info_button_pressed() -> void:
	DisplayServer.clipboard_set(_current_lobby)
	_show_copied_popup()

func _show_copied_popup() -> void:
	var copy_label := lobby_info_copy_label
	copy_label.show()
	var tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(lobby_info_button, "self_modulate:a", 0.5, 0.1)
	tween.tween_property(copy_label, "modulate:a", 1.0, 0.2).from(0.0)
	tween.tween_property(copy_label, "position:y", -5.0, 0.2).from(10.0)
	await tween.finished
	var fade_out_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN)
	fade_out_tween.tween_property(copy_label, "modulate:a", 0.0, 0.2)
	fade_out_tween.tween_property(copy_label, "position:y", 10.0, 0.2)
	fade_out_tween.tween_property(lobby_info_button, "self_modulate:a", 1.0, 0.5)
	await fade_out_tween.finished
