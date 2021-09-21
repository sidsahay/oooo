extends Node2D

# In case you're thinking this is horrible code
# 1. Yes, it is.
# 2. Switching to Godot and GDScript was a last second decision when p5.js wasn't working out. I literally learnt this as I made this.
# 3. I learnt that each GDScript file is actually a class AFTER making most of this. Yeah.
# 4. Feel free to send PRs with code refactors. Much appreciated. Thanks.

var instruction_scene = preload("res://Instruction.tscn")
var stage_scene = preload("res://Stage5Stage.tscn")

var instructions = []
var parsed_instructions = []
var stages = []

var fetch_stage = null
var decode_stage = null
var execute_stage = null
var memory_stage = null
var writeback_stage = null

var fetch_buffer = null
var decode_buffer = null
var execute_buffer = null
var memory_buffer = null
var writeback_buffer = null

var fetch_buffer_new = null
var decode_buffer_new = null
var execute_buffer_new = null
var memory_buffer_new = null
var writeback_buffer_new = null

export var fetch_delay = 1
export var decode_delay = 1
export var execute_delay = 1
export var memory_delay = 1
export var writeback_delay = 1
export var use_forwarding = false
export var bp_accuracy = 0.5
export var mispredict_delay = 2

var rng = null

var fetch_dirty = true
var decode_dirty = true
var execute_dirty = true
var memory_dirty = true
var writeback_dirty = true
var commit_dirty = true

var fetch_timer = 0
var decode_timer = 0
var execute_timer = 0
var memory_timer = 0
var writeback_timer = 0

var fetch_output_ready = false
var decode_output_ready = false
var execute_output_ready = false
var memory_output_ready = false
var writeback_output_ready = false

var fetch_looking_for_new = false
var decode_looking_for_new = false
var execute_looking_for_new = false
var memory_looking_for_new = false
var writeback_looking_for_new = false
var commit_looking_for_new = false

var commit_buffer_new = null

var current_tick = 0
var fetch_index = 0

var decode_to_execute_RAW_hazard = false
var decode_to_memory_RAW_hazard = false
var decode_to_writeback_RAW_hazard = false

var stall_decode = false

var instructions_committed = 0

func parse_instructions(text):
	var lines = text.split("\n")
	var r = RegEx.new()
	r.compile("\\S+")
	for line in lines:
		var inst_str_list = []
		for m in r.search_all(line):
			inst_str_list.push_back(m.get_string())
		var opcode = inst_str_list[0]
		var parsed_inst = [opcode]
		inst_str_list.pop_front()
		for op_str in inst_str_list:
			parsed_inst.push_back(int(op_str.right(1)))
		parsed_instructions.push_back(parsed_inst)
		
	var y = 10
	for parsed_instruction in parsed_instructions:
		var inst = instruction_scene.instance()
		inst.get_node("Opcode").text = parsed_instruction[0]
		inst.get_node("Rd").text = "x" + str(parsed_instruction[1])
		if parsed_instruction.size() > 2:
			inst.get_node("Rs1").text = "x" + str(parsed_instruction[2])
			if parsed_instruction.size() == 4:
				inst.get_node("Rs2").text = "x" + str(parsed_instruction[3])
			else:
				inst.get_node("Rs2").text = ""
		add_child(inst)
		inst.rect_position = Vector2(10, y)
		y += 70
		instructions.push_back(inst)
	
	var stage_x = 700
	var y_inc = 200
	y = 20
	fetch_stage = stage_scene.instance()
	fetch_stage.rect_position = Vector2(stage_x, y)
	y += y_inc
	add_child(fetch_stage)
	stages.push_back(fetch_stage)
	
	decode_stage = stage_scene.instance()
	decode_stage.rect_position = Vector2(stage_x, y)
	y += y_inc
	add_child(decode_stage)
	stages.push_back(decode_stage)
	
	execute_stage = stage_scene.instance()
	execute_stage.rect_position = Vector2(stage_x, y)
	y += y_inc
	add_child(execute_stage)
	stages.push_back(execute_stage)
	
	memory_stage = stage_scene.instance()
	memory_stage.rect_position = Vector2(stage_x, y)
	y += y_inc
	add_child(memory_stage)
	stages.push_back(memory_stage)
	
	writeback_stage = stage_scene.instance()
	writeback_stage.rect_position = Vector2(stage_x, y)
	y += y_inc
	add_child(writeback_stage)
	stages.push_back(writeback_stage)
	
	fetch_index = 0

	fetch_timer = 0
	decode_timer = 0
	execute_timer = 0
	memory_timer = 0
	writeback_timer = 0
	
	fetch_dirty = false
	decode_dirty = false
	execute_dirty = false
	memory_dirty = false
	writeback_dirty = false
	commit_dirty = false
	
	
func tick():
	# check branch predictor
	var bp_succeeded = true
	if execute_buffer != null && parsed_instructions[execute_buffer][0] == "br":
		bp_succeeded = rng.randf() < bp_accuracy
		
	# check for control hazard
	if not bp_succeeded:
		if fetch_buffer != null:
			var fi = instructions[fetch_buffer]
			fi.rect_position = Vector2(-1000, -1000)
			fetch_stage.remove_child(fi)
			fetch_buffer = null
			fetch_index = 0 # we restart from the top because might as well, no functional correctness here
			
		fetch_timer = mispredict_delay + 1
			
		if decode_buffer != null:
			var di = instructions[decode_buffer]
			di.rect_position = Vector2(-1000, -1000)
			decode_stage.remove_child(di)
			decode_buffer = null
			
		decode_timer = 0
			
	#check for data hazards
	decode_to_execute_RAW_hazard = false
	decode_to_memory_RAW_hazard = false
	decode_to_writeback_RAW_hazard = false

	var decode_start = 2
	if decode_buffer != null:
		if parsed_instructions[decode_buffer][0] == "st" || parsed_instructions[decode_buffer][0] == "br":
			decode_start = 1
			
	if decode_buffer != null && execute_buffer != null:
		# D to E RAW hazard
		var d = parsed_instructions[decode_buffer]
		var e = parsed_instructions[execute_buffer]
		if (not use_forwarding) || (use_forwarding && e[0] == "ld"):
			for i in range(decode_start, d.size()):
				if e[1] == d[i]:
					decode_to_execute_RAW_hazard = true
		
	if decode_buffer != null && memory_buffer != null:
		# D to M RAW hazard
		var d = parsed_instructions[decode_buffer]
		var m = parsed_instructions[memory_buffer]
		if (not use_forwarding) || (use_forwarding && m[0] == "ld"):
			for i in range(decode_start, d.size()):
				if m[1] == d[i]:
					decode_to_memory_RAW_hazard = true
					
	if decode_buffer != null && writeback_buffer != null:
		# D to W RAW hazard
		var d = parsed_instructions[decode_buffer]
		var w = parsed_instructions[writeback_buffer]
		if (not use_forwarding):
			for i in range(decode_start, d.size()):
				if w[1] == d[i]:
					decode_to_writeback_RAW_hazard = true
				
	stall_decode = decode_to_execute_RAW_hazard || decode_to_memory_RAW_hazard || decode_to_writeback_RAW_hazard
	
	# update timers
	current_tick += 1
	fetch_timer = fetch_timer - 1 if fetch_timer > 0 else 0
	if not stall_decode:
		decode_timer = decode_timer - 1 if decode_timer > 0 else 0
	execute_timer = execute_timer - 1 if execute_timer > 0 else 0
	memory_timer = memory_timer - 1 if memory_timer > 0 else 0
	writeback_timer = writeback_timer - 1 if writeback_timer > 0 else 0
	
	fetch_output_ready = fetch_timer == 0
	decode_output_ready = decode_timer == 0 && not stall_decode
	execute_output_ready = execute_timer == 0
	memory_output_ready = memory_timer == 0
	writeback_output_ready = writeback_timer == 0
	
	# commit is a fake stage to pull instructions from writeback
	# commit will pull new instruction from writeback if it knows writeback is ready to go
	commit_looking_for_new = writeback_output_ready
	
	# writeback will pull new instruction from memory if it knows mem is ready to go and it's done (commit is always ready to go)
	writeback_looking_for_new = memory_output_ready && writeback_output_ready
	
	# memory will pull new instruction from execute when it knows execute is ready to output, it's done and writeback is looking for something new
	memory_looking_for_new = execute_output_ready && memory_output_ready && writeback_looking_for_new
	
	# execute will pull new instruction from decode when it knows decode is ready to output, it's done, and memory is looking for something new
	execute_looking_for_new = decode_output_ready && execute_output_ready && memory_looking_for_new
	
	# decode will pull new instruction from fetch when it knows fetch is ready to output, it's done, and execute is looking for something new
	decode_looking_for_new = fetch_output_ready && decode_output_ready && execute_looking_for_new
	
	# fetch will pull new instructions when it knows it is ready and decode is looking for something new
	fetch_looking_for_new = fetch_output_ready && decode_looking_for_new
	
	if fetch_looking_for_new:
		fetch_buffer_new = fetch_index
		fetch_index = fetch_index + 1 if fetch_index < instructions.size() - 1 else 0
		fetch_timer = fetch_delay
		fetch_dirty = true
			
	if decode_looking_for_new:
		decode_buffer_new = fetch_buffer
		fetch_buffer = null
		if decode_buffer_new != null:
			decode_timer = decode_delay
		else:
			decode_timer = 1
		decode_dirty = true
		
	if execute_looking_for_new:
		execute_buffer_new = decode_buffer
		decode_buffer = null
		if execute_buffer_new != null:
			execute_timer = execute_delay
		else:
			execute_timer = 1
		execute_dirty = true
		
	if memory_looking_for_new:
		memory_buffer_new = execute_buffer
		execute_buffer = null
		if memory_buffer_new != null:
			var pinst = parsed_instructions[memory_buffer_new]
			if pinst[0] == "ld" || pinst[0] == "st":
				memory_timer = memory_delay
			else:
				memory_timer = 1
		else:
			memory_timer = 1
		memory_dirty = true
		
	if writeback_looking_for_new:
		writeback_buffer_new = memory_buffer
		memory_buffer = null
		if writeback_buffer_new != null:
			writeback_timer = writeback_delay
		else:
			writeback_timer = 1
		writeback_dirty = true
		
	if commit_looking_for_new:
		commit_buffer_new = writeback_buffer
		writeback_buffer = null
		commit_dirty = true
		
	print("F: " + str(fetch_buffer))
	print("D: " + str(decode_buffer))
	print("E: " + str(execute_buffer))
	print("M: " + str(memory_buffer))
	print("W: " + str(writeback_buffer))
	print("\n")
	
	
func _process(delta):
	var zero = Vector2(0, 0)
	
	if fetch_dirty:
		fetch_dirty = false
		if fetch_buffer_new != null:
			remove_child(instructions[fetch_buffer_new])
			fetch_stage.add_child(instructions[fetch_buffer_new])
			instructions[fetch_buffer_new].rect_position = zero
		fetch_buffer = fetch_buffer_new
		fetch_buffer_new = null
	
	if decode_dirty:
		decode_dirty = false
		if decode_buffer_new != null:
			fetch_stage.remove_child(instructions[decode_buffer_new])
			decode_stage.add_child(instructions[decode_buffer_new])
			instructions[decode_buffer_new].rect_position = zero
		decode_buffer = decode_buffer_new
		decode_buffer_new = null
		
	if execute_dirty:
		execute_dirty = false
		if execute_buffer_new != null:
			decode_stage.remove_child(instructions[execute_buffer_new])
			execute_stage.add_child(instructions[execute_buffer_new])
			instructions[execute_buffer_new].rect_position = zero
		execute_buffer = execute_buffer_new
		execute_buffer_new = null
		
	if memory_dirty:
		memory_dirty = false
		if memory_buffer_new != null:
			execute_stage.remove_child(instructions[memory_buffer_new])
			memory_stage.add_child(instructions[memory_buffer_new])
			instructions[memory_buffer_new].rect_position = zero
		memory_buffer = memory_buffer_new
		memory_buffer_new = null
		
	if writeback_dirty:
		writeback_dirty = false
		if writeback_buffer_new != null:
			memory_stage.remove_child(instructions[writeback_buffer_new])
			writeback_stage.add_child(instructions[writeback_buffer_new])
			instructions[writeback_buffer_new].rect_position = zero
		writeback_buffer = writeback_buffer_new
		writeback_buffer_new = null
		
	if commit_dirty:
		commit_dirty = false
		if commit_buffer_new != null:
			writeback_stage.remove_child(instructions[commit_buffer_new])
			instructions[commit_buffer_new].rect_position = Vector2(-100, -100)
			instructions_committed += 1
		commit_buffer_new = null
		if (current_tick != 0):
			$IpcLabel.text = "IPC: "+ str(float(instructions_committed)/current_tick)
		
func _ready():
	rng = RandomNumberGenerator.new()


func _on_DriveButton_pressed():
	$Timer.stop()
	for inst in instructions:
		inst.queue_free()
	instructions = []
	parsed_instructions = []

	for stage in stages:
		stage.queue_free()
		
	stages = []	
	
	var text = $CodeEdit.text
	parse_instructions(text)
	instructions_committed = 0
	current_tick = 0
	

var toggle_button_state = false
func _on_ToggleButton_pressed():
	toggle_button_state = not toggle_button_state
	if toggle_button_state:
		$Timer.start()
	else:
		$Timer.stop()
