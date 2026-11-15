import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from app.android import AndroidBuilder
from app.apple import AppleBuilder
from app.linux import LinuxBuilder
from app.windows import WindowsBuilder
from main import main


class CoreDownloadsChannelTest(unittest.TestCase):
    """ONEXRAY_CORE_DOWNLOADS must match the channel that can run it."""

    def setUp(self):
        fixtures = Path(__file__).resolve().parents[3] / "references/onexray-tests/build-scripts"
        fixtures.mkdir(parents=True, exist_ok=True)
        temporary = tempfile.TemporaryDirectory(dir=fixtures)
        self.addCleanup(temporary.cleanup)
        self.workspace = Path(temporary.name)
        self.root = self.workspace / "OneXray"
        self.root.mkdir()
        (self.root / "pubspec.yaml").write_bytes(b"name: onexray\nversion: 26.7.3+412\n")
        self.output = self.workspace / "output"
        self.output.mkdir()
        self.addCleanup(mock.patch.stopall)
        mock.patch.dict(os.environ, {"BUILD_NUMBER": "1"}).start()

    def scripts(self):
        return str(self.root / "build_scripts")

    def test_cli_defaults_to_play_and_forwards_the_channel(self):
        for options, distribution in (([], "play"), (["--android-distribution", "direct"], "direct")):
            with (
                mock.patch.object(sys, "argv", ["build", "OneXray", "android", *options]),
                mock.patch("main.build") as run,
            ):
                main()
                self.assertEqual(run.call_args.kwargs["android_distribution"], distribution)
        with (
            mock.patch.object(
                sys, "argv", ["build", "OneXray", "linux", "--android-distribution", "play"]
            ),
            mock.patch("main.build") as run,
            mock.patch("sys.stderr"),
        ):
            with self.assertRaises(SystemExit):
                main()
            run.assert_not_called()

    def test_android_defines_follow_the_distribution_channel(self):
        for distribution, downloads in (("play", "false"), ("direct", "true")):
            with self.subTest(distribution=distribution):
                builder = AndroidBuilder(
                    "OneXray", "android", self.scripts(), distribution=distribution
                )
                commands = []

                def command(args, **kwargs):
                    commands.append(args)
                    if "appbundle" in args:
                        aab = self.root / "build/app/outputs/bundle/release/app-release.aab"
                        aab.parent.mkdir(parents=True, exist_ok=True)
                        aab.write_bytes(b"release bundle")

                with mock.patch("app.android.run_command", side_effect=command):
                    builder.build_app()
                flutter = commands[0]
                self.assertIn(
                    f"--dart-define=ONEXRAY_CORE_DOWNLOADS={downloads}", flutter
                )
                self.assertIn(
                    f"--dart-define=ONEXRAY_ANDROID_DISTRIBUTION={distribution}", flutter
                )
                self.assertEqual(
                    commands[1][:2], ["fastlane", "deploy"], "upload lane stays unchanged"
                )

    def test_android_rejects_unknown_channels_before_building(self):
        with self.assertRaisesRegex(ValueError, "Unsupported Android distribution"):
            AndroidBuilder("OneXray", "android", self.scripts(), distribution="sideload")

    def test_linux_desktop_enables_downloads_for_both_packages(self):
        config = self.root / "linux/packaging/deb/make_config.yaml"
        config.parent.mkdir(parents=True)
        config.write_text("installed_size: 1\n")
        bundle = self.root / "build/linux/x64/release/bundle"
        bundle.mkdir(parents=True)
        (bundle / "OneXray").write_bytes(b"x" * 4096)
        with (
            mock.patch("app.builder.platform.system", return_value="Linux"),
            mock.patch("app.builder.platform.machine", return_value="x86_64"),
        ):
            builder = LinuxBuilder("OneXray", "linux", self.scripts())

            def package(args, **kwargs):
                extension = args[args.index("--targets") + 1]
                self.assertIn("--build-dart-define", args)
                self.assertIn("ONEXRAY_CORE_DOWNLOADS=true", args)
                path = (
                    self.root
                    / "dist"
                    / builder.read_version()
                    / f"OneXray-linux-x86_64.{extension}"
                )
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(extension.encode())

            with mock.patch("app.builder.run_command", side_effect=package) as run:
                builder.build_app()
        self.assertEqual(run.call_count, 2)

    def test_windows_exe_enables_downloads(self):
        builder = self.windows_builder("exe")

        def package(args, **kwargs):
            if "package" in args:
                self.assertIn("--build-dart-define", args)
                self.assertIn("ONEXRAY_CORE_DOWNLOADS=true", args)
                dist = self.root / "dist/26.7.3"
                dist.mkdir(parents=True, exist_ok=True)
                for name in ("exe", "zip"):
                    (dist / f"OneXray-windows-amd64.{name}").write_bytes(name.encode())

        with mock.patch("app.builder.run_command", side_effect=package) as run:
            builder.build_app()
        self.assertTrue(any("package" in call.args[0] for call in run.call_args_list))

    def test_windows_msix_keeps_downloads_off(self):
        builder = self.windows_builder("msix")
        with (
            mock.patch("app.windows.run_command") as run,
            mock.patch.object(builder, "package_msix"),
        ):
            builder.build_app()
        flutter = run.call_args_list[0].args[0]
        self.assertIn("--dart-define=ONEXRAY_WINDOWS_MODE=msix", flutter)
        self.assertIn("--dart-define=ONEXRAY_CORE_DOWNLOADS=false", flutter)

    def windows_builder(self, mode):
        if mode == "exe":
            config = self.root / "windows/packaging/exe/make_config.yaml"
            config.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(
                Path(__file__).resolve().parents[2] / "windows/packaging/exe/make_config.yaml",
                config,
            )
        with mock.patch.dict(os.environ, {"ONEXRAY_WINDOWS_ARCH": "x64"}):
            return WindowsBuilder("OneXray", "windows", self.scripts(), mode=mode)

    def test_apple_uses_the_default_off_without_the_ineffective_env_pin(self):
        builder = AppleBuilder("OneXray", "macos", self.scripts())
        with mock.patch("app.apple.run_command") as run:
            builder.build_app()
        self.assertEqual(run.call_args.args[0][:2], ["fastlane", "deploy"])
        # Apple keeps the Dart default false; an environment entry would not
        # reach flutter build as a --dart-define, so none is passed.
        self.assertNotIn("env", run.call_args.kwargs)


if __name__ == "__main__":
    unittest.main()
