extends Node
class_name State

@warning_ignore("unused_signal")
signal transitioned

func enter(_char_reference : CharacterBody3D) -> void: pass

func exit() -> void: pass

func update(_delta : float) -> void: pass

func physics_update(_delta : float) -> void: pass
