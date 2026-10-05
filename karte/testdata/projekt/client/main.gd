extends Node
const Hud = preload("res://client/hud.gd")

func _ready():
	Hud.text(1)
	call_deferred("_open")
	_open()
	$Panel.text = "text"
	var d := {"text": 1}

# _open nur im Kommentar
func _open():
	pass
