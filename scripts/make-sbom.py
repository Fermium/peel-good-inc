#!/usr/bin/env python3
"""Writes a CycloneDX 1.5 SBOM of the Swift package dependencies.

Reads Package.resolved and each checkout's LICENSE file in .build/checkouts
(run `swift package resolve` first). Usage: make-sbom.py <version> <out.json>
"""
import json, os, re, sys, uuid, datetime

version, out = sys.argv[1], sys.argv[2]
pins = json.load(open("Package.resolved"))["pins"]

def spdx(identity):
    folder = os.path.join(".build", "checkouts", identity)
    names = [n for n in os.listdir(folder) if re.match(r"(?i)(license|licence|copying)", n)] if os.path.isdir(folder) else []
    found = []
    for name in sorted(names):
        text = open(os.path.join(folder, name), errors="ignore").read()
        if "Apache License" in text and "Version 2.0" in text: found.append("Apache-2.0")
        elif "MIT License" in text or "Permission is hereby granted, free of charge" in text: found.append("MIT")
        elif "Redistribution and use in source and binary forms" in text:
            found.append("BSD-3-Clause" if "Neither the name" in text else "BSD-2-Clause")
    return sorted(set(found)) or ["NOASSERTION"]

def component(pin):
    url = pin["location"].removesuffix(".git")
    path = re.sub(r"^https?://", "", url)
    v = pin["state"].get("version") or pin["state"].get("revision", "")[:12]
    return {
        "type": "library",
        "bom-ref": f"pkg:swift/{path}@{v}",
        "name": pin["identity"],
        "version": v,
        "purl": f"pkg:swift/{path}@{v}",
        "licenses": [{"license": {"id": l}} if l != "NOASSERTION" else {"expression": "NOASSERTION"} for l in spdx(pin["identity"])],
        "externalReferences": [{"type": "vcs", "url": url}],
    }

bom = {
    "bomFormat": "CycloneDX",
    "specVersion": "1.5",
    "serialNumber": f"urn:uuid:{uuid.uuid4()}",
    "version": 1,
    "metadata": {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat(),
        "component": {
            "type": "application", "bom-ref": "peel-good-inc", "name": "Peel Good Inc.", "version": version,
            "licenses": [{"license": {"id": "MIT"}}], "supplier": {"name": "FERMIUM LTD"},
            "externalReferences": [{"type": "vcs", "url": "https://github.com/Fermium/peel-good-inc"}],
        },
    },
    "components": [component(p) for p in sorted(pins, key=lambda p: p["identity"])],
}
os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
json.dump(bom, open(out, "w"), indent=2)
print(f"SBOM: {len(bom['components'])} components → {out}")
