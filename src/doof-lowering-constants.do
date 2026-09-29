// Shared lowered type names and array helpers.
export readonly BYTE_ARRAY_CLASS = "__doof_array_byte"
export readonly BYTE_ARRAY_DESTRUCTOR = "__doof_array_byte.destroy"
export readonly CHAR_ARRAY_CLASS = "__doof_array_char"
export readonly CHAR_ARRAY_DESTRUCTOR = "__doof_array_char.destroy"
export readonly STRING_CLASS = "__doof_string"
export readonly RESULT_SUCCESS_CLASS = "__doof_result_success"
export readonly RESULT_FAILURE_CLASS = "__doof_result_failure"
export readonly ARRAY_CLASS_PREFIX = "__doof_array_type"
export readonly STRING_BOOL_MAP_CLASS = "__doof_map_string_bool"

export function arrayClassName(elementType: string): string {
  return ARRAY_CLASS_PREFIX + "_" + elementType
}

export function arrayElementFromClassName(className: string): string {
  prefix := ARRAY_CLASS_PREFIX + "_"
  if !className.startsWith(prefix) { return "" }
  return className.substring(prefix.length, className.length)
}

export function isArrayClass(typeName: string): bool => typeName == BYTE_ARRAY_CLASS || typeName == CHAR_ARRAY_CLASS || typeName.startsWith(ARRAY_CLASS_PREFIX + "_")
