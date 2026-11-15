// Compile-time switches set by build_scripts per platform and channel.
// Defaults must keep a plain `flutter build` identical to current behavior.

/// Core downloads only ship where they can actually run: the Linux desktop
/// and the Windows EXE/ZIP and Android direct channels.
const coreDownloadsBuildEnabled = bool.fromEnvironment(
  'ONEXRAY_CORE_DOWNLOADS',
  defaultValue: false,
);

/// Android distribution channel: `play` for Google Play builds, `direct` for
/// sideloaded APKs/AABs. Mirrors ONEXRAY_WINDOWS_MODE as a build define.
const androidDistributionName = String.fromEnvironment(
  'ONEXRAY_ANDROID_DISTRIBUTION',
  defaultValue: 'direct',
);
