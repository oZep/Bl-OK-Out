# Draws the grid, pickups and snakes. All state lives in Game.gd.
extends Node2D

var game: Node2D = null


func _draw() -> void:
	if game == null:
		return
	var cs: int = game.cell_size
	var n: int = game.grid_size

	# checkerboard
	for x in n:
		for y in n:
			var v := 0.16 if (x + y) % 2 == 0 else 0.2
			draw_rect(Rect2(x * cs, y * cs, cs, cs), Color(v, v, v + 0.04))

	# "know the next spawn" hint (Game decides who may see it)
	if game.can_see_hint():
		_draw_marker(game.planned_score_cell, true, 0.35)
		_draw_marker(game.planned_sabotage_cell, false, 0.35)

	if game.points_active:
		if not game.score_taken:
			_draw_marker(game.score_cell, true, 1.0)
		if not game.sabotage_taken:
			_draw_marker(game.sabotage_cell, false, 1.0)

	for id in game.snakes:
		_draw_snake(game.snakes[id])

	draw_rect(Rect2(0, 0, n * cs, n * cs), Color.WHITE, false, 2.0)


func _draw_marker(cell: Vector2i, is_score: bool, alpha: float) -> void:
	var cs: int = game.cell_size
	var c := Vector2(cell) * cs + Vector2(cs, cs) / 2.0
	if is_score:
		draw_circle(c, cs * 0.3, Color(1, 0.85, 0.2, alpha))           # gold circle = score
	else:
		var r := cs * 0.34                                              # pink diamond = sabotage
		var pts := PackedVector2Array([c + Vector2(0, -r), c + Vector2(r, 0), c + Vector2(0, r), c + Vector2(-r, 0)])
		draw_colored_polygon(pts, Color(0.9, 0.2, 0.5, alpha))


func _draw_snake(s) -> void:
	var cs: int = game.cell_size
	for i in s.body.size():
		var rect := Rect2(Vector2(s.body[i]) * cs, Vector2(cs, cs))
		if s.texture != null:
			var tint := Color.WHITE if i == 0 else Color(0.85, 0.85, 0.85)
			draw_texture_rect(s.texture, rect, false, tint)
		else:
			var c: Color = s.color.lightened(0.3) if i == 0 else s.color
			draw_rect(rect.grow(-2), c)
		if i == 0:
			var outline := Color.WHITE
			if s.inverted_time > 0.0:
				outline = Color(1, 0.2, 0.2)
			elif s.boost_time > 0.0:
				outline = Color(1, 1, 0.2)
			draw_rect(rect.grow(-1), outline, false, 2.0)
