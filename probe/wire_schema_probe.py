import json
from collections import Counter
from pathlib import Path

ROOT = Path(r"D:\app\kimi-code-data\sessions")

files = list(ROOT.glob("**/wire.jsonl"))
root_types = Counter()
event_types = Counter()
part_types = Counter()
arg_types = Counter()
arg_keys = Counter()
tool_events = Counter()
result_types = Counter()
result_keys = Counter()
result_output_types = Counter()
result_content_types = Counter()
parse_errors = 0
line_count = 0

for path in files:
    for line in path.read_text(encoding="utf-8").splitlines():
        line_count += 1
        try:
            item = json.loads(line)
        except json.JSONDecodeError:
            parse_errors += 1
            continue

        root_types[str(item.get("type"))] += 1
        event = item.get("event")
        if not isinstance(event, dict):
            continue

        event_type = str(event.get("type"))
        event_types[event_type] += 1

        part = event.get("part")
        if isinstance(part, dict):
            part_types[str(part.get("type"))] += 1

        if "args" in event:
            args = event.get("args")
            arg_types[type(args).__name__] += 1
            if isinstance(args, dict):
                arg_keys[tuple(sorted(args.keys()))] += 1

        if "result" in event:
            result = event.get("result")
            result_types[type(result).__name__] += 1
            if isinstance(result, dict):
                result_keys[tuple(sorted(result.keys()))] += 1
                if "output" in result:
                    result_output_types[type(result.get("output")).__name__] += 1
                if "content" in result:
                    result_content_types[type(result.get("content")).__name__] += 1

        if event_type.startswith("tool."):
            tool_name = event.get("name") or event.get("toolName") or "<none>"
            tool_events[(event_type, str(tool_name))] += 1

print(f"files={len(files)} lines={line_count} parse_errors={parse_errors}")
print("root_types", root_types.most_common())
print("event_types", event_types.most_common())
print("part_types", part_types.most_common())
print("args_types", arg_types.most_common())
print("args_keysets")
for keys, count in arg_keys.most_common():
    print(count, list(keys))
print("result_types", result_types.most_common())
print("result_keysets")
for keys, count in result_keys.most_common():
    print(count, list(keys))
print("result_output_types", result_output_types.most_common())
print("result_content_types", result_content_types.most_common())
print("tool_events")
for key, count in tool_events.most_common():
    print(count, key)
