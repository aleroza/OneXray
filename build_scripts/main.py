#!/usr/bin/env python3

import argparse
import os

from app.config import PROJECT_CONFIG
from app.flutter import BUILDERS, build


def main():
    parser = argparse.ArgumentParser(description="Build and package OneXray")
    parser.add_argument("project", choices=PROJECT_CONFIG)
    parser.add_argument("system", choices=BUILDERS)
    parser.add_argument(
        "--windows-mode",
        choices=("exe", "msix"),
        help="Windows runtime/package mode (default: exe)",
    )
    parser.add_argument(
        "--android-distribution",
        choices=("play", "direct"),
        help="Android distribution channel (default: play)",
    )
    args = parser.parse_args()
    if args.windows_mode is not None and args.system != "windows":
        parser.error("--windows-mode is only valid for Windows")
    if args.android_distribution is not None and args.system != "android":
        parser.error("--android-distribution is only valid for Android")
    build(
        args.project,
        args.system,
        os.path.dirname(os.path.abspath(__file__)),
        windows_mode=args.windows_mode or "exe",
        android_distribution=args.android_distribution or "play",
    )


if __name__ == "__main__":
    main()
