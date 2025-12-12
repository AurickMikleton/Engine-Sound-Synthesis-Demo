extends Control

@onready var audio_player: AudioStreamPlayer = $AudioStreamPlayer
@onready var sample_hz: float = audio_player.stream.mix_rate
@onready var playback: AudioStreamPlayback

var throttle: float = 0.0

var rpm: float = idle_rpm
var pulse_hz: float = 0.0
var phase: float = 0.0
var ap_dn1: float = 0.0
var rumble_lfo_phase: float = 0.0

var muffler_buffer := PackedFloat32Array()
var muffler_index := 0

@export_category("Engine")
@export var cylinders: int = 4
@export var strokes: int = 4
@export var max_rpm: float = 7000.0
@export var idle_rpm: float = 750.0

@export_category("Sound Shape")
@export var firing_pattern := [1.0, 0.82, 1.28, 0.96] # ej25
#@export var firing_pattern := [1.067, 0.889, 1.133, 0.933, 0.911, 1.111, 0.844, 1.111] # coyote 5.0

var firing_step := 0
@export var duty_cycle: float = 0.30
@export var wave_quality: int = 12
@export var starting_volume: float = 0.12
@export var rumble_resonance: float = 0.32
@export var pattern_strength: float = 0.65
@export var lowpass_floor: float = 2000.0
@export var lowpass_ceiling: float = 12000.0

@export_category("Throttle")
@export var throttle_intake_gain: float = 0.45
@export var throttle_attack_sharpness: float = 0.35
@export var throttle_brightness_boost: float = 5000.0
@export var throttle_volume_gain: float = 0.4

@export_category("Muffler")
@export var muff_resonance := 180.0      # Hz — muffler chamber resonance
@export var muff_damping := 0.15         # 0–1 (higher = more damping)
@export var tailpipe_lp := 6000.0        # Hz — final low-pass to soften exhaust
@export var exhaust_echo_strength := 0.15 # 0–1, optional
@export var exhaust_echo_delay := 0.012   # seconds
#@export var muffler_length_ms: float = 18.0 # Delay time in ms (exhaust pipe length)

@export_category("Burble")
@export var enable_burble: bool = true
@export var burble_intensity: float = 1.5
@export var burble_timer := 0.1
@export var burble_gap := 0.2
var burble_active := false

var muff_vel := 0.0
var muff_pos := 0.0
var lp_prev := 0.0
var echo_buffer := []
var echo_index := 0

func init_exhaust_dsp(sample_rate: float):
	var echo_len := int(exhaust_echo_delay * sample_rate)
	echo_buffer.resize(max(echo_len, 1))
	for i in echo_buffer.size():
		echo_buffer[i] = 0.0
	echo_index = 0

func _ready():
	set_rpm($HSlider.value)
	audio_player.stream.mix_rate = sample_hz
	audio_player.play()
	playback = audio_player.get_stream_playback()
	
	init_exhaust_dsp(sample_hz)
	
	_fill_buffer()

func set_rpm(new_rpm: float):
	rpm = new_rpm
	pulse_hz = (rpm / 60.0) * (cylinders / (strokes / 2.0))

func _on_h_slider_value_changed(value):
	set_rpm(float(value))
	$Label.text = "RPM: " + str(int(rpm))

func _on_v_slider_value_changed(value: float) -> void:
	throttle = float(value)

func _process(_delta):
	_fill_buffer()
	$fps.text = "FPS: " + str(Engine.get_frames_per_second())


func _fill_buffer():
	if playback == null: return
		
	var frames :float = playback.get_frames_available()
	if frames <= 0: return
		
	var buffer := PackedFloat32Array()
	buffer.resize(int(frames))
	
	for i in frames:
		# uneven firing
		var pattern : float = firing_pattern[firing_step]
		firing_step = (firing_step + 1) % firing_pattern.size()
		
		var phase_increment : float = (pulse_hz / sample_hz) * lerp(1.0, pattern, pattern_strength)
		
		# Pulse wave
		var pulse := 0.0
		for h in range(1, wave_quality + 1):
			var sharp := 1.0 + throttle * throttle_attack_sharpness
			pulse += (sin(PI * h * duty_cycle * sharp) / h) * cos(TAU * h * phase)
		pulse = (pulse * (4/PI)) + (2*duty_cycle - 1)
		
		var noise := randf() * 0.6 + randf() * 0.3 + randf() * 0.1
		var base_engine : float = max(0.0, pulse) * noise
		
		var intake := throttle * throttle_intake_gain * (randf() * 0.6 + 0.4)
		
		var rumble := sin(rumble_lfo_phase) * rumble_resonance
		rumble_lfo_phase = fmod(rumble_lfo_phase + 0.002 + (rpm / 200000.0), TAU)
		
		var raw := base_engine + rumble + intake
	
		var vol := starting_volume + (rpm / max_rpm) * (1.0 - starting_volume)
		vol += throttle * throttle_volume_gain
		raw *= vol
		
		raw = apply_burbles(raw, sample_hz)
		var exhaust := exhaust_dsp(raw, sample_hz)
		buffer[i] = exhaust
		phase = fmod(phase + phase_increment, 1.0)
		
	#var muffled := apply_muffler(buffer)
	var filtered := lowpass(buffer)
	
	for i in filtered.size():
		playback.push_frame(Vector2.ONE * filtered[i])

func lowpass(input: PackedFloat32Array) -> PackedFloat32Array:
	var output := PackedFloat32Array()
	output.resize(input.size())
	
	var rpm_ratio : float = clamp((rpm - idle_rpm) / (max_rpm - idle_rpm), 0.0, 1.0)
	
	var cutoff : float = lerp(lowpass_floor, lowpass_ceiling, rpm_ratio)
	cutoff += throttle * throttle_brightness_boost
	cutoff = min(cutoff, sample_hz*0.45)
	
	var t := tan(PI * cutoff / sample_hz)
	var a1 := (t - 1.0) / (t + 1.0)
	
	for i in input.size():
		var x := input[i]
		var ap := a1 * x + ap_dn1
		ap_dn1 = x - a1 * ap
		output[i] = 0.5 * (x + ap)
		
	return output

func exhaust_dsp(input_sample: float, sample_rate: float) -> float:
	var k := (PI * 2.0 * muff_resonance) / sample_rate
	var d := muff_damping
	
	# damped harmonic oscillator
	muff_vel += (input_sample - muff_pos) * k
	muff_vel *= (1.0 - d)
	muff_pos += muff_vel
	
	var resonated := muff_pos
	# ----- Tailpipe Low-Pass -----
	var rc := 1.0 / (PI * 2.0 * tailpipe_lp)
	var alpha := clampf(sample_rate * rc / (sample_rate * rc + 1.0), 0.0, 1.0)
	var low_passed := lp_prev + alpha * (resonated - lp_prev)
	lp_prev = low_passed
	# ----- Optional Reflection Echo -----
	var delayed : float = echo_buffer[echo_index]
	echo_buffer[echo_index] = low_passed
	echo_index = (echo_index + 1) % echo_buffer.size()
	
	var out := low_passed + delayed * exhaust_echo_strength
	return out

func apply_burbles(raw: float, sample_rate: float) -> float:
	# Trigger when throttle is nearly closed and RPM is above idle
	if enable_burble and throttle < 0.1 and rpm > idle_rpm + 400:
		if not burble_active:
			# Start a "cluster" of pops: 50–200 ms
			burble_active = true
			burble_timer = randf_range(0.05, 0.20)
			burble_gap = 0.0
	else:
		burble_active = false
	
	# If no burbles active → return untouched raw sample
	if not burble_active:
		return raw
	
	# Burble cluster progression
	burble_timer -= 1.0 / sample_rate
	if burble_timer <= 0.0:
		burble_active = false
		return raw
	
	# Time until next pop
	burble_gap -= 1.0 / sample_rate
	if burble_gap <= 0.0:
		# Create a pop
		var pop := (randf_range(-1.0, 1.0)
			* burble_intensity
			* (rpm / max_rpm + 0.4))
	
		# Crisp envelope (gives the "snap")
		pop *= pop * pop
	
		raw += pop
	
		# Random gap between pops: 2–15 ms
		burble_gap = randf_range(0.002, 0.015)
	
	return raw
