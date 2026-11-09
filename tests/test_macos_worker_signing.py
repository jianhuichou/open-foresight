"""Exercise entitlement selection; actual codesign is a separate Mac gate."""

import plistlib

from tools import macos_bundle as bundle


def test_companion_and_desktop_receive_separate_entitlements_before_sealing(
    tmp_path, monkeypatch
):
    app = tmp_path / "Example.app"
    worker = app / "Contents/Resources/bin/foresight-diagnostic-worker"
    worker.parent.mkdir(parents=True)
    worker.write_bytes(b"synthetic executable")
    desktop = app / "Contents/MacOS/Example"
    desktop.parent.mkdir()
    desktop.write_bytes(b"synthetic desktop executable")
    helper = worker.parent / "audio-helper"
    helper.write_bytes(b"synthetic audio helper")
    (app / "Contents/Info.plist").write_bytes(
        plistlib.dumps(
            {
                "CFBundleExecutable": "Example",
                "NSCalendarsFullAccessUsageDescription": "Show upcoming meetings.",
            }
        )
    )
    entitlements = tmp_path / "base.entitlements"
    entitlements.write_bytes(plistlib.dumps({"com.apple.security.app-sandbox": False}))
    monkeypatch.setattr(
        bundle, "binaries", lambda root: [worker.resolve(), helper.resolve(), desktop.resolve()]
    )
    events = []

    def run(*args):
        if "--entitlements" in args:
            selected = args[args.index("--entitlements") + 1]
            values = plistlib.loads(selected.read_bytes())
            path = args[-1]
            if path == worker.resolve():
                assert (
                    values["com.apple.security.cs.allow-unsigned-executable-memory"]
                    is True
                )
                assert "com.apple.security.personal-information.calendars" not in values
                events.append("companion-signed")
            elif path == helper.resolve():
                assert "com.apple.security.cs.allow-unsigned-executable-memory" not in values
                assert "com.apple.security.personal-information.calendars" not in values
                events.append("helper-signed")
            else:
                assert (
                    "com.apple.security.cs.allow-unsigned-executable-memory"
                    not in values
                )
                assert values["com.apple.security.personal-information.calendars"] is True
                events.append(
                    "desktop-signed" if path == desktop.resolve() else "outer-signed"
                )
        return ""

    monkeypatch.setattr(bundle, "run", run)
    bundle._sign_application(
        app, "-", entitlements, before_seal=lambda: events.append("final-bytes-sealed")
    )
    assert events == [
        "companion-signed",
        "helper-signed",
        "desktop-signed",
        "final-bytes-sealed",
        "outer-signed",
    ]
