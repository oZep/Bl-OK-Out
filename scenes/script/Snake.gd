# Plain data holder for one snake (no node needed).
extends RefCounted

var id: int = 1
var start_cell := Vector2i.ZERO
var texture: Texture2D = null      # square picture, repeated on every segment
var color := Color.WHITE           # fallback when no texture is set

var body: Array = []               # Vector2i grid cells, index 0 = head
var dir := Vector2i.DOWN
var queued_dir := Vector2i.ZERO
var grow_pending: int = 0
var step_acc: float = 0.0
var score: int = 0

var inverted_time: float = 0.0     # seconds of inverted controls left
var boost_time: float = 0.0        # seconds of speed boost left


func setup(p_id: int, p_start: Vector2i, p_texture: Texture2D, p_color: Color) -> void:
	id = p_id
	start_cell = p_start
	texture = p_texture
	color = p_color
	reset(0)


# Back to the spawn corner. Score is NOT touched.
func reset(start_growth: int) -> void:
	body = [start_cell]
	dir = Vector2i.DOWN
	queued_dir = Vector2i.ZERO
	grow_pending = start_growth
	step_acc = 0.0


func clear_effects() -> void:
	inverted_time = 0.0
	boost_time = 0.0


func head() -> Vector2i:
	return body[0]


func queue_direction(d: Vector2i) -> void:
	queued_dir = d


func apply_queued() -> void:
	if queued_dir != Vector2i.ZERO and queued_dir != -dir:
		dir = queued_dir
	queued_dir = Vector2i.ZERO


# --- network snapshot helpers (host -> client) ---
func to_dict() -> Dictionary:
	return {"body": body.duplicate(), "dir": dir, "score": score, "inv": inverted_time, "boost": boost_time}


func apply_dict(d: Dictionary) -> void:
	body = d["body"]
	dir = d["dir"]
	score = d["score"]
	inverted_time = d["inv"]
	boost_time = d["boost"]
