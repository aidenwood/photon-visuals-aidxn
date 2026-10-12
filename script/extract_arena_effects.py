#!/usr/bin/env python3
"""Read shipped preset XML into research metadata; never modify the source app."""
import argparse
import collections
import datetime
import hashlib
import json
import pathlib
import xml.etree.ElementTree as ET


def extract(source: pathlib.Path) -> dict:
    presets = []
    for path in sorted(source.rglob("*.xml")):
        document = ET.parse(path).getroot()
        preset = document if document.tag == "Preset" else document.find(".//Preset")
        if preset is None:
            raise ValueError(f"Missing Preset element: {path}")
        parameters = []
        for parameter in preset.iter():
            if not parameter.tag.startswith("Param") or parameter.tag == "Params":
                continue
            item = {"kind": parameter.tag, **parameter.attrib}
            ranges = [child.attrib for child in parameter.findall("ValueRange")]
            if ranges:
                item["ranges"] = ranges
            phases = [
                {"kind": child.tag, **child.attrib}
                for child in parameter.iter() if child.tag.startswith("PhaseSource")
            ]
            if phases:
                item["phaseSources"] = phases
            parameters.append(item)
        version = preset.find("versionInfo")
        presets.append({
            "source": str(path.relative_to(source)),
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "family": path.parent.name,
            "preset": preset.attrib,
            "version": version.attrib if version is not None else None,
            "passes": [child.attrib for child in preset.iter("RenderPass")],
            "parameters": parameters,
        })
    if not presets:
        raise ValueError(f"No preset XML found: {source}")
    families = collections.Counter(item["family"] for item in presets)
    return {
        "schemaVersion": 1,
        "observedAt": datetime.date.today().isoformat(),
        "sourceRoot": str(source),
        "coverage": "Shipped XML presets only; not the entire Effects browser or shader implementation.",
        "presetCount": len(presets), "familyCount": len(families),
        "families": dict(sorted(families.items())), "presets": presets,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=pathlib.Path,
                        default=pathlib.Path("/Applications/Resolume Arena/default/Presets/Video Effects"))
    parser.add_argument("--output", type=pathlib.Path,
                        default=pathlib.Path(__file__).resolve().parent.parent / "docs/reference/arena-effects-presets.json")
    args = parser.parse_args()
    result = extract(args.source)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(f"Extracted {result['presetCount']} presets / {result['familyCount']} folders → {args.output}")
