# Context map

| File | Format and contents |
| --- | --- |
| [scope.json](scope.json) | Object with `codebases[]`: repository directories, pinned commits and `in_scope_files`; repository [scope rule](scope-rules/limitorder-org__v1-core.md). |
| [entries.json](entries.json) | Document array with `id`, workspace-relative `path`, `dimensions`, `description`, `written_for_engagement`, content `level`, `visibility`, and `sources[]` (`path`, `location`). Dimensions are `tf`, `scope`, `known`, `severity`, or empty for background. |
| [statements.json](statements.json) | Object with `version` and `files[]`; each file has `path` and `statements[]` with `id`, `lines`, `quote`, and per-dimension `level` and `fails`. Validity is keyed `true_finding` here. Statement levels differ from inventory content levels. |
| [severity-set.json](severity-set.json) | Ordered array of severity objects with `identifier`, `display_name` and the full `body_markdown`. |

Run these examples from the workspace root. Statement quotes are preserved in full.

```sh
# Find documents by dimension; change 'known' to 'tf', 'scope', or 'severity'.
python -c 'import json; [print(e["path"], "—", e["description"]) for e in json.load(open("context/entries.json")) if "known" in e["dimensions"]]'

# Read every statement for one dimension; validity uses 'true_finding'.
python -c 'import json; [print(json.dumps({"path": f["path"], **s}, ensure_ascii=False, indent=2)) for f in json.load(open("context/statements.json"))["files"] for s in f["statements"] if "known" in s["dimensions"]]'

# Retrieve a statement by ID, including its source and full quote.
python -c 'import json; [print(json.dumps({"path": f["path"], **s}, ensure_ascii=False, indent=2)) for f in json.load(open("context/statements.json"))["files"] for s in f["statements"] if s["id"] == "S68"]'
```

[Evidence by section](evidence-map.md) · [Workspace starting point](../README.md)
