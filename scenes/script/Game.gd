extends Node2D
# 2-player snake (Godot 4). Root of res://scenes/script/Main.tscn.
#
# NETWORK MODEL (host-authoritative, built on the Online autoload):
#   * The host (peer 1) is Player 1 and runs the whole simulation + all randomness.
#   * The first remote peer to announce itself is Player 2.
#   * Clients send their direction to the host and render the snapshots the host sends.
#   * If no multiplayer session exists (you pressed F6 on this scene) it runs as a
#     local 2-player test: P1 = WASD, P2 = arrow keys.

signal countdown_started
signal game_started
signal round_started(round_number: int)
signal points_spawned(score_cell: Vector2i, sabotage_cell: Vector2i)
signal point_scored(player_id: int, new_score: int)
signal sabotage_captured(player_id: int)
signal sabotage_triggered(player_id: int, event: int)
signal player_reset(player_id: int)
signal game_over(winner_id: int)

const SnakeData = preload("res://scenes/script/Snake.gd")
const BoardView = preload("res://scenes/script/Board.gd")
const MENU_SCENE := "res://scenes/lobby/lobby.tscn"
const UI_THEME: Theme = preload("res://common/themes/main_theme/main_theme.tres")
const NO_CELL := Vector2i(-1, -1)
const NET_SEND_INTERVAL := 0.05   # 20 snapshots / second

enum State { WAITING, COUNTDOWN, PLAYING, GAME_OVER }
enum Sabotage { REVEAL, INVERT, SPEED }

@export var grid_size: int = 8
@export var cell_size: int = 96
@export var win_score: int = 16
@export var countdown_seconds: int = 3
@export var round_seconds: float = 40.0
@export var step_interval: float = 0.35     # seconds per move
@export var boost_interval: float = 0.18    # seconds per move while boosted
@export var effect_seconds: float = 15.0    # how long invert / speed last
@export var start_growth: int = 2           # snake starts at length 1 and grows to 1 + this
@export var allow_offline_test: bool = true # run as local 2-player when there is no session
@export var p1_texture: Texture2D           # square picture for player 1's snake
@export var p2_texture: Texture2D           # square picture for player 2's snake
@export var p1_color := Color(0.3, 0.8, 0.3)
@export var p2_color := Color(0.3, 0.5, 0.9)

var state: int = State.WAITING
var players_connected: int = 0
var game_in_progress := false
var snakes := {}
var board: Node2D
var countdown_left := 0.0

var round_number := 0
var round_timer := 0.0
var points_active := false
var score_cell := NO_CELL
var sabotage_cell := NO_CELL
var planned_score_cell := NO_CELL
var planned_sabotage_cell := NO_CELL
var score_taken := false
var sabotage_taken := false
var pending_sabotage_owner := 0   # player who grabbed the sabotage; it fires next round
var reveal_player := 0
var winner := 0

var message_text := ""
var message_time := 0.0

# networking
var online := false
var is_host := true
var local_slot := 1               # which snake THIS machine controls
var peer_slots := {}              # host only: peer_id -> slot (2)
var net_acc := 0.0
var _leaving := false

var ui: CanvasLayer
var status_label: Label
var hud_label: Label
var info_label: Label


func _ready() -> void:
	_setup_inputs()

	var s1 := SnakeData.new()
	s1.setup(1, Vector2i(0, 0), p1_texture, p1_color)                 # top-left
	var s2 := SnakeData.new()
	s2.setup(2, Vector2i(grid_size - 1, 0), p2_texture, p2_color)     # top-right
	snakes[1] = s1
	snakes[2] = s2

	board = BoardView.new()
	board.game = self
	add_child(board)

	_setup_ui()
	_layout()
	get_viewport().size_changed.connect(_layout)

	var peer := multiplayer.multiplayer_peer
	online = peer != null and not (peer is OfflineMultiplayerPeer)
	is_host = multiplayer.is_server()

	if online:
		local_slot = 1 if is_host else 2
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
		multiplayer.server_disconnected.connect(_leave_to_menu)
		Online.connection_failed.connect(_leave_to_menu)
		Online.server_disconnected.connect(_leave_to_menu)
		if is_host:
			_refresh_player_count()          # host alone -> WAITING
		else:
			_announce_ready()
	elif allow_offline_test:
		set_connected_players(2)


# ---------------------------------------------------------------- public API

# Host / offline only. Normally driven by _refresh_player_count().
func set_connected_players(count: int) -> void:
	players_connected = count
	if state == State.GAME_OVER:
		return
	if count >= 2 and state == State.WAITING:
		state = State.COUNTDOWN
		countdown_left = float(countdown_seconds)
		countdown_started.emit()
	elif count < 2 and (state == State.COUNTDOWN or state == State.PLAYING):
		state = State.WAITING   # pauses; resumes with a countdown when 2 are back


# Host / offline only. Remote input arrives through _submit_direction_rpc.
func submit_direction(player_id: int, dir: Vector2i) -> void:
	if state != State.PLAYING or not snakes.has(player_id):
		return
	var s = snakes[player_id]
	if s.inverted_time > 0.0:
		dir = -dir              # sabotage: controls inverted
	s.queue_direction(dir)


func restart_game() -> void:
	if online and not is_host:
		return
	game_in_progress = false
	winner = 0
	state = State.WAITING
	set_connected_players(players_connected)


func can_see_hint() -> bool:
	if points_active or reveal_player == 0 or planned_score_cell == NO_CELL:
		return false
	return (not online) or reveal_player == local_slot


# ---------------------------------------------------------------- networking

func _announce_ready() -> void:
	var peer := multiplayer.multiplayer_peer
	if peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		_client_ready.rpc_id(1)
	else:
		multiplayer.connected_to_server.connect(func(): _client_ready.rpc_id(1), CONNECT_ONE_SHOT)


@rpc("any_peer", "call_remote", "reliable")
func _client_ready() -> void:
	if not multiplayer.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	if not peer_slots.has(id):
		if peer_slots.size() >= 1:      # only 2 players per session
			multiplayer.multiplayer_peer.disconnect_peer(id)
			return
		peer_slots[id] = 2
	_refresh_player_count()


func _refresh_player_count() -> void:
	set_connected_players(1 + peer_slots.size())


func _on_peer_disconnected(id: int) -> void:
	if not is_host:
		return
	peer_slots.erase(id)
	_refresh_player_count()


@rpc("any_peer", "call_remote", "reliable")
func _submit_direction_rpc(dir: Vector2i) -> void:
	if not multiplayer.is_server():
		return
	var slot: int = peer_slots.get(multiplayer.get_remote_sender_id(), 0)
	if slot != 0:
		submit_direction(slot, dir)


func _broadcast(delta: float) -> void:
	net_acc += delta
	if net_acc < NET_SEND_INTERVAL or peer_slots.is_empty():
		return
	net_acc = 0.0
	for peer_id in peer_slots:
		_apply_state.rpc_id(peer_id, _make_snapshot(peer_slots[peer_id]))


func _make_snapshot(for_slot: int) -> Dictionary:
	var show_hint := reveal_player == for_slot and not points_active   # hide hints from the other player
	return {
		"state": state, "cd": countdown_left, "round": round_number, "rt": round_timer,
		"pa": points_active, "sc": score_cell, "bc": sabotage_cell,
		"st": score_taken, "bt": sabotage_taken, "rv": reveal_player,
		"ps": planned_score_cell if show_hint else NO_CELL,
		"pb": planned_sabotage_cell if show_hint else NO_CELL,
		"win": winner, "msg": message_text, "mt": message_time,
		"pc": 1 + peer_slots.size(),
		"s1": snakes[1].to_dict(), "s2": snakes[2].to_dict(),
	}


@rpc("authority", "call_remote", "unreliable_ordered")
func _apply_state(s: Dictionary) -> void:
	state = s["state"]
	countdown_left = s["cd"]
	round_number = s["round"]
	round_timer = s["rt"]
	points_active = s["pa"]
	score_cell = s["sc"]
	sabotage_cell = s["bc"]
	score_taken = s["st"]
	sabotage_taken = s["bt"]
	reveal_player = s["rv"]
	planned_score_cell = s["ps"]
	planned_sabotage_cell = s["pb"]
	winner = s["win"]
	message_text = s["msg"]
	message_time = s["mt"]
	players_connected = s["pc"]
	snakes[1].apply_dict(s["s1"])
	snakes[2].apply_dict(s["s2"])


func _leave_to_menu() -> void:
	if _leaving:
		return
	_leaving = true
	Online.leave_lobby()
	get_tree().change_scene_to_file.call_deferred(MENU_SCENE)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_leave_to_menu()


# ---------------------------------------------------------------- main loop

func _process(delta: float) -> void:
	message_time = maxf(0.0, message_time - delta)

	if online and not is_host:
		# client: just send input and render what the host tells us
		if state == State.PLAYING:
			_poll_input()
		_update_ui()
		board.queue_redraw()
		return

	match state:
		State.COUNTDOWN:
			countdown_left -= delta
			if countdown_left <= 0.0:
				_start_game()
		State.PLAYING:
			_poll_input()
			_update_effects(delta)
			_update_round(delta)
			for s in snakes.values():
				_tick_snake(s, delta)
				if state != State.PLAYING:
					break
		State.GAME_OVER:
			if Input.is_action_just_pressed("ui_accept"):
				restart_game()

	if online:
		_broadcast(delta)
	_update_ui()
	board.queue_redraw()


func _start_game() -> void:
	if not game_in_progress:
		_reset_game()
		game_in_progress = true
	state = State.PLAYING
	game_started.emit()


func _reset_game() -> void:
	for s in snakes.values():
		s.score = 0
		s.reset(start_growth)
		s.clear_effects()
	round_number = 0
	pending_sabotage_owner = 0
	reveal_player = 0
	winner = 0
	_begin_round()


# ---------------------------------------------------------------- rounds & points

func _begin_round() -> void:
	round_number += 1
	points_active = false
	round_timer = round_seconds
	planned_score_cell = _pick_free_cell([])
	planned_sabotage_cell = _pick_free_cell([planned_score_cell])
	_trigger_sabotage()
	round_started.emit(round_number)


func _update_round(delta: float) -> void:
	if points_active:
		return
	round_timer -= delta
	if round_timer <= 0.0:
		_spawn_points()


func _spawn_points() -> void:
	# Re-roll if a snake moved onto the planned square during the round.
	score_cell = planned_score_cell
	if score_cell == NO_CELL or _is_occupied(score_cell):
		score_cell = _pick_free_cell([])
	sabotage_cell = planned_sabotage_cell
	if sabotage_cell == NO_CELL or sabotage_cell == score_cell or _is_occupied(sabotage_cell):
		sabotage_cell = _pick_free_cell([score_cell])

	if score_cell == NO_CELL or sabotage_cell == NO_CELL:
		round_timer = 1.0    # board full, try again shortly
		return

	points_active = true
	score_taken = false
	sabotage_taken = false
	reveal_player = 0
	points_spawned.emit(score_cell, sabotage_cell)


func _check_pickups(s) -> void:
	if not points_active:
		return
	var h: Vector2i = s.head()
	if not score_taken and h == score_cell:
		score_taken = true
		s.score += 1
		s.grow_pending += 1
		point_scored.emit(s.id, s.score)
		if s.score >= win_score:
			state = State.GAME_OVER
			winner = s.id
			game_over.emit(s.id)
			return
	if not sabotage_taken and h == sabotage_cell:
		sabotage_taken = true
		pending_sabotage_owner = s.id
		_show_message("Player %d grabbed the sabotage! It triggers next round." % s.id)
		sabotage_captured.emit(s.id)
	if score_taken and sabotage_taken:
		_begin_round()    # spawn system restarts


func _trigger_sabotage() -> void:
	var who := pending_sabotage_owner
	pending_sabotage_owner = 0
	reveal_player = 0
	if who == 0:
		return
	var enemy := 3 - who
	var event := randi() % 3
	match event:
		Sabotage.REVEAL:
			reveal_player = who
			_show_message("Player %d can see where the next points will spawn!" % who)
		Sabotage.INVERT:
			snakes[enemy].inverted_time = effect_seconds
			_show_message("Player %d's controls are INVERTED!" % enemy)
		Sabotage.SPEED:
			snakes[who].boost_time = effect_seconds
			_show_message("Player %d has a SPEED BOOST!" % who)
	sabotage_triggered.emit(who, event)


func _update_effects(delta: float) -> void:
	for s in snakes.values():
		s.inverted_time = maxf(0.0, s.inverted_time - delta)
		s.boost_time = maxf(0.0, s.boost_time - delta)


# ---------------------------------------------------------------- snake movement

func _tick_snake(s, delta: float) -> void:
	s.step_acc += delta
	var interval := boost_interval if s.boost_time > 0.0 else step_interval
	if s.step_acc >= interval:
		s.step_acc -= interval
		_move_snake(s)


func _move_snake(s) -> void:
	s.apply_queued()
	var new_head: Vector2i = s.head() + s.dir
	var other = snakes[3 - s.id]
	var will_grow: bool = s.grow_pending > 0

	# wall
	if new_head.x < 0 or new_head.y < 0 or new_head.x >= grid_size or new_head.y >= grid_size:
		_reset_snake(s)
		return

	# self (tail square is free if the tail is about to move away)
	var own: Array = s.body.duplicate()
	if not will_grow:
		own.pop_back()
	if own.has(new_head):
		_reset_snake(s)
		return

	# enemy trail
	if other.body.has(new_head):
		_reset_snake(s)
		return

	s.body.push_front(new_head)
	if will_grow:
		s.grow_pending -= 1
	else:
		s.body.pop_back()

	_check_pickups(s)


func _reset_snake(s) -> void:
	s.reset(start_growth)   # keeps score, goes back to its starting corner
	player_reset.emit(s.id)


# ---------------------------------------------------------------- helpers

func _is_occupied(cell: Vector2i) -> bool:
	return snakes[1].body.has(cell) or snakes[2].body.has(cell)


# Random in-bounds square with no snake on it. Returns NO_CELL if none.
func _pick_free_cell(exclude: Array) -> Vector2i:
	var free: Array[Vector2i] = []
	for x in grid_size:
		for y in grid_size:
			var c := Vector2i(x, y)
			if exclude.has(c) or _is_occupied(c):
				continue
			free.append(c)
	if free.is_empty():
		return NO_CELL
	return free.pick_random()


func _show_message(text: String) -> void:
	message_text = text
	message_time = 4.0


# ---------------------------------------------------------------- input

func _setup_inputs() -> void:
	var keys := {
		"snake_up": KEY_W, "snake_down": KEY_S, "snake_left": KEY_A, "snake_right": KEY_D,
		"snake2_up": KEY_UP, "snake2_down": KEY_DOWN, "snake2_left": KEY_LEFT, "snake2_right": KEY_RIGHT,
	}
	for action in keys:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		var ev := InputEventKey.new()
		ev.physical_keycode = keys[action]
		InputMap.action_add_event(action, ev)


func _dir_from_actions(prefix: String) -> Vector2i:
	if Input.is_action_just_pressed(prefix + "_up"):
		return Vector2i.UP
	if Input.is_action_just_pressed(prefix + "_down"):
		return Vector2i.DOWN
	if Input.is_action_just_pressed(prefix + "_left"):
		return Vector2i.LEFT
	if Input.is_action_just_pressed(prefix + "_right"):
		return Vector2i.RIGHT
	return Vector2i.ZERO


func _poll_input() -> void:
	var d := _dir_from_actions("snake")
	if not online:
		# local test: P1 = WASD, P2 = arrows
		if d != Vector2i.ZERO:
			submit_direction(1, d)
		var d2 := _dir_from_actions("snake2")
		if d2 != Vector2i.ZERO:
			submit_direction(2, d2)
		return
	if d == Vector2i.ZERO:
		return
	if is_host:
		submit_direction(1, d)
	else:
		_submit_direction_rpc.rpc_id(1, d)


# ---------------------------------------------------------------- UI

func _setup_ui() -> void:
	ui = CanvasLayer.new()
	add_child(ui)
	var root := Control.new()
	ui.add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = UI_THEME
	hud_label = _make_label(root, 36)
	info_label = _make_label(root, 28)
	status_label = _make_label(root, 56)


func _make_label(parent: Control, font_size: int) -> Label:
	var l := Label.new()
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_constant_override("outline_size", 8)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	parent.add_child(l)
	return l


func _place(label: Label, y: float, h: float, w: float) -> void:
	label.position = Vector2(0.0, y)
	label.size = Vector2(w, h)


func _layout() -> void:
	var vs := get_viewport_rect().size
	var board_px := float(grid_size * cell_size)
	var origin := Vector2((vs.x - board_px) / 2.0, (vs.y - board_px) / 2.0 + 20.0)
	board.position = origin
	_place(hud_label, origin.y - 70.0, 60.0, vs.x)
	_place(info_label, origin.y + board_px + 10.0, 50.0, vs.x)
	_place(status_label, origin.y + board_px / 2.0 - 110.0, 220.0, vs.x)


func _lobby_info() -> String:
	if not online:
		return ""
	if Online.steam_lobby_id != 0:
		return "Lobby ID: %d" % Online.steam_lobby_id
	return "IP: %s" % Online.LOCAL_SERVER_ADDRESS


func _update_ui() -> void:
	match state:
		State.WAITING:
			status_label.text = "Waiting for opponent... (%d/2)\n%s" % [players_connected, _lobby_info()]
		State.COUNTDOWN:
			status_label.text = str(ceili(countdown_left))
		State.PLAYING:
			status_label.text = ""
		State.GAME_OVER:
			var tail := "\nPress Enter to play again" if (is_host or not online) else "\nWaiting for host..."
			status_label.text = "Player %d wins!%s" % [winner, tail]

	var timer_text := "Grab the points!"
	if not points_active:
		timer_text = "Points in %ds" % ceili(round_timer)
	hud_label.text = "P1  %d/%d     %s     P2  %d/%d" % [snakes[1].score, win_score, timer_text, snakes[2].score, win_score]

	var info := ""
	if online:
		info += "You are P%d   " % local_slot
	for s in snakes.values():
		if s.inverted_time > 0.0:
			info += "P%d INVERTED %ds   " % [s.id, ceili(s.inverted_time)]
		if s.boost_time > 0.0:
			info += "P%d BOOST %ds   " % [s.id, ceili(s.boost_time)]
	if message_time > 0.0:
		info += message_text
	info_label.text = info
