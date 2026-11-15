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
        # Apple always ships the code-signed static xcframework, which cannot
        # be replaced at runtime; ONEXRAY_CORE_DOWNLOADS therefore keeps its
        # Dart default of false for every Apple build.
        run_command(["fastlane", "deploy", "--verbose"], cwd=self.project_dir)
