#!/usr/bin/env python3
"""Apply Qingzhou's bounded dispatcher counter to a pinned, disposable xray-core copy."""
import pathlib
import shutil
import sys

root = pathlib.Path(sys.argv[1])
source = pathlib.Path(__file__).resolve().parent / "patches" / "xray-core"
for name in ("qingzhou_domain_traffic.go", "qingzhou_domain_traffic_test.go"):
    shutil.copy2(source / name, root / "app" / "dispatcher" / name)
path = root / "app" / "dispatcher" / "default.go"
text = path.read_text()
hook = '\tctx = qingzhouTrackDomain(ctx, link, inTag, handler.Tag(), destination.Address.String())\n'
anchor = '\thandler.Dispatch(ctx, link)\n'
if hook not in text:
    if text.count(anchor) != 1:
        raise SystemExit("Dispatcher changed upstream; review the domain traffic hook before building")
    path.write_text(text.replace(anchor, hook + anchor))
