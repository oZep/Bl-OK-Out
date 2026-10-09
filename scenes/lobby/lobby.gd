extends Node
class_name Lobby
## Main menu controller. Creating or joining a lobby now loads the snake game scene.

const GAME_SCENE := "res://scenes/script/Main.tscn"

@onready var lobby_info_button: Button = %LobbyInfoButton
@onready var lobby_info_copy_label: Label = %LobbyInfoCopyLabel

@onready var main_menu: MainMenuUI = %MainMenuUI
@onready var steam_friends_list: Panel = %SteamFriendsList
@onready var in_game_ui: Control = %InGameUI

var _entering_game := false

var _current_lobby: String:
	get: return Online.LOCAL_SERVER_ADDRESS if not Online.steam_lobby_id else str(Online.steam_lobby_id)

func _ready() -> void:
	_update_lobby_info_button()

	Online.server_disconnected.connect(_handle_failed_connection)
	Online.connection_failed.connect(_handle_failed_connection)
	# Fires for every successful join path: Create (Steam), Join button, and Steam invites.
	Online.joined_lobby.connect(_enter_game)

	main_menu.host_online_requested.connect(_on_host_online_requested)
	main_menu.host_local_requested.connect(_on_host_local_requested)
	main_menu.join_requested.connect(_on_join_requested)
	main_menu.quit_requested.connect(_on_quit_requested)
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

func _enter_game() -> void:
	if _entering_game: return
	_entering_game = true
	get_tree().change_scene_to_file.call_deferred(GAME_SCENE)

func _update_lobby_info_button() -> void: lobby_info_button.text = "IP/Lobby ID: \n\n%s" % _current_lobby

func _handle_failed_connection() -> void: _on_disconnected.call_deferred()

func _on_disconnected() -> void:
	_entering_game = false
	_update_lobby_info_button.call_deferred()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	toggle_ui(true)

# "Play offline" button (host_local_requested): LAN / same-machine ENet lobby
func _on_host_local_requested() -> void:
	toggle_ui(true, true)
	var error := Online.host_local_lobby()
	match error:
		Online.ErrorCodes.SUCCESS: _enter_game()
		_: toggle_ui(true)

# "Create Server" button (host_online_requested): Steam lobby
func _on_host_online_requested() -> void:
	toggle_ui(true, true)
	var error: Online.ErrorCodes = await Online.host_steam_lobby()
	match error:
		Online.ErrorCodes.SUCCESS:
			_update_lobby_info_button()
			DisplayServer.clipboard_set(_current_lobby)
			_show_copied_popup()
			_enter_game()
		_: toggle_ui(true)

func _on_join_requested(address: String) -> void:
	if not address: address = Online.LOCAL_SERVER_ADDRESS
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	toggle_ui(true, true)
	var error: Online.ErrorCodes
	if address == Online.LOCAL_SERVER_ADDRESS: error = await Online.join_local_lobby()
	elif address.is_valid_ip_address(): error = Online.join_address(address) # LAN IP
	else: error = await Online.join_steam_lobby(address.to_int())            # Steam lobby ID
	match error:
		Online.ErrorCodes.SUCCESS: _enter_game()
		_: toggle_ui(true)

func _on_quit_requested() -> void:
	Online.leave_lobby()
	get_tree().quit()

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_fullscreen"):
		var current_mode = DisplayServer.window_get_mode()
		if current_mode == DisplayServer.WINDOW_MODE_WINDOWED: DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		else: DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)

# Kept because lobby.tscn connects these two signals.
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
