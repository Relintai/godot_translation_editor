tool
extends Panel

const CsvLoader = preload("./csv_loader.gd")
const PoLoader = preload("./po_loader.gd")
const Locales = preload("./locales.gd")
const StringEditionDialog = preload("./string_edition_dialog.gd")
const LanguageSelectionDialog = preload("./language_selection_dialog.gd")
const ExtractorDialog = preload("./extractor_dialog.gd")
const Util = preload("./util/util.gd")
const Logger = preload("./util/logger.gd")

const StringEditionDialogScene = preload("./string_edition_dialog.tscn")
const LanguageSelectionDialogScene = preload("./language_selection_dialog.tscn")
const ExtractorDialogScene = preload("./extractor_dialog.tscn")

const MENU_FILE_OPEN = 0
const MENU_FILE_SAVE = 1
const MENU_FILE_SAVE_AS_CSV = 2
const MENU_FILE_SAVE_AS_PO = 3
const MENU_FILE_ADD_LANGUAGE = 4
const MENU_FILE_REMOVE_LANGUAGE = 5
const MENU_FILE_EXTRACT = 6

const FORMAT_CSV = 0
const FORMAT_GETTEXT = 1

const STATUS_UNTRANSLATED = 0
const STATUS_PARTIALLY_TRANSLATED = 1
const STATUS_TRANSLATED = 2

onready var _file_menu : MenuButton = $VBoxContainer/MenuBar/FileMenu
onready var _edit_menu : MenuButton = $VBoxContainer/MenuBar/EditMenu
onready var _search_edit : LineEdit = $VBoxContainer/Main/LeftPane/Search/Search
onready var _clear_search_button : Button = $VBoxContainer/Main/LeftPane/Search/ClearSearch
onready var _string_list : ItemList = $VBoxContainer/Main/LeftPane/StringList
onready var _translation_tab_container : TabContainer = \
	$VBoxContainer/Main/RightPane/VSplitContainer/TranslationTabContainer
onready var _notes_edit : TextEdit = \
	$VBoxContainer/Main/RightPane/VSplitContainer/VBoxContainer/NotesEdit
onready var _status_label : Label = $VBoxContainer/StatusBar/Label
onready var _show_untranslated_checkbox : CheckBox = $VBoxContainer/MenuBar/ShowUntranslated

var _string_edit_dialog : StringEditionDialog = null
var _language_selection_dialog : LanguageSelectionDialog = null
var _remove_language_confirmation_dialog : ConfirmationDialog = null
var _remove_string_confirmation_dialog : ConfirmationDialog = null
var _extractor_dialog : ExtractorDialog = null
var _open_dialog : FileDialog = null
var _save_file_dialog : FileDialog = null
var _save_folder_dialog : FileDialog = null
# This is set when integrated as a Godot plugin
var _base_control : Control = null
# language => TextEdit
var _translation_edits := {}
var _dialogs_to_free_on_exit := []
var _logger = Logger.get_for(self)
var _string_status_icons := [null, null, null]

# {string_id => {comments: string, translations: {language_name => text}}}
var _data := {}
# string[]
var _languages := []
var _current_path := ""
var _current_format := FORMAT_CSV
var _modified_languages := {}


func _ready():
	# I don't want any of this to run in the edited scene (because `tool`)...
	if Util.is_in_edited_scene(self):
		return
	
	# TODO these icons are blank when running as a game
	_string_status_icons[STATUS_UNTRANSLATED] = get_theme_icon("StatusError", "EditorIcons")
	_string_status_icons[STATUS_PARTIALLY_TRANSLATED] = get_theme_icon("StatusWarning", "EditorIcons")
	_string_status_icons[STATUS_TRANSLATED] = get_theme_icon("StatusSuccess", "EditorIcons")
	
	_file_menu.get_popup().add_item("Open...", MENU_FILE_OPEN)
	_file_menu.get_popup().add_item("Save", MENU_FILE_SAVE)
	_file_menu.get_popup().add_item("Save as CSV...", MENU_FILE_SAVE_AS_CSV)
	_file_menu.get_popup().add_item("Save as PO...", MENU_FILE_SAVE_AS_PO)
	_file_menu.get_popup().add_separator()
	_file_menu.get_popup().add_item("Add language...", MENU_FILE_ADD_LANGUAGE)
	_file_menu.get_popup().add_item("Remove language", MENU_FILE_REMOVE_LANGUAGE)
	_file_menu.get_popup().add_separator()
	_file_menu.get_popup().add_item("Extractor", MENU_FILE_EXTRACT)
	_file_menu.get_popup().set_item_disabled(
		_file_menu.get_popup().get_item_index(MENU_FILE_REMOVE_LANGUAGE), true)
	_file_menu.get_popup().connect("id_pressed", self, "_on_FileMenu_id_pressed")
	
	_edit_menu.get_popup().connect("id_pressed", self, "_on_EditMenu_id_pressed")
	
	# In the editor the parent is still busy setting up children...
	call_deferred("_setup_dialogs")
	
	_update_status_label()


func _setup_dialogs():
	# If this fails, something wrong is happening with parenting of the main view
	assert(_open_dialog == null)
	
	_open_dialog = FileDialog.new()
	_open_dialog.window_title = "Open translations"
	_open_dialog.add_filter("*.csv ; CSV files")
	_open_dialog.add_filter("*.po ; Gettext files")
	_open_dialog.mode = FileDialog.MODE_OPEN_FILE
	_open_dialog.connect("file_selected", self, "_on_OpenDialog_file_selected")
	_add_dialog(_open_dialog)

	_save_file_dialog = FileDialog.new()
	_save_file_dialog.window_title = "Save translations as CSV"
	_save_file_dialog.add_filter("*.csv ; CSV files")
	_save_file_dialog.mode = FileDialog.MODE_SAVE_FILE
	_save_file_dialog.connect("file_selected", self, "_on_SaveFileDialog_file_selected")
	_add_dialog(_save_file_dialog)

	_save_folder_dialog = FileDialog.new()
	_save_folder_dialog.window_title = "Save translations as gettext .po files"
	_save_folder_dialog.mode = FileDialog.MODE_OPEN_DIR
	_save_folder_dialog.connect("dir_selected", self, "_on_SaveFolderDialog_dir_selected")
	_add_dialog(_save_folder_dialog)
	
	_string_edit_dialog = StringEditionDialogScene.instance()
	_string_edit_dialog.set_validator(funcref(self, "_validate_new_string_id"))
	_string_edit_dialog.connect("submitted", self, "_on_StringEditionDialog_submitted")
	_add_dialog(_string_edit_dialog)
	
	_language_selection_dialog = LanguageSelectionDialogScene.instance()
	_language_selection_dialog.connect(
		"language_selected", self, "_on_LanguageSelectionDialog_language_selected")
	_add_dialog(_language_selection_dialog)
	
	_remove_language_confirmation_dialog = ConfirmationDialog.new()
	_remove_language_confirmation_dialog.dialog_text = \
		"Do you really want to remove this language? (There is no undo!)"
	_remove_language_confirmation_dialog.connect(
		"confirmed", self, "_on_RemoveLanguageConfirmationDialog_confirmed")
	_add_dialog(_remove_language_confirmation_dialog)
	
	_extractor_dialog = ExtractorDialogScene.instance()
	_extractor_dialog.set_registered_string_filter(funcref(self, "_is_string_registered"))
	_extractor_dialog.connect("import_selected", self, "_on_ExtractorDialog_import_selected")
	_add_dialog(_extractor_dialog)
	
	_remove_string_confirmation_dialog = ConfirmationDialog.new()
	_remove_string_confirmation_dialog.dialog_text = \
		"Do you really want to remove this string and all its translations? (There is no undo)"
	_remove_string_confirmation_dialog.connect(
		"confirmed", self, "_on_RemoveStringConfirmationDialog_confirmed")
	_add_dialog(_remove_string_confirmation_dialog)


func _add_dialog(dialog: Control):
	if _base_control != null:
		_base_control.add_child(dialog)
		_dialogs_to_free_on_exit.append(dialog)
	else:
		add_child(dialog)


func _exit_tree():
	# Free dialogs because in the editor they might not be child of the main view...
	# Also this code runs in the edited scene view as a `tool` side-effect.
	for dialog in _dialogs_to_free_on_exit:
		dialog.queue_free()
	_dialogs_to_free_on_exit.clear()


func configure_for_godot_integration(base_control: Control):
	# You have to call this before adding to the tree
	assert(not is_inside_tree())
	_base_control = base_control
	# Make underlying panel transparent because otherwise it looks bad in the editor
	# TODO Would be better to not draw the panel background conditionally
	self_modulate = Color(0, 0, 0, 0)


func _on_FileMenu_id_pressed(id: int):
	match id:
		MENU_FILE_OPEN:
			_open()
		
		MENU_FILE_SAVE:
			_save()
		
		MENU_FILE_SAVE_AS_CSV:
			_save_file_dialog.popup_centered_ratio()

		MENU_FILE_SAVE_AS_PO:
			_save_folder_dialog.popup_centered_ratio()
		
		MENU_FILE_ADD_LANGUAGE:
			_language_selection_dialog.configure(_languages)
			_language_selection_dialog.popup_centered_ratio()
			
		MENU_FILE_REMOVE_LANGUAGE:
			var language := _get_current_language()
			_remove_language_confirmation_dialog.window_title = \
				str("Remove language `", language, "`")
			_remove_language_confirmation_dialog.popup_centered_minsize()
		
		MENU_FILE_EXTRACT:
			_extractor_dialog.popup_centered_minsize()


func _on_EditMenu_id_pressed(id: int):
	pass


func _on_OpenDialog_file_selected(filepath: String):
	_load_file(filepath)


func _on_SaveFileDialog_file_selected(filepath: String):
	_save_file(filepath, FORMAT_CSV)


func _on_SaveFolderDialog_dir_selected(filepath: String):
	_save_file(filepath, FORMAT_GETTEXT)


func _on_OpenButton_pressed():
	_open()


func _on_SaveButton_pressed():
	_save()


func _on_LanguageSelectionDialog_language_selected(language: String):
	_add_language(language)


func _open():
	_open_dialog.popup_centered_ratio()


func _save():
	if _current_path == "":
		# Have to default to CSV for now...
		_save_file_dialog.popup_centered_ratio()
	else:
		_save_file(_current_path, _current_format)


func _load_file(filepath: String):
	var ext := filepath.get_extension()
	
	if ext == "po":
		var valid_locales := Locales.get_all_locale_ids()
		_current_path = filepath.get_base_dir()
		_data = PoLoader.load_po_translation(_current_path, valid_locales, Logger.get_for(PoLoader))
		_current_format = FORMAT_GETTEXT
		
	elif ext == "csv":
		_data = CsvLoader.load_csv_translation(filepath, Logger.get_for(CsvLoader))
		_current_path = filepath
		_current_format = FORMAT_CSV
		
	else:
		_logger.error("Unknown file format, cannot load {0}".format([filepath]))
		return
	
	_languages.clear()
	for strid in _data:
		var s : Dictionary = _data[strid]
		for language in s.translations:
			if _languages.find(language) == -1:
				_languages.append(language)
	
	_translation_edits.clear()
	
	for i in _translation_tab_container.get_child_count():
		var child = _translation_tab_container.get_child(i)
		if child is TextEdit:
			child.queue_free()
	
	for language in _languages:
		_create_translation_edit(language)
	
	_refresh_list()
	_modified_languages.clear()
	_update_status_label()


func _update_status_label():
	if _current_path == "":
		_status_label.text = "No file loaded"
	elif _current_format == FORMAT_CSV:
		_status_label.text = _current_path
	elif _current_format == FORMAT_GETTEXT:
		_status_label.text = str(_current_path, " (Gettext translations folder)")


func _create_translation_edit(language: String):
	assert(not _translation_edits.has(language)) # boom
	var edit := TextEdit.new()
	edit.hide()
	var tab_index := _translation_tab_container.get_tab_count()
	_translation_tab_container.add_child(edit)
	_translation_tab_container.set_tab_title(tab_index, language)

	var strid := _get_selected_string_id()
	if strid != "":
		var s = _data[strid]
		if s.translations.has(language):
			edit.text = s.translations[language]
		var status := _get_string_status_for_language(strid, language)
		var icon = _string_status_icons[status]
		_translation_tab_container.set_tab_icon(tab_index, icon)

	_translation_edits[language] = edit
	edit.connect("text_changed", self, "_on_TranslationEdit_text_changed", [language])


func _get_selected_string_id() -> String:
	var selected = _string_list.get_selected_items()
	if len(selected) == 0:
		return ""
	return _string_list.get_item_text(selected[0])


func _get_language_tab_index(language: String) -> int:
	var page = _translation_edits[language]
	for i in _translation_tab_container.get_child_count():
		if _translation_tab_container.get_child(i) == page:
			return i
	return -1


func _on_TranslationEdit_text_changed(language: String):
	var edit : TextEdit = _translation_edits[language]
	var selected_strids := _string_list.get_selected_items()
	# TODO Don't show the editor if no strings are selected
	if len(selected_strids) != 1:
		return

	#assert(len(selected_strids) == 1)
	var list_index : int = selected_strids[0]
	var strid := _string_list.get_item_text(list_index)
	var prev_text : String

	var s : Dictionary = _data[strid]

	if s.translations.has(language):
		prev_text = s.translations[language]

	if prev_text != edit.text:
		s.translations[language] = edit.text
		_set_language_modified(language)
		
		# Update status icon
		var status := _get_string_status(strid)
		_string_list.set_item_icon(list_index, _string_status_icons[status])
		
		var tab_index := _get_language_tab_index(language)
		var tab_status := _get_string_status_for_language(strid, language)
		_translation_tab_container.set_tab_icon(tab_index, _string_status_icons[tab_status])


func _on_NotesEdit_text_changed():
	var selected_strids := _string_list.get_selected_items()
	# TODO Don't show the editor if no strings are selected
	if len(selected_strids) != 1:
		return
	#assert(len(selected_strids) == 1)
	var strid := _string_list.get_item_text(selected_strids[0])
	var s : Dictionary = _data[strid]
	if s.comments != _notes_edit.text:
		s.comments = _notes_edit.text
		for language in _languages:
			_set_language_modified(language)


func _set_language_modified(language: String):
	if _modified_languages.has(language):
		return
	_modified_languages[language] = true
	_set_language_tab_title(language, str(language, "*"))


func _set_language_unmodified(language: String):
	if not _modified_languages.has(language):
		return
	_modified_languages.erase(language)
	_set_language_tab_title(language, language)


func _set_language_tab_title(language: String, title: String):
	var tab_index := _get_language_tab_index(language)
	assert(tab_index != -1)
	_translation_tab_container.set_tab_title(tab_index, title)
	# TODO There seem to be a Godot bug, tab titles don't update unless you click on them Oo
	# See https://github.com/godotengine/godot/issues/23696
	_translation_tab_container.update()


func _get_current_language() -> String:
	var page = _translation_tab_container.get_current_tab_control()
	for language in _translation_edits:
		if _translation_edits[language] == page:
			return language
	# Something bad happened
	assert(false)
	return ""


func _save_file(path: String, format: int):
	var saved_languages := []
	
	if format == FORMAT_GETTEXT:
		var languages_to_save : Array
		if _current_format != FORMAT_GETTEXT:
			languages_to_save = _languages
		else:
			languages_to_save = _modified_languages.keys()
		saved_languages = PoLoader.save_po_translations(
			path, _data, languages_to_save, Logger.get_for(PoLoader))
		
	elif format == FORMAT_CSV:
		saved_languages = CsvLoader.save_csv_translation(path, _data, Logger.get_for(CsvLoader))
		
	else:
		_logger.error("Unknown file format, cannot save {0}".format([path]))

	for language in saved_languages:
		_set_language_unmodified(language)
	
	_current_format = format
	_current_path = path
	_update_status_label()


func _refresh_list():
	var prev_selection := _string_list.get_selected_items()
	var prev_selected_strid := ""
	if len(prev_selection) > 0:
		prev_selected_strid = _string_list.get_item_text(prev_selection[0])
	
	var search_text := _search_edit.text.strip_edges()
	var show_untranslated := _show_untranslated_checkbox.pressed
	
	var sorted_strids := []
	for strid in _data.keys():
		if show_untranslated and _get_string_status(strid) == STATUS_TRANSLATED:
			continue
		if search_text != "" and strid.find(search_text) == -1:
			continue
		sorted_strids.append(strid)
	
	sorted_strids.sort()
	
	_string_list.clear()
	for strid in sorted_strids:
		var i := _string_list.get_item_count()
		_string_list.add_item(strid)
		var status := _get_string_status(strid)
		var icon = _string_status_icons[status]
		_string_list.set_item_icon(i, icon)
	
	# Preserve selection
	if prev_selected_strid != "":
		for i in _string_list.get_item_count():
			if _string_list.get_item_text(i) == prev_selected_strid:
				_string_list.select(i)
				# Normally not necessary, unless the list changed a lot
				_string_list.ensure_current_is_visible()
				break


func _get_string_status_for_language(strid: String, language: String) -> int:
	if len(_languages) == 0:
		return STATUS_UNTRANSLATED
	var s : Dictionary = _data[strid]
	if not s.translations.has(language):
		return STATUS_UNTRANSLATED
	var text : String = s.translations[language].strip_edges()
	if text != "":
		return STATUS_TRANSLATED
	return STATUS_UNTRANSLATED


func _get_string_status(strid: String) -> int:
	if len(_languages) == 0:
		return STATUS_UNTRANSLATED
	var s : Dictionary = _data[strid]
	var translated_count := 0
	for language in s.translations:
		var text : String = s.translations[language].strip_edges()
		if text != "":
			translated_count += 1
	if translated_count == len(_languages):
		return STATUS_TRANSLATED
	if translated_count <= 1:
		return STATUS_UNTRANSLATED
	return STATUS_PARTIALLY_TRANSLATED


func _on_StringList_item_selected(index: int):
	var str_id := _string_list.get_item_text(index)
	var s : Dictionary = _data[str_id]
	for language in _languages:
		var e : TextEdit = _translation_edits[language]
		#e.show()
		if s.translations.has(language):
			e.text = s.translations[language]
		else:
			e.text = ""
		var status = _get_string_status_for_language(str_id, language)
		var icon = _string_status_icons[status]
		var tab_index = _get_language_tab_index(language)
		_translation_tab_container.set_tab_icon(tab_index, icon)
	_notes_edit.text = s.comments


func _on_AddButton_pressed():
	_string_edit_dialog.set_replaced_str_id("")
	_string_edit_dialog.popup_centered()


func _on_RemoveButton_pressed():
	var selected_items = _string_list.get_selected_items()
	if len(selected_items) == 0:
		return
	var str_id := _string_list.get_item_text(selected_items[0])
	_remove_string_confirmation_dialog.window_title = str("Remove `", str_id, "`")
	_remove_string_confirmation_dialog.popup_centered_minsize()


func _on_RemoveStringConfirmationDialog_confirmed():
	var selected_items := _string_list.get_selected_items()
	if len(selected_items) == 0:
		_logger.error("No selected string??")
		return
	var strid := _string_list.get_item_text(selected_items[0])
	_string_list.remove_item(selected_items[0])
	_data.erase(strid)
	for language in _languages:
		_set_language_modified(language)


func _on_RenameButton_pressed():
	var selected_items := _string_list.get_selected_items()
	if len(selected_items) == 0:
		return
	var str_id := _string_list.get_item_text(selected_items[0])
	_string_edit_dialog.set_replaced_str_id(str_id)
	_string_edit_dialog.popup_centered()


func _on_StringEditionDialog_submitted(str_id: String, prev_str_id: String):
	if prev_str_id == "":
		_add_new_string(str_id)
	else:
		_rename_string(prev_str_id, str_id)


func _validate_new_string_id(str_id: String):
	if _data.has(str_id):
		return "Already existing"
	if str_id.strip_edges() != str_id:
		return "Must not start or end with spaces"
	for k in _data:
		if k.nocasecmp_to(str_id) == 0:
			return "Already existing with different case"
	return true


func _add_new_string(strid: String):
	_logger.debug(str("Adding new string ", strid))
	assert(not _data.has(strid))
	var s := {
		"translations": {},
		"comments": ""
	}
	_data[strid] = s

	for language in _languages:
		_set_language_modified(language)
		
	# Update UI
	_refresh_list()


func _add_new_strings(strids: Array):
	if len(strids) == 0:
		return
	
	for strid in strids:
		assert(not _data.has(strid))
		var s := {
			"translations": {},
			"comments": ""
		}
		_data[strid] = s

	for language in _languages:
		_set_language_modified(language)
		
	# Update UI
	_refresh_list()


func _rename_string(old_strid: String, new_strid: String):
	assert(_data.has(old_strid))
	var s : Dictionary = _data[old_strid]
	_data.erase(old_strid)
	_data[new_strid] = s

	for language in _languages:
		_set_language_modified(language)

	# Update UI
	for i in _string_list.get_item_count():
		if _string_list.get_item_text(i) == old_strid:
			_string_list.set_item_text(i, new_strid)
			break


func _add_language(language: String):
	assert(_languages.find(language) == -1)
	
	_create_translation_edit(language)
	_languages.append(language)
	_set_language_modified(language)
	
	var menu_index := _file_menu.get_popup().get_item_index(MENU_FILE_REMOVE_LANGUAGE)
	_file_menu.get_popup().set_item_disabled(menu_index, false)
	
	_logger.debug(str("Added language ", language))
	
	_refresh_list()


func _remove_language(language: String):
	assert(_languages.find(language) != -1)
	
	_set_language_unmodified(language)
	var edit : TextEdit = _translation_edits[language]
	edit.queue_free()
	_translation_edits.erase(language)
	_languages.erase(language)

	if len(_languages) == 0:
		var menu_index = _file_menu.get_popup().get_item_index(MENU_FILE_REMOVE_LANGUAGE)
		_file_menu.get_popup().set_item_disabled(menu_index, true)

	_logger.debug(str("Removed language ", language))
	
	_refresh_list()


func _on_RemoveLanguageConfirmationDialog_confirmed():
	var language := _get_current_language()
	_remove_language(language)


# Used as callback for filtering
func _is_string_registered(text: String) -> bool:
	if _data == null:
		_logger.debug("No data")
		return false
	return _data.has(text)


func _on_ExtractorDialog_import_selected(results: Dictionary):
	var new_strings = []
	for text in results:
		if not _is_string_registered(text):
			new_strings.append(text)
	_add_new_strings(new_strings)


func _on_Search_text_changed(search_text: String):
	_clear_search_button.visible = (search_text != "")
	_refresh_list()


func _on_ClearSearch_pressed():
	_search_edit.text = ""
	# LineEdit does not emit `text_changed` when doing this
	_on_Search_text_changed(_search_edit.text)


func _on_ShowUntranslated_toggled(button_pressed):
	_refresh_list()
