extends RefCounted

func test_deliberate_assertion_failure() -> String:
	return "deliberate assertion failure to prove runner fails"

func test_deliberate_crash() -> String:
	var x = null
	x.nonexistent_method()
	return ""
