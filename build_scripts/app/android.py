import shutil
from pathlib import Path

from app.builder import Builder
from app.command_line import flutter_command, run_command


class AndroidBuilder(Builder):
    def __init__(
        self,
        project: str,
        system: str,
        build_scripts_dir: str,
        *,
        distribution: str = "play",
    ):
        if distribution not in ("play", "direct"):
            raise ValueError(f"Unsupported Android distribution: {distribution}")
        super().__init__(project, system, build_scripts_dir)
        self.distribution = distribution

    def build_app(self):
        # Core downloads stay off for Play builds; direct APK/AAB channels
        # may replace the bundled core. The ABI list is the universal set.
        core_downloads = "true" if self.distribution == "direct" else "false"
        run_command(
            [
                flutter_command(),
                "build",
                "appbundle",
                "--target-platform",
                "android-arm64,android-x64",
                f"--dart-define=ONEXRAY_CORE_DOWNLOADS={core_downloads}",
                f"--dart-define=ONEXRAY_ANDROID_DISTRIBUTION={self.distribution}",
            ],
            cwd=self.root_dir,
        )
        run_command(
            ["fastlane", "deploy", "--verbose"],
            cwd=self.project_dir,
            env={"ONEXRAY_BUILD_NUMBER": str(self.build_number)},
        )
        shutil.copy2(
            Path(self.root_dir) / "build/app/outputs/bundle/release/app-release.aab",
            self.output_dir,
        )
