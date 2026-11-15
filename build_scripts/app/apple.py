from app.builder import Builder
from app.command_line import run_command


class AppleBuilder(Builder):
    def before_build(self):
        super().before_build()
        run_command(
            ["xcrun", "agvtool", "new-version", "-all", str(self.build_number)],
            cwd=self.project_dir,
        )

    def build_app(self):
        # Apple ships the code-signed bundled xcframework, so downloads stay
        # off. The Dart default is false already; the environment pin records
        # the channel and takes effect once the shared Fastfiles forward it
        # into `flutter build` as --dart-define.
        run_command(
            ["fastlane", "deploy", "--verbose"],
            cwd=self.project_dir,
            env={"ONEXRAY_CORE_DOWNLOADS": "false"},
        )
