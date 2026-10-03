extends RefCounted
## Tests for MetaProfile (PR 1 of #10).

func test_defaults_empty() -> String:
	var p := MetaProfile.new()
	if not p.patents.is_empty() or not p.unlocks.is_empty() or not p.contracts.is_empty():
		return "lists should start empty"
	if p.bankruptcies_filed != 0:
		return "bankruptcies_filed should start 0"
	return "ok"

func test_add_and_has_helpers() -> String:
	var p := MetaProfile.new()
	if not p.add_patent("hull_a") or not p.add_unlock("u1") or not p.add_contract("c1"):
		return "first add should return true"
	if p.add_patent("hull_a"):
		return "duplicate add should return false"
	if p.add_patent(""):
		return "empty id should be rejected"
	if p.patents.size() != 1:
		return "duplicate/empty must not grow list"
	if not p.has_patent("hull_a") or not p.has_unlock("u1") or not p.has_contract("c1"):
		return "has_* should find added ids"
	if p.has_patent("nope") or p.has_unlock("hull_a") or p.has_contract("u1"):
		return "has_* false positives (lists must be independent)"
	return "ok"

func test_roundtrip() -> String:
	var p := MetaProfile.new()
	p.add_patent("a")
	p.add_patent("b")
	p.add_unlock("u")
	p.add_contract("c")
	p.bankruptcies_filed = 3
	var q := MetaProfile.from_dict(p.to_dict())
	if q.patents != p.patents or q.unlocks != p.unlocks or q.contracts != p.contracts:
		return "lists did not roundtrip"
	if q.bankruptcies_filed != 3:
		return "count did not roundtrip"
	if q.to_dict() != p.to_dict():
		return "to_dict not stable across roundtrip"
	return "ok"

func test_to_dict_is_a_copy() -> String:
	var p := MetaProfile.new()
	p.add_patent("a")
	var d := p.to_dict()
	d["patents"].append("zzz")
	if p.patents.size() != 1:
		return "to_dict leaked internal array"
	return "ok"

func test_from_dict_sanitises() -> String:
	var q := MetaProfile.from_dict({
		"patents": "not-an-array",
		"unlocks": ["a", "a", "b", 5, null, "", "b"],
		"contracts": {"x": 1},
		"bankruptcies_filed": -4,
	})
	if not q.patents.is_empty():
		return "non-array patents should become empty"
	if q.unlocks != ["a", "b"]:
		return "unlocks should dedupe and drop non-strings, got %s" % str(q.unlocks)
	if not q.contracts.is_empty():
		return "dict contracts should become empty"
	if q.bankruptcies_filed != 0:
		return "negative count should clamp to 0"
	return "ok"

func test_from_dict_bad_count_types_and_missing_keys() -> String:
	if MetaProfile.from_dict({"bankruptcies_filed": "7"}).bankruptcies_filed != 0:
		return "string count should become 0"
	if MetaProfile.from_dict({"bankruptcies_filed": 2.0}).bankruptcies_filed != 2:
		return "float count should coerce to int"
	var q := MetaProfile.from_dict({})
	if q.bankruptcies_filed != 0 or not q.patents.is_empty():
		return "empty dict should yield default profile"
	return "ok"
