extends Control

@onready var status_label: Label = $VBox/StatusLabel
@onready var host_button: Button = $VBox/HostButton
@onready var invite_button: Button = $VBox/InviteButton
@onready var lobby_id_field: LineEdit = $VBox/LobbyIdField
@onready var join_button: Button = $VBox/JoinButton


func _ready() -> void:
	NetworkManager.players_ready.connect(_on_ready_to_play)
	NetworkManager.connection_failed.connect(_on_connection_failed)
	NetworkManager.lobby_ready.connect(_on_lobby_ready)

	host_button.pressed.connect(_on_host_pressed)
	invite_button.pressed.connect(_on_invite_pressed)
	join_button.pressed.connect(_on_join_pressed)

	invite_button.disabled = true

	if not NetworkManager.steam_initialized:
		status_label.text = "Steam didn't initialize. Make sure Steam is running and steam_appid.txt (480) sits next to the project/executable."
		host_button.disabled = true
		join_button.disabled = true


func _on_host_pressed() -> void:
	status_label.text = "Creating Steam lobby..."
	host_button.disabled = true
	join_button.disabled = true
	NetworkManager.host_game()


func _on_lobby_ready(lobby_id: int) -> void:
	status_label.text = "Lobby ready — ID %d. Invite a friend, or have them paste this ID and hit Join." % lobby_id
	invite_button.disabled = false


func _on_invite_pressed() -> void:
	NetworkManager.open_invite_overlay()


func _on_join_pressed() -> void:
	var text := lobby_id_field.text.strip_edges()
	if not text.is_valid_int():
		status_label.text = "Enter the numeric Lobby ID your friend shared with you."
		return
	status_label.text = "Joining lobby..."
	host_button.disabled = true
	join_button.disabled = true
	NetworkManager.join_lobby(int(text))


func _on_connection_failed() -> void:
	status_label.text = "Connection failed. Try again."
	host_button.disabled = false
	join_button.disabled = false


func _on_ready_to_play() -> void:
	get_tree().change_scene_to_file("res://scenes/Board.tscn")
