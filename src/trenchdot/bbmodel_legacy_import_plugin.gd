@tool
class_name TrenchDotLegacyBBModelImportPlugin extends TrenchDotBBModelImportPlugin
## Stands in for the importer that .bbmodel.import files of older projects name, see [TrenchDotLegacyImportPlugin].

func _get_importer_name() -> String:
	return TrenchDotLegacy.BBMODEL_IMPORTER

func _get_priority() -> float:
	return 0.5
