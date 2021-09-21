extends Control

signal ready_for_more

var startup = true

func on_new_instruction(instr):
	add_child(instr)
	emit_signal("ready_for_more")
	
# Called when the node enters the scene tree for the first time.
func _ready():
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	if startup:
		startup = false
		emit_signal("ready_for_more")
