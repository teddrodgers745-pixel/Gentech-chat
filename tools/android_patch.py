#!/usr/bin/env python3
# Copyright (c) 2026 Minkail. All rights reserved.
"""Idempotent patch of the freshly generated android/ platform.

Runs in CI after `flutter create`. Performs:
  1. INTERNET permission + app label in AndroidManifest.xml;
  2. applicationId -> com.minkail.gentech_lab;
  3. full rewrite of res/values/styles.xml and res/values-night/styles.xml
     so windowBackground and windowSplashScreenBackground are #1B1A19
     (warm charcoal, matches the in-app splash).

Every step is safe to run repeatedly and never fails the build:
missing files are skipped with a notice.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP_LABEL = "GenTech Chat"
APPLICATION_ID = "com.minkail.gentech_lab"
SPLASH_BG = "#1B1A19"

STYLES_TEMPLATE = """<?xml version="1.0" encoding="utf-8"?>
<!-- Patched by tools/android_patch.py: warm charcoal splash background. -->
<resources>
    <style name="LaunchTheme" parent="@android:style/{launch_parent}">
        <item name="android:windowBackground">{bg}</item>
        <item name="android:windowSplashScreenBackground">{bg}</item>
        <item name="android:forceDarkAllowed">false</item>
        <item name="android:windowFullscreen">false</item>
        <item name="android:windowLayoutInDisplayCutoutMode">shortEdges</item>
    </style>
    <style name="NormalTheme" parent="@android:style/{normal_parent}">
        <item name="android:windowBackground">?android:colorBackground</item>
    </style>
</resources>
"""


def patch_manifest() -> None:
    path = ROOT / "android" / "app" / "src" / "main" / "AndroidManifest.xml"
    if not path.exists():
        print("android_patch: manifest not found, skip")
        return
    text = path.read_text(encoding="utf-8")
    if "android.permission.INTERNET" not in text:
        text = text.replace(
            "<application",
            '<uses-permission android:name="android.permission.INTERNET"/>\n    <application',
            1,
        )
    text = re.sub(
        r'android:label="[^"]*"',
        f'android:label="{APP_LABEL}"',
        text,
        count=1,
    )
    path.write_text(text, encoding="utf-8")
    print("android_patch: manifest patched (INTERNET + label)")


def patch_application_id() -> None:
    for name in ("build.gradle", "build.gradle.kts"):
        path = ROOT / "android" / "app" / name
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        text, n = re.subn(
            r'applicationId(\s+)("[^"]*")',
            rf'applicationId\1"{APPLICATION_ID}"',
            text,
            count=1,
        )
        if n:
            path.write_text(text, encoding="utf-8")
            print(f"android_patch: applicationId -> {APPLICATION_ID}")
        else:
            print(f"android_patch: applicationId not found in {name}, skip")
        return
    print("android_patch: app/build.gradle not found, skip")


def patch_styles() -> None:
    variants = {
        "values": ("Theme.Light.NoTitleBar", "Theme.Light.NoTitleBar"),
        "values-night": ("Theme.Black.NoTitleBar", "Theme.Black.NoTitleBar"),
    }
    for folder, (launch_parent, normal_parent) in variants.items():
        path = ROOT / "android" / "app" / "src" / "main" / "res" / folder / "styles.xml"
        if not path.exists():
            print(f"android_patch: {path} not found, skip")
            continue
        content = STYLES_TEMPLATE.format(
            launch_parent=launch_parent,
            normal_parent=normal_parent,
            bg=SPLASH_BG,
        )
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        print(f"android_patch: {folder}/styles.xml rewritten (bg {SPLASH_BG})")


def main() -> None:
    patch_manifest()
    patch_application_id()
    patch_styles()
    print("android_patch: done")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # never fail the build because of cosmetics
        print(f"android_patch: unexpected error: {exc}", file=sys.stderr)
        sys.exit(0)
