/// One value read from the registry: [text] for `REG_SZ`, [number] for
/// `REG_DWORD`. A missing value is reported as null, which restore must undo
/// with a delete rather than with a written default.
typedef RegistryValue = ({String? text, int? number});

/// Narrow synchronous view over
/// `HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Internet Settings`
/// so the backend stays testable without Windows or FFI.
abstract interface class WindowsRegistryAccess {
  /// Reads one value of the Internet Settings key; null when it is absent.
  RegistryValue? readValue(String name);

  void setStringValue(String name, String value);

  void setDwordValue(String name, int value);

  /// Removes a value; a missing value is not an error.
  void deleteValue(String name);

  /// Tells running WinINet processes that the settings changed and should be
  /// re-read (`INTERNET_OPTION_SETTINGS_CHANGED` + `INTERNET_OPTION_REFRESH`).
  void notifySettingsChanged();

  void close();
}
