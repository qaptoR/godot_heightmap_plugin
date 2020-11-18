tool
extends Control

const HTerrainTextureSet = preload("../../../hterrain_texture_set.gd")
const Logger = preload("../../../util/logger.gd")
const EditorUtil = preload("../../util/editor_util.gd")
const Errors = preload("../../../util/errors.gd")
const TextureSetEditor = preload("./texture_set_editor.gd")
const Result = preload("../../util/result.gd")
const Util = preload("../../../util/util.gd")

const COMPRESS_RAW = 0
const COMPRESS_LOSSLESS = 1
const COMPRESS_LOSSY = 2
const COMPRESS_VRAM = 3
const COMPRESS_COUNT = 4

const _compress_names = ["Raw", "Lossless", "Lossy", "VRAM"]

# Indexed by HTerrainTextureSet.SRC_TYPE_* constants
const _smart_pick_file_keywords = [
	["albedo", "color", "col"],
	["bump", "height", "depth", "displacement", "disp"],
	["normal", "norm", "nrm"],
	["roughness", "rough", "rgh"]
]

signal import_finished

onready var _texture_editors = [
	$Import/HS/VB2/HB/Albedo,
	$Import/HS/VB2/HB/Bump,
	$Import/HS/VB2/HB/Normal,
	$Import/HS/VB2/HB/Roughness
]

onready var _slots_list = $Import/HS/VB/SlotsList

onready var _import_mode_selector = $Import/GC/ImportModeSelector
onready var _compression_selector = $Import/GC/CompressionSelector
onready var _resolution_spinbox = $Import/GC/ResolutionSpinBox
onready var _mipmaps_checkbox = $Import/GC/MipmapsCheckbox
onready var _filter_checkbox = $Import/GC/FilterCheckBox
onready var _add_slot_button = $Import/HS/VB/HB/AddSlotButton
onready var _remove_slot_button = $Import/HS/VB/HB/RemoveSlotButton
onready var _import_directory_line_edit : LineEdit = $Import/HB2/ImportDirectoryLineEdit

var _texture_set : HTerrainTextureSet
var _undo_redo : UndoRedo
var _logger = Logger.get_for(self)

# This is normally an `EditorFileDialog`. I can't type-hint this one properly,
# because when I test this UI in isolation, I can't use `EditorFileDialog`.
var _load_texture_dialog : WindowDialog
var _load_texture_type : int = -1
var _error_popup : AcceptDialog
var _info_popup : AcceptDialog
var _delete_confirmation_popup : ConfirmationDialog
var _open_dir_dialog : ConfirmationDialog
var _editor_file_system : EditorFileSystem

var _import_mode = HTerrainTextureSet.MODE_TEXTURES

var _slots_data = [
	["", "", "", ""],
	#...
]

var _import_settings = {
	"mipmaps": true,
	"filter": true,
	"compression": COMPRESS_VRAM,
	"resolution": 512
}


func _init():
	# Default data
	_slots_data.clear()
	for i in 4:
		var src = []
		src.resize(HTerrainTextureSet.SRC_TYPE_COUNT)
		for j in len(src):
			src[j] = ""
		_slots_data.append(src)


func _ready():
	if Util.is_in_edited_scene(self):
		return

	for src_type in len(_texture_editors):
		var ed = _texture_editors[src_type]
		var typename = HTerrainTextureSet.get_source_texture_type_name(src_type)
		ed.set_label(typename.capitalize())
		ed.connect("load_pressed", self, "_on_texture_load_pressed", [src_type])
		ed.connect("clear_pressed", self, "_on_texture_clear_pressed", [src_type])
	
	for import_mode in HTerrainTextureSet.MODE_COUNT:
		var n = HTerrainTextureSet.get_import_mode_name(import_mode)
		_import_mode_selector.add_item(n, import_mode)

	for compress_mode in COMPRESS_COUNT:
		var n = _compress_names[compress_mode]
		_compression_selector.add_item(n, compress_mode)


func setup_dialogs(parent: Node):
	var d = EditorUtil.create_open_texture_dialog()
	d.connect("file_selected", self, "_on_LoadTextureDialog_file_selected")
	_load_texture_dialog = d
	parent.add_child(d)
	
	d = AcceptDialog.new()
	d.window_title = "Import error"
	_error_popup = d
	parent.add_child(_error_popup)

	d = AcceptDialog.new()
	d.window_title = "Info"
	_info_popup = d
	parent.add_child(_info_popup)
	
	d = ConfirmationDialog.new()
	d.connect("confirmed", self, "_on_delete_confirmation_popup_confirmed")
	_delete_confirmation_popup = d
	parent.add_child(_delete_confirmation_popup)
	
	d = EditorUtil.create_open_dir_dialog()
	d.window_title = "Choose import directory"
	d.connect("dir_selected", self, "_on_OpenDirDialog_dir_selected")
	_open_dir_dialog = d
	parent.add_child(_open_dir_dialog)
	
	_update_ui_from_data()


func _notification(what: int):
	if what == NOTIFICATION_EXIT_TREE:
		# Have to check for null in all of them,
		# because otherwise it breaks in the scene editor...
		if _load_texture_dialog != null:
			_load_texture_dialog.queue_free()
		if _error_popup != null:
			_error_popup.queue_free()
		if _delete_confirmation_popup != null:
			_delete_confirmation_popup.queue_free()
		if _open_dir_dialog != null:
			_open_dir_dialog.queue_free()
		if _info_popup != null:
			_info_popup.queue_free()


# TODO Is it still necessary for an import tab?
func set_undo_redo(ur: UndoRedo):
	_undo_redo = ur


func set_editor_file_system(efs: EditorFileSystem):
	_editor_file_system = efs


func set_texture_set(texture_set: HTerrainTextureSet):
	if _texture_set == texture_set:
		# TODO What if the set was actually modified since?
		return
	_texture_set = texture_set

	_slots_data.clear()
	
	if _texture_set.get_mode() == HTerrainTextureSet.MODE_TEXTURES:
		var slots_count = _texture_set.get_slots_count()
		
		for slot_index in slots_count:
			var source_textures = []
			for i in HTerrainTextureSet.SRC_TYPE_COUNT:
				source_textures.append("")
			
			for type in HTerrainTextureSet.TYPE_COUNT:
				var texture = _texture_set.get_texture(slot_index, type)
				
				if texture == null or texture.resource_path == "":
					continue
				
				if not texture.resource_path.ends_with(".packed_tex"):
					continue
				
				var import_data := _parse_json_file(texture.resource_path)
				if import_data.empty() or not import_data.has("src"):
					continue
				
				var src_types = HTerrainTextureSet.get_src_types_from_type(type)
				
				var src_data = import_data["src"]
				if src_data.has("rgb"):
					source_textures[src_types[0]] = src_data["rgb"]
				if src_data.has("a"):
					source_textures[src_types[1]] = src_data["a"]
			
			_slots_data.append(source_textures)
	
	else:
		var slots_count := _texture_set.get_slots_count()
		
		for type in HTerrainTextureSet.TYPE_COUNT:
			var texture_array := _texture_set.get_texture_array(type)
			
			if texture_array == null or texture_array.resource_path == "":
				continue
			
			if not texture_array.resource_path.ends_with(".packed_texarr"):
				continue
			
			var import_data := _parse_json_file(texture_array.resource_path)
			if import_data.empty() or not import_data.has("layers"):
				continue
			
			var layers_data = import_data["layers"]
			
			for slot_index in len(layers_data):
				var src_data = layers_data[slot_index]
				
				var src_types = HTerrainTextureSet.get_src_types_from_type(type)
				
				while slot_index >= len(_slots_data):
					var slot_data = []
					for i in HTerrainTextureSet.SRC_TYPE_COUNT:
						slot_data.append("")
					_slots_data[slot_index] = slot_data
				
				var slot_data = _slots_data[slot_index]
				
				if src_data.has("rgb"):
					slot_data[src_types[0]] = src_data["rgb"]
				if src_data.has("a"):
					slot_data[src_types[1]] = src_data["a"]

	# TODO If the set doesnt have a file, use terrain path by default?
	if texture_set.resource_path != "":
		var dir = texture_set.resource_path.get_base_dir()
		_import_directory_line_edit.text = dir

	_update_ui_from_data()


func _parse_json_file(fpath: String) -> Dictionary:
	var f := File.new()
	var err := f.open(fpath, File.READ)
	if err != OK:
		_logger.error("Could not load {0}: {1}".format([fpath, Errors.get_message(err)]))
		return {}
	
	var json_text := f.get_as_text()
	var json_result := JSON.parse(json_text)
	if json_result.error != OK:
		_logger.error("Failed to parse {0}: {1}".format([fpath, json_result.error_string]))
		return {}
	
	return json_result.result


func _update_ui_from_data():
	var prev_selected_items = _slots_list.get_selected_items()
	
	_slots_list.clear()
	
	for slot_index in len(_slots_data):
		_slots_list.add_item("Texture {0}".format([slot_index]))
	
	_resolution_spinbox.value = _import_settings.resolution
	_mipmaps_checkbox.pressed = _import_settings.mipmaps
	_filter_checkbox.pressed = _import_settings.filter
	_set_selected_id(_compression_selector, _import_settings.compression)
	_set_selected_id(_import_mode_selector, _import_mode)
	
	if _slots_list.get_item_count() > 0:
		if len(prev_selected_items) > 0:
			var i : int = prev_selected_items[0]
			if i >= _slots_list.get_item_count():
				i = _slots_list.get_item_count() - 1
			_select_slot(i)
		else:
			_select_slot(0)
	
	var max_slots := HTerrainTextureSet.get_max_slots_for_mode(_import_mode)
	_add_slot_button.disabled = len(_slots_data) >= max_slots
	_remove_slot_button.disabled = len(_slots_data) == 0


static func _set_selected_id(ob: OptionButton, id: int):
	for i in ob.get_item_count():
		if ob.get_item_id(i) == id:
			ob.selected = i
			break


func _select_slot(slot_index: int):
	assert(slot_index >= 0)
	assert(slot_index < len(_slots_data))
	var slot = _slots_data[slot_index]
	
	for type in HTerrainTextureSet.SRC_TYPE_COUNT:
		var im_path : String = slot[type]
		_set_ui_slot_texture_from_path(im_path, type)

	_slots_list.select(slot_index)


func _set_ui_slot_texture_from_path(im_path: String, type: int):
	var ed = _texture_editors[type]

	if im_path == "":
		ed.set_texture(null)
		ed.set_texture_tooltip("<empty>")
		return
	
	var im := Image.new()
	var err := im.load(im_path)
	if err != OK:
		_logger.error(str("Unable to load image from ", im_path))
		# TODO Different icon for images that can't load?
		ed.set_texture(null)
		ed.set_texture_tooltip("<empty>")
		return

	var tex := ImageTexture.new()
	tex.create_from_image(im, 0)
	ed.set_texture(tex)
	ed.set_texture_tooltip(im_path)


func _set_source_image(fpath: String, type: int):
	_set_ui_slot_texture_from_path(fpath, type)

	var slot_index : int = _slots_list.get_selected_items()[0]
	#var prev_path = _texture_set.get_source_image_path(slot_index, type)
	
	var slot : Array = _slots_data[slot_index]
	slot[type] = fpath


func _set_import_property(key: String, value):
	var prev_value = _import_settings[key]
	# This is needed, notably because CheckBox emits a signal too when we set it from code...
	if prev_value == value:
		return
		
	_import_settings[key] = value


func _on_texture_load_pressed(type: int):
	_load_texture_type = type
	_load_texture_dialog.popup_centered_ratio()


func _on_LoadTextureDialog_file_selected(fpath: String):
	_set_source_image(fpath, _load_texture_type)
	
	if _load_texture_type == HTerrainTextureSet.SRC_TYPE_ALBEDO:
		_smart_pick_files(fpath)


# Attempts to load source images of other types by looking at how the albedo file was named
func _smart_pick_files(albedo_fpath: String):
	var albedo_words = _smart_pick_file_keywords[HTerrainTextureSet.SRC_TYPE_ALBEDO]
	
	var albedo_fname := albedo_fpath.get_file()
	var albedo_fname_lower = albedo_fname.to_lower()
	var fname_pattern = ""
	
	for albedo_word in albedo_words:
		var i = albedo_fname_lower.find(albedo_word, 0)
		if i != -1:
			fname_pattern = albedo_fname.left(i) + "{0}" + albedo_fname.right(i + len(albedo_word))
			break
	
	if fname_pattern == "":
		return
	
	var dirpath := albedo_fpath.get_base_dir()
	var fnames := _get_files_in_directory(dirpath, _logger)
	
	var types := [
		HTerrainTextureSet.SRC_TYPE_BUMP,
		HTerrainTextureSet.SRC_TYPE_NORMAL,
		HTerrainTextureSet.SRC_TYPE_ROUGHNESS
	]
	
	var slot_index : int = _slots_list.get_selected_items()[0]
	
	for type in types:
		var slot = _slots_data[slot_index]
		if slot[type] != "":
			# Already set, don't overwrite unwantedly
			continue
		
		var keywords = _smart_pick_file_keywords[type]
		
		for key in keywords:
			var expected_fname = fname_pattern.format([key])
			
			var found := false
			
			for i in len(fnames):
				var fname : String = fnames[i]
				
				# TODO We should probably ignore extensions?
				if fname.to_lower() == expected_fname.to_lower():
					var fpath = dirpath.plus_file(fname)
					_set_source_image(fpath, type)
					found = true
					break
			
			if found:
				break


static func _get_files_in_directory(dirpath: String, logger) -> Array:
	var dir := Directory.new()
	var err := dir.open(dirpath)
	if err != OK:
		logger.error("Could not open directory {0}: {1}" \
			.format([dirpath, Errors.get_message(err)]))
		return []
	
	err = dir.list_dir_begin(true, true)
	if err != OK:
		logger.error("Could not probe directory {0}: {1}" \
			.format([dirpath, Errors.get_message(err)]))
		return []
	
	var files := []
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir():
			files.append(fname)
		fname = dir.get_next()
	
	return files


func _on_texture_clear_pressed(type: int):
	_set_source_image("", type)


func _on_SlotsList_item_selected(index: int):
	_select_slot(index)


func _on_ImportModeSelector_item_selected(index: int):
	var mode : int = _import_mode_selector.get_item_id(index)
	#_set_import_property("mode", mode)
	_import_mode = mode


func _on_CompressionSelector_item_selected(index: int):
	var compression : int = _compression_selector.get_item_id(index)
	_set_import_property("compression", compression)


func _on_MipmapsCheckbox_toggled(button_pressed: bool):
	_set_import_property("mipmaps", button_pressed)


func _on_ResolutionSpinBox_value_changed(value):
	_set_import_property("resolution", int(value))


func _on_TextureArrayPrefixLineEdit_text_changed(new_text: String):
	_set_import_property("output_prefix", new_text)


func _on_AddSlotButton_pressed():
	var i := len(_slots_data)
	_slots_data.append(["", "", "", ""])
	_update_ui_from_data()
	_select_slot(i)


func _on_RemoveSlotButton_pressed():
	if _slots_list.get_item_count() == 0:
		return
	var selected_item = _slots_list.get_selected_items()[0]
	_delete_confirmation_popup.window_title = "Delete slot {0}".format([selected_item])
	_delete_confirmation_popup.dialog_text = "Delete import slot {0}?".format([selected_item])
	_delete_confirmation_popup.popup_centered()


func _on_delete_confirmation_popup_confirmed():
	var selected_item : int = _slots_list.get_selected_items()[0]
	_slots_data.remove(selected_item)
	_update_ui_from_data()


func _on_FilterCheckBox_toggled(button_pressed: bool):
	_set_import_property("filter", button_pressed)


func _on_CancelButton_pressed():
	hide()


func _on_BrowseImportDirectory_pressed():
	_open_dir_dialog.popup_centered_ratio()


func _on_ImportDirectoryLineEdit_text_changed(new_text: String):
	pass


func _on_OpenDirDialog_dir_selected(dir_path: String):
	_import_directory_line_edit.text = dir_path


func _show_error(message: String):
	_error_popup.dialog_text = message
	_error_popup.popup_centered()


# class ButtonDisabler:
# 	var _button : Button

# 	func _init(b: Button):
# 		_button = b
# 		_button.disabled = true

# 	func _notification(what: int):
# 		if what == NOTIFICATION_PREDELETE:
# 			_button.disabled = false


func _on_ImportButton_pressed():
	if _texture_set == null:
		_show_error("No HTerrainTextureSet selected.")
		return
	
	var import_dir := _import_directory_line_edit.text.strip_edges()

	var prefix := ""
	if _texture_set.resource_path != "":
		prefix = _texture_set.resource_path.get_file().get_basename() + "_"
	
	var files_data_result
	if _import_mode == HTerrainTextureSet.MODE_TEXTURES:
		files_data_result = _generate_packed_textures_files_data(import_dir, prefix)
	else:
		files_data_result = _generate_save_packed_texture_arrays_files_data(import_dir, prefix)
	
	if not files_data_result.success:
		_show_error(files_data_result.get_message())
		return	
	
	var files_data : Array = files_data_result.value
	if len(files_data) == 0:
		_show_error("There are no files to save.\nYou must setup at least one slot of textures.")
		return
	
	var dir := Directory.new()
	for fd in files_data:
		var dir_path : String = fd.path.get_base_dir()
		if not dir.dir_exists(dir_path):
			_show_error("The directory {0} could not be found.".format([dir_path]))
			return
	
	for fd in files_data:
		var json := JSON.print(fd.data, "\t", true)
		if json == "":
			_show_error("A problem occurred while serializing data for {0}".format([fd.path]))
			return
		
		var f := File.new()
		var err := f.open(fd.path, File.WRITE)
		if err != OK:
			_show_error("Could not write file {0}: {1}".format([fd.path]))
			return
		
		f.store_string(json)
		f.close()
	
	if _editor_file_system == null:
		_show_error("EditorFileSystem is not setup, can't trigger import system.")
		return
	
	#                   ______
	#                .-"      "-.
	#               /            \
	#   _          |              |          _
	#  ( \         |,  .-.  .-.  ,|         / )
	#   > "=._     | )(__/  \__)( |     _.=" <
	#  (_/"=._"=._ |/     /\     \| _.="_.="\_)
	#         "=._ (_     ^^     _)"_.="
	#             "=\__|IIIIII|__/="
	#            _.="| \IIIIII/ |"=._
	#  _     _.="_.="\          /"=._"=._     _
	# ( \_.="_.="     `--------`     "=._"=._/ )
	#  > _.="                            "=._ <
	# (_/                                    \_)
	#
	# TODO What I need here is a way to trigger the import of specific files!
	# It exists, but is not exposed, so I have to rely on a VERY fragile and hacky use of scan()...
	# I'm not even sure it works tbh. It's terrible.
	# See https://github.com/godotengine/godot-proposals/issues/1615
	_editor_file_system.scan()
	while _editor_file_system.is_scanning():
		_logger.debug("Waiting for scan to complete...")
		yield(get_tree(), "idle_frame")
		if not is_inside_tree():
			# oops?
			return
	_logger.debug("Scanning complete")
	# Looks like import takes place AFTER scanning, so let's yield some more...
	for fd in len(files_data) * 2:
		_logger.debug("Yielding some more")
		yield(get_tree(), "idle_frame")

	var failed_resource_paths := []
	
	# Using UndoRedo is mandatory for Godot to consider the resource as modified...
	# ...yet if files get deleted, that won't be undoable anyways, but whatever :shrug:
	var ur := _undo_redo
	
	# Check imported textures
	if _import_mode == HTerrainTextureSet.MODE_TEXTURES:
		for fd in files_data:
			var texture = load(fd.path)
			if texture == null:
				failed_resource_paths.append(fd.path)
				continue
			assert(texture is Texture)
			fd["texture"] = texture

	else:
		for fd in files_data:
			var texture_array = load(fd.path)
			if texture_array == null:
				failed_resource_paths.append(fd.path)
			assert(texture_array is TextureArray)
			fd["texture_array"] = texture_array

	if len(failed_resource_paths) > 0:
		var failed_list = PoolStringArray(failed_resource_paths).join("\n")
		_show_error("Some resources failed to load:\n" + failed_list)

	else:
		# All is OK, commit action to modify the texture set with imported textures

		if _import_mode == HTerrainTextureSet.MODE_TEXTURES:
			ur.create_action("HTerrainTextureSet: import textures")
			
			TextureSetEditor.backup_for_undo(_texture_set, ur)
			
			ur.add_do_method(_texture_set, "clear")
			ur.add_do_method(_texture_set, "set_mode", _import_mode)
			
			for i in len(_slots_data):
				ur.add_do_method(_texture_set, "insert_slot", -1)
			for fd in files_data:
				ur.add_do_method(_texture_set, "set_texture", fd.slot_index, fd.type, fd.texture)

		else:
			ur.create_action("HTerrainTextureSet: import textures")
			
			TextureSetEditor.backup_for_undo(_texture_set, ur)
			
			ur.add_do_method(_texture_set, "clear")
			ur.add_do_method(_texture_set, "set_mode", _import_mode)
			
			for fd in files_data:
				ur.add_do_method(_texture_set, "set_texture_array", fd.type, fd.texture_array)

		ur.commit_action()
		
		_logger.debug("Done importing")

		_info_popup.dialog_text = "Importing complete!"
		_info_popup.popup_centered()

		emit_signal("import_finished")


func _generate_packed_textures_files_data(import_dir: String, prefix: String) -> Result:
	var files := []
	
	for type in HTerrainTextureSet.TYPE_COUNT:
		var src_types := HTerrainTextureSet.get_src_types_from_type(type)
		
		for slot_index in len(_slots_data):
			var sources : Array = _slots_data[slot_index]
			
			if sources[src_types[0]] == "":
				if src_types[0] == HTerrainTextureSet.SRC_TYPE_ALBEDO:
					return Result.new(false, 
						"Albedo texture is missing in slot {0}".format([slot_index]))
				continue

			var json_data := {
				"contains_albedo": type == HTerrainTextureSet.TYPE_ALBEDO_BUMP,
				"resolution": _import_settings.resolution,
				"src": {
					"rgb": sources[src_types[0]],
					"a": sources[src_types[1]]
				}
			}
			
			var type_name := HTerrainTextureSet.get_texture_type_name(type)
			var fpath = import_dir.plus_file(
				str(prefix, "slot", slot_index, "_", type_name, ".packed_tex"))
			files.append({
				"slot_index": slot_index,
				"type": type,
				"path": fpath,
				"data": json_data
			})
	
	return Result.new(true).with_value(files)


func _generate_save_packed_texture_arrays_files_data(import_dir: String, prefix: String) -> Result:
	var files := []
	
	for type in HTerrainTextureSet.TYPE_COUNT:
		var src_types := HTerrainTextureSet.get_src_types_from_type(type)
		
		var json_data := {
			"contains_albedo": type == HTerrainTextureSet.TYPE_ALBEDO_BUMP,
			"resolution": _import_settings.resolution,
		}
		var layers_data := []
		
		for slot_index in len(_slots_data):
			var sources : Array = _slots_data[slot_index]
			
			if sources[src_types[0]] == "":
				if src_types[0] == HTerrainTextureSet.SRC_TYPE_ALBEDO:
					return Result.new(false, 
						"Albedo texture is missing in slot {0}".format([slot_index]))
				continue
			
			layers_data.append({
				"rgb": sources[src_types[0]],
				"a": sources[src_types[1]]
			})
		
		json_data["layers"] = layers_data
		
		var type_name := HTerrainTextureSet.get_texture_type_name(type)
		var fpath := import_dir.plus_file(str(prefix, type_name, ".packed_texarr"))
		
		files.append({
			"type": type,
			"path": fpath,
			"data": json_data
		})
	
	return Result.new(true).with_value(files)
