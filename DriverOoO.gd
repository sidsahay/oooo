extends Node2D

# In case you're thinking this is horrible code
# 1. Yes, it is.
# 2. Switching to Godot and GDScript was a last second decision when p5.js wasn't working out. I literally learnt this as I made this.
# 3. I learnt that each GDScript file is actually a class AFTER making most of this. Yeah.
# 4. Feel free to send PRs with code refactors. Much appreciated. Thanks.

var instruction_scene = preload("res://Instruction.tscn")
var stage_scene = preload("res://Stage.tscn")
var rob_entry_scene = preload("res://ROBEntry.tscn")
var iq_entry_scene = preload("res://IQEntry.tscn")

var instructions = []
var parsed_instructions = []
var stages = []
var rob_entries = []
var iq_entries = []

var alu_stages = []
var lsu_stages = []
var br_stage = null

var alu_buffers = []
var lsu_buffers = []
var br_buffer = null

# yes I know "dirtys" is not a word. Leave me alone.
var alu_dirtys = []
var lsu_dirtys = []
var br_dirty = false

var alu_timers = []
var lsu_timers = []
var br_timer = 0

# yes I know "entrys" is not a word. Leave me alone.
var alu_rob_entrys = []
var lsu_rob_entrys = []
var br_rob_entry = null

var alu_speculating = []
var lsu_speculating = []

# is the processor speculating on an instruction?
var speculating = false

# ROB and IQ data
var rob_table = []
var iq_table = []

# architectural register file
var arf_table = []
var backup_arf_table = []

var fetch_index = 0

# ROB head points to the first full space in the ROB
var rob_head = 0
# ROB tail points to space after the last full space in the ROB 
var rob_tail = 0

# IQ head points to first full space in the IQ
var iq_head = 0
# IQ tail points to the space after the last full space in the IQ
var iq_tail = 0

var rob_dirty = []
var iq_dirty = []

var rob_start = true
var last_issue = -1

export var rob_size = 16
export var iq_size = 8
export var issue_width = 4
export var commit_width = 4
export var alu_delay = 1
export var lsu_delay = 1
export var br_delay = 1
export var num_alus = 2
export var num_lsus = 2
export var bp_accuracy = 0.5

var rng = null

var ROB_BUSY = 0
var ROB_ISSUED = 1
var ROB_FINISHED = 2
var ROB_IA = 3
var ROB_RR = 4
var ROB_SPECULATING = 5

var IQ_BUSY = 0
var IQ_IA = 1
var IQ_OP1 = 2
var IQ_VALID1 = 3
var IQ_OP2 = 4
var IQ_VALID2 = 5
var IQ_OUT = 6
var IQ_READY = 7
var IQ_SPECULATING = 8

var current_tick = 0

var instructions_committed = 0
var major_cycles = 0

export var ROB_FREE_COLOR = Color("484848")
#export var ROB_FREE_COLOR = Color("870000")
export var ROB_BUSY_COLOR = Color("f9683a")
export var ROB_SPECULATING_COLOR = Color("7c43bd")

export var IQ_FREE_COLOR = Color("484848")
#export var IQ_FREE_COLOR = Color("002f6c")
export var IQ_BUSY_COLOR = Color("4f83cc")
export var IQ_SPECULATING_COLOR = Color("7c43bd")

export var STAGE_FREE_COLOR = Color("484848")
#export var STAGE_FREE_COLOR = Color("003d00")
export var STAGE_BUSY_COLOR = Color("629749")

var ROB_INDICATOR_OFFSET = Vector2(15, -50)

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
		
	var y = 0
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
		#add_child(inst)
		inst.rect_position = Vector2(-1000, -1000)
		instructions.push_back(inst)
		


func _ready():
	rng = RandomNumberGenerator.new()
	var y = 800
	var x = 50
	for i in range(rob_size):
		var r = rob_entry_scene.instance()
		r.get_node("Busy").text = "0"
		r.get_node("Issued").text = "0"
		r.get_node("Finished").text = "0"
		r.get_node("IA").text = "0"
		r.get_node("RR").text = "-"
		r.get_node("ColorRect").color = ROB_FREE_COLOR
		add_child(r)
		r.rect_position = Vector2(x, y)
		x += 70
		rob_entries.push_back(r)
		rob_table.push_back([0, 0, 0, -1, -1, 0]) # last bit is "speculating?"
		
	$HeadIndicator.rect_position = rob_entries[0].rect_global_position + ROB_INDICATOR_OFFSET
	$TailIndicator.rect_position = rob_entries[0].rect_global_position + ROB_INDICATOR_OFFSET
	
	x = 700
	y = 30
	for i in range(iq_size):
		var q = iq_entry_scene.instance()
		q.get_node("Busy").text = "0"
		q.get_node("Op1").text = "-"
		q.get_node("Valid1").text = "0"
		q.get_node("Op2").text = "-"
		q.get_node("Valid2").text = "0"
		q.get_node("Out").text = "-"
		q.get_node("Ready").text = "0"
		q.get_node("ColorRect").color = IQ_FREE_COLOR
		add_child(q)
		q.rect_position = Vector2(x, y)
		y += 50
		iq_entries.push_back(q)
		iq_table.push_back([0, 0, "", 0, "", 0, "", 0, 0]) # last bit is "speculating?"
		
	# 32 register ARF
	for i in range(32):
		arf_table.push_back(-1) # -1 = not in ROB
		backup_arf_table.push_back(-1) # init backup table to roll back speculatives
		
	# make processing stages
	
	y = 650
	for _i in range(num_alus):
		var alu_stage = stage_scene.instance()
		alu_stage.get_node("ColorRect").color = STAGE_FREE_COLOR
		add_child(alu_stage)
		alu_stage.rect_position = Vector2(400, y)
		y += 60
		alu_stages.push_back(alu_stage)
		alu_buffers.push_back(null)
		alu_dirtys.push_back(false)
		alu_timers.push_back(0)
		alu_rob_entrys.push_back(null)
		alu_speculating.push_back(0)
	
	# convert delay from major cycles to sub cycles
	alu_delay *= issue_width
	
	y = 650
	for _i in range(num_lsus):
		var lsu_stage = stage_scene.instance()
		add_child(lsu_stage)
		lsu_stage.rect_position = Vector2(850, y)
		lsu_stage.get_node("ColorRect").color = STAGE_FREE_COLOR
		y += 60
		lsu_stages.push_back(lsu_stage)
		lsu_buffers.push_back(null)
		lsu_dirtys.push_back(false)
		lsu_timers.push_back(0)
		lsu_rob_entrys.push_back(null)
		lsu_speculating.push_back(0)
		
	# convert delay from major cycles to sub cycles
	lsu_delay *= issue_width
		
	br_stage = stage_scene.instance()
	add_child(br_stage)
	br_stage.rect_position = Vector2(1300, 650)
	br_stage.get_node("ColorRect").color = STAGE_FREE_COLOR
	speculating = false
	
	# convert delay from major cycles to sub cycles
	br_delay *= issue_width


func rob_is_full():
	if (rob_tail - rob_head) == rob_size:
		return true
	else:
		return false

func rob_is_empty():
	if (rob_tail - rob_head) == 0:
		return true
	else:
		return false
		
func iq_is_full():
	for entry in iq_table:
		if entry[0] == 0:
			return false
	return true

func get_first_iq_empty():
	for i in range(iq_table.size()):
		if iq_table[i][0] == 0:
			return i
	return -1
	
func tick():
	for i in range(num_alus):
		alu_timers[i] = alu_timers[i] - 1 if alu_timers[i] > 0 else 0
	for i in range(num_lsus):
		lsu_timers[i] = lsu_timers[i] - 1 if lsu_timers[i] > 0 else 0
	br_timer = br_timer - 1 if br_timer > 0 else 0
		
	# check if issue_cycle = is major cycle
	var is_issue_cycle = (current_tick % issue_width) == 0
	
	current_tick += 1
	
	if is_issue_cycle:
		major_cycles += 1
		# first, do commit
		var effective_rob_idx = rob_head % rob_size;
		for i in range(commit_width):
			if not rob_is_empty():
				var t = rob_table[(effective_rob_idx + i) % rob_size]
				if t[ROB_FINISHED] == 1 || (t[ROB_BUSY] == 0 && t[ROB_SPECULATING] == 1):
					print("Checking for commit: " + str((effective_rob_idx + i) % rob_size))
					print("Busy: " + str(t[ROB_BUSY]) + " Spec: " + str(t[ROB_SPECULATING]) + " Fin: " + str(t[ROB_FINISHED]))
					if t[ROB_FINISHED] == 1 && t[ROB_BUSY] == 1 && t[ROB_SPECULATING] == 0:
						# update the ARF unless the instruction is a st or br because those don't write anything
						var inst = parsed_instructions[t[ROB_IA]]
						# if there are no other ROB entries writing to that register, mark architectural state update in ARF
						# get the register being written to
						if (inst[0] != "st") && (inst[0] != "br"):
							var dest_register = inst[1]
							var last_update = true
							for k in range(rob_head + i + 1, rob_tail):
								var k_inst = parsed_instructions[rob_table[k % rob_size][ROB_IA]]
								if (k_inst[0] != "st") && (k_inst[0] != "br"):
									var k_dest_register = k_inst[1]
									if k_dest_register == dest_register:
										last_update = false
										break
							if not last_update:
								pass
							else:
								arf_table[dest_register] = -1
						rob_head += 1
						t[ROB_BUSY] = 0
						t[ROB_ISSUED] = 0
						t[ROB_FINISHED] = 0
						t[ROB_IA] = 0
						t[ROB_RR] = -1
						t[ROB_SPECULATING] = 0
						rob_dirty.push_back((effective_rob_idx + i) % rob_size)
						instructions_committed += 1
					elif (t[ROB_BUSY] == 0) && (t[ROB_SPECULATING] == 1):
						# do not commit any instructions
						print("committing speculative")
						t[ROB_BUSY] = 0
						t[ROB_ISSUED] = 0
						t[ROB_FINISHED] = 0
						t[ROB_IA] = 0
						t[ROB_RR] = -1
						t[ROB_SPECULATING] = 0
						rob_head += 1
						rob_dirty.push_back((effective_rob_idx + i) % rob_size)
				else:
					break
			
		# second, do execute
		# check branch predictor
		if br_timer == 0 && br_buffer != null:
			rob_table[br_rob_entry][ROB_FINISHED] = 1
			var bp_succeeded = false #rng.randf() < bp_accuracy
			if bp_succeeded:
				# branch does not write to anything
				rob_dirty.push_back(br_rob_entry)
				br_buffer = null
				br_rob_entry = null
				br_dirty = true
			else:
				# kill all speculative instructions in ALUs
				for k in range(num_alus):
					if alu_speculating[k] == 1:
						alu_speculating[k] = 0
						alu_buffers[k] = null
						alu_rob_entrys[k] = null
						alu_timers[k] = 0
						alu_dirtys[k] = true
						
				# kill all speculative instructions in LSUs
				for k in range(num_lsus):
					if lsu_speculating[k] == 1:
						lsu_speculating[k] = 0
						lsu_buffers[k] = null
						lsu_rob_entrys[k] = null
						lsu_timers[k] = 0
						lsu_dirtys[k] = true
						
				# kill all speculative instructions in IQ
				for i in range(iq_size):
					if iq_table[i][IQ_SPECULATING] == 1:
						iq_table[i] = [0, 0, "", 0, "", 0, "", 0, 0]
						iq_dirty.push_back(i)
				
				# kill all speculative instructions in ROB
				for i in range(rob_size):
					if rob_table[i][ROB_SPECULATING] == 1:
						rob_table[i][ROB_BUSY] = 0
						rob_dirty.push_back(i)
				
				# reset ARF
				for i in range(arf_table.size()):
					arf_table[i] = backup_arf_table[i]
					
				# we are not speculating any more 
				speculating = false
				print("branch rewound")
				br_dirty = true
				rob_dirty.push_back(br_rob_entry)
				br_buffer = null
				br_rob_entry = null
				br_dirty = true
					
		for k in range(num_alus):
			if alu_timers[k] == 0 && alu_buffers[k] != null:
				rob_table[alu_rob_entrys[k]][ROB_FINISHED] = 1
				var rob_str = "r" + str(alu_rob_entrys[k])
				
				# wake up instructions
				for i in range(iq_table.size()):
					if iq_table[i][IQ_OP1] == rob_str:
						iq_table[i][IQ_VALID1] = 1
					if iq_table[i][IQ_OP2] == rob_str:
						iq_table[i][IQ_VALID2] = 1
						
				rob_dirty.push_back(alu_rob_entrys[k])
				alu_buffers[k] = null
				alu_rob_entrys[k] = null
				alu_dirtys[k] = true
				alu_speculating[k] = 0 # ALU is done with instruction, no speculation


		for k in range(num_lsus):
			if lsu_timers[k] == 0 && lsu_buffers[k] != null:
				rob_table[lsu_rob_entrys[k]][ROB_FINISHED] = 1
				var rob_str = "r" + str(lsu_rob_entrys[k])
				
				# wake up instructions
				for i in range(iq_table.size()):
					if iq_table[i][IQ_OP1] == rob_str:
						iq_table[i][IQ_VALID1] = 1
					if iq_table[i][IQ_OP2] == rob_str:
						iq_table[i][IQ_VALID2] = 1
						
				rob_dirty.push_back(lsu_rob_entrys[k])
				lsu_buffers[k] = null
				lsu_rob_entrys[k] = null
				lsu_dirtys[k] = true
				lsu_speculating[k] = 0 # LSU is done with instruction, no speculation
		
				
		for i in range(iq_table.size()):
			var old_ready = iq_table[i][IQ_READY]
			var new_ready = 1 if iq_table[i][IQ_VALID1] == 1 && iq_table[i][IQ_VALID2] == 1 else 0
			if new_ready != old_ready:
				iq_table[i][IQ_READY] = new_ready
				iq_dirty.push_back(i)

		# now do issue
		# find first entries in IQ to issue in a circular fashion to prevent starvation
		for _k in range(issue_width):
			var ready_idx = null
			var after_last_issue = (last_issue + 1) % iq_size
			for i in range(after_last_issue, iq_table.size()):
				if iq_table[i][IQ_READY] == 1:
					ready_idx = i
					break
			if ready_idx == null:
				for i in range(0, after_last_issue):
					if iq_table[i][IQ_READY] == 1:
						ready_idx = i
						break
			
			if ready_idx != null:
				# check if there is an execution unit ready to go
				var inst = parsed_instructions[iq_table[ready_idx][IQ_IA]]
				if inst[0] == "ad":
					for k in range(num_alus):
						if alu_buffers[k] == null:
							alu_buffers[k] = iq_table[ready_idx][IQ_IA]
							alu_dirtys[k] = true
							alu_timers[k] = alu_delay
							alu_speculating[k] = 1 if speculating else 0
							var rob_idx = iq_table[ready_idx][IQ_OUT]
							alu_rob_entrys[k] = rob_idx
							rob_table[rob_idx][ROB_ISSUED] = 1
							iq_table[ready_idx] = [0, 0, "", 0, "", 0, "", 0, 0]
							rob_dirty.push_back(rob_idx)
							iq_dirty.push_back(ready_idx)
							last_issue = ready_idx
							break
				elif inst[0] == "ld" || inst[0] == "st":
					for k in range(num_lsus):
						if lsu_buffers[k] == null:
							lsu_buffers[k] = iq_table[ready_idx][IQ_IA]
							lsu_dirtys[k] = true
							lsu_timers[k] = lsu_delay
							lsu_speculating[k] = 1 if speculating else 0
							var rob_idx = iq_table[ready_idx][IQ_OUT]
							lsu_rob_entrys[k] = rob_idx
							rob_table[rob_idx][ROB_ISSUED] = 1
							iq_table[ready_idx] = [0, 0, "", 0, "", 0, "", 0, 0]
							rob_dirty.push_back(rob_idx)
							iq_dirty.push_back(ready_idx)
							last_issue = ready_idx
							break
				elif inst[0] == "br":
					if br_buffer == null:
						br_buffer = iq_table[ready_idx][IQ_IA]
						br_dirty = true
						br_timer = br_delay
						var rob_idx = iq_table[ready_idx][IQ_OUT]
						br_rob_entry = rob_idx
						rob_table[rob_idx][ROB_ISSUED] = 1
						iq_table[ready_idx] = [0, 0, "", 0, "", 0, "", 0, 0]
						rob_dirty.push_back(rob_idx)
						iq_dirty.push_back(ready_idx)
						last_issue = ready_idx
						print("branch issued")
						

						
	# Each "tick" is a sub-cycle
	var inst = parsed_instructions[fetch_index]
	var inst_idx = fetch_index
	
	# we assume fetch and decode happen on their own
	
	# if there is space in the ROB and IQ
	if (not rob_is_full()) and (not iq_is_full() and not (speculating and (inst[0] == "br"))):
		# we can allocate, update fetch
		fetch_index = fetch_index + 1 if fetch_index < (instructions.size() - 1) else 0
		
		var rob_idx = rob_tail % rob_size
		rob_tail = rob_tail + 1
		#print("ROB idx: " + str(rob_idx))
		var iq_idx = get_first_iq_empty()
		
		# fill the ROB entry
		rob_table[rob_idx][ROB_BUSY] = 1
		rob_table[rob_idx][ROB_ISSUED] = 0
		rob_table[rob_idx][ROB_FINISHED] = 0
		rob_table[rob_idx][ROB_IA] = inst_idx
		rob_table[rob_idx][ROB_RR] = rob_idx
		rob_table[rob_idx][ROB_SPECULATING] = 1 if speculating else 0
		rob_dirty.push_back(rob_idx)
		
		# fill the IQ entry
		iq_table[iq_idx][IQ_BUSY] = 1
		iq_table[iq_idx][IQ_IA] = inst_idx
		#print("IQ IA:" + str(iq_table[iq_idx][IQ_IA]))
		
		# branches and stores have inst[1] as op1
		if (inst[0] != "br") and (inst[0] != "st"):
			var rob_output_idx1 = arf_table[inst[2]]
			if rob_output_idx1 == -1:
				iq_table[iq_idx][IQ_OP1] = "x" + str(inst[2])
				iq_table[iq_idx][IQ_VALID1] = 1
			else:
				iq_table[iq_idx][IQ_OP1] = "r" + str(rob_output_idx1)
				iq_table[iq_idx][IQ_VALID1] = rob_table[rob_output_idx1][ROB_FINISHED]
		else:
			var rob_output_idx1 = arf_table[inst[1]]
			if rob_output_idx1 == -1:
				iq_table[iq_idx][IQ_OP1] = "x" + str(inst[1])
				iq_table[iq_idx][IQ_VALID1] = 1
			else:
				iq_table[iq_idx][IQ_OP1] = "r" + str(rob_output_idx1)
				iq_table[iq_idx][IQ_VALID1] = rob_table[rob_output_idx1][ROB_FINISHED]
			
		# branches and stores have a different op2
		if (inst[0] == "ad"):
			var rob_output_idx2 = arf_table[inst[3]]
			if rob_output_idx2 == -1:
				iq_table[iq_idx][IQ_OP2] = "x" + str(inst[3])
				iq_table[iq_idx][IQ_VALID2] = 1
			else:
				iq_table[iq_idx][IQ_OP2] = "r" + str(rob_output_idx2)
				iq_table[iq_idx][IQ_VALID2] = rob_table[rob_output_idx2][ROB_FINISHED]
		elif (inst[0] == "st"):
			#print("hit store")
			var rob_output_idx2 = arf_table[inst[2]]
			if rob_output_idx2 == -1:
				iq_table[iq_idx][IQ_OP2] = "x" + str(inst[2])
				iq_table[iq_idx][IQ_VALID2] = 1
			else:
				iq_table[iq_idx][IQ_OP2] = "r" + str(rob_output_idx2)
				iq_table[iq_idx][IQ_VALID2] = rob_table[rob_output_idx2][ROB_FINISHED]
		else:
			iq_table[iq_idx][IQ_OP2] = "-"
			iq_table[iq_idx][IQ_VALID2] = 1
		
				
		iq_table[iq_idx][IQ_OUT] = rob_idx
		iq_table[iq_idx][IQ_SPECULATING] = 1 if speculating else 0
		iq_dirty.push_back(iq_idx)
		
		# store and branch only read from the first op, not write
		if (inst[0] != "st") and (inst[0] != "br"):
			#if (inst[0] == "ld"):
				#print("hit ld")
			arf_table[inst[1]] = rob_idx
			
		if inst[0] == "br":
			speculating = true
			
		
	# update ready
	for i in range(iq_table.size()):
		var old_ready = iq_table[i][IQ_READY]
		var new_ready = 1 if iq_table[i][IQ_VALID1] == 1 && iq_table[i][IQ_VALID2] == 1 else 0
		if new_ready != old_ready:
			iq_table[i][IQ_READY] = new_ready
			iq_dirty.push_back(i)

		
func _process(delta):
	if rob_dirty != []:
		for i in rob_dirty:
			var r = rob_entries[i]
			var t = rob_table[i]
			r.get_node("Busy").text = str(t[ROB_BUSY])
			r.get_node("Issued").text = str(t[ROB_ISSUED])
			r.get_node("Finished").text = str(t[ROB_FINISHED])
			if t[ROB_BUSY] == 1:
				r.get_node("IA").text = "i" + str(t[ROB_IA])
				r.get_node("RR").text = "r" + str(t[ROB_RR])
			else:
				r.get_node("IA").text = "-"
				r.get_node("RR").text = "-"
			if t[ROB_BUSY] == 1 && t[ROB_SPECULATING] == 1:
				r.get_node("ColorRect").color = ROB_SPECULATING_COLOR
			elif t[ROB_BUSY] == 1:
				r.get_node("ColorRect").color = ROB_BUSY_COLOR
			else:
				r.get_node("ColorRect").color = ROB_FREE_COLOR
		rob_dirty = []
		$HeadIndicator.rect_position = rob_entries[rob_head % rob_size].rect_global_position + ROB_INDICATOR_OFFSET
		$TailIndicator.rect_position = rob_entries[rob_tail % rob_size].rect_global_position + ROB_INDICATOR_OFFSET
		if major_cycles != 0:
			$IPCLabel.text = "IPC: " + str(float(instructions_committed)/major_cycles)
		else:
			$IPCLabel.text = "IPC: 0"
		
	if iq_dirty != []:
		for i in iq_dirty:
			var q = iq_entries[i]
			var t = iq_table[i]
			q.get_node("Busy").text = str(t[IQ_BUSY])
			q.get_node("IA").text = "i" + str(t[IQ_IA])
			q.get_node("Op1").text = t[IQ_OP1]
			q.get_node("Valid1").text = str(t[IQ_VALID1])
			q.get_node("Op2").text = t[IQ_OP2]
			q.get_node("Valid2").text = str(t[IQ_VALID2])
			q.get_node("Out").text = "r" + str(t[IQ_OUT])
			q.get_node("Ready").text = str(t[IQ_READY])
			if t[IQ_BUSY] == 1 && t[IQ_SPECULATING] == 1:
				q.get_node("ColorRect").color = IQ_SPECULATING_COLOR
			elif t[IQ_BUSY] == 1:
				q.get_node("ColorRect").color = IQ_BUSY_COLOR
			else:
				q.get_node("ColorRect").color = IQ_FREE_COLOR
		iq_dirty = []
		
	for k in range(num_alus):
		if alu_dirtys[k]:
			if alu_buffers[k] != null:
				alu_stages[k].get_node("Label").text = "i" + str(alu_buffers[k])
				alu_stages[k].get_node("ColorRect").color = STAGE_BUSY_COLOR
			else:
				alu_stages[k].get_node("Label").text = ""
				alu_stages[k].get_node("ColorRect").color = STAGE_FREE_COLOR
			alu_dirtys[k] = false

	for k in range(num_lsus):				
		if lsu_dirtys[k]:
			if lsu_buffers[k] != null:
				lsu_stages[k].get_node("Label").text = "i" + str(lsu_buffers[k])
				lsu_stages[k].get_node("ColorRect").color = STAGE_BUSY_COLOR
			else:
				lsu_stages[k].get_node("Label").text = ""
				lsu_stages[k].get_node("ColorRect").color = STAGE_FREE_COLOR
			lsu_dirtys[k] = false
	
	if br_dirty:
		print("br dirty")
		if br_buffer != null:
			br_stage.get_node("Label").text = "i" + str(br_buffer)
			br_stage.get_node("ColorRect").color = STAGE_BUSY_COLOR
		else:
			br_stage.get_node("Label").text = ""
			br_stage.get_node("ColorRect").color = STAGE_FREE_COLOR
		br_dirty = false

func _on_DriverButton_pressed():
	parse_instructions($CodeEdit.text)

var timer_state = false
func _on_ToggleButton_pressed():
	timer_state = not timer_state
	if timer_state:
		$Timer.start()
	else:
		$Timer.stop()
