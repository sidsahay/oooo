extends Control

signal ready_for_out
signal ready_for_next
signal instruction_out

# Declare member variables here. Examples:
# var a = 2
# var b = "text"
var new_instruction_received = false
var instruction_position = Vector2(0, 0)
var instruction_scene = preload("res://InstBasic.tscn")
var instruction = null
var instruction_rect = null

var y_bound = 0
var x_half = 0

var instruction_has_reached_end = false

# Called when the node enters the scene tree for the first time.
func _ready():
	pass # Replace with function body.

func on_instruction_in():
	new_instruction_received = true
	
# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	if new_instruction_received:
		if instruction != null:
			instruction.queue_free()
		instruction = instruction_scene.instance()
		add_child(instruction)
		instruction_rect = instruction.get_node("ColorRect")
		new_instruction_received = false
		y_bound = $ColorRect.rect_size.y - instruction_rect.rect_size.y
		instruction_has_reached_end = false

	if instruction != null:
		if instruction.rect_position.y < y_bound:
			instruction.rect_position.y += delta * 15
		elif not instruction_has_reached_end:
			print("Instruction reached end!")
			emit_signal("instruction_out")
			instruction_has_reached_end = true
			instruction.queue_free()
			instruction = null
		
