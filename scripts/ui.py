#!/usr/bin/env python3
"""Tiny adb UI driver: dump / tap by text / screenshot."""
import re, subprocess, sys, os, time

ADB = os.path.expanduser("~/android-vm/sdk/platform-tools/adb")

def sh(*a, **kw):
    return subprocess.run([ADB, *a], capture_output=True, text=True, timeout=120, **kw)

def dump():
    sh("shell", "uiautomator", "dump", "/sdcard/ui.xml")
    xml = sh("shell", "cat", "/sdcard/ui.xml").stdout
    out = []
    for m in re.finditer(r'<node[^>]*>', xml):
        n = m.group(0)
        t = re.search(r'text="([^"]*)"', n)
        d = re.search(r'content-desc="([^"]*)"', n)
        b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', n)
        if not b:
            continue
        x1, y1, x2, y2 = map(int, b.groups())
        label = (t.group(1) if t else "") or (d.group(1) if d else "")
        if label.strip():
            out.append((label, (x1 + x2) // 2, (y1 + y2) // 2, x1, y1, x2, y2))
    return out

def show():
    for label, cx, cy, *_ in dump():
        print(f"{label!r:60s} center=({cx},{cy})")

def tap(label, exact=False):
    items = dump()
    for l, cx, cy, *_ in items:
        if (l == label) if exact else (label.lower() in l.lower()):
            sh("shell", "input", "tap", str(cx), str(cy))
            time.sleep(1.5)
            print(f"tapped {l!r} at ({cx},{cy})")
            return True
    print(f"NOT FOUND: {label!r}; on screen:", [i[0] for i in items][:25])
    return False

def shot(path):
    with open(path, "wb") as f:
        f.write(sh("exec-out", "screencap", "-p").stdout if False else subprocess.run(
            [ADB, "exec-out", "screencap", "-p"], capture_output=True, timeout=120).stdout)
    print("saved", path)

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "show"
    if cmd == "show":
        show()
    elif cmd == "tap":
        tap(" ".join(sys.argv[2:]))
    elif cmd == "shot":
        shot(sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser("~/android-vm/shot.png"))
    elif cmd == "key":
        sh("shell", "input", "keyevent", sys.argv[2])
