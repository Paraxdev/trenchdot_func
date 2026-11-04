@tool
class_name TrenchDotLegacyImportPlugin extends TrenchDotTdmImportPlugin
## Stands in for the importer that .gtm.import files of older projects name. Godot leaves a file alone whose importer
## does not exist, so without it those maps would never be imported again.

func _get_importer_name() -> String:
	return TrenchDotLegacy.MAP_IMPORTER

func _get_priority():
	return 0.5
