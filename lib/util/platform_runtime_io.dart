/// Native (iOS, Android, macOS, Windows, Linux) implementation of
/// [detectIsPhysicalDevice].
///
/// Uses `device_info_plus` to read the platform-specific physicality flag:
/// - iOS: `IosDeviceInfo.isPhysicalDevice` (false on Simulator).
/// - Android: `AndroidDeviceInfo.isPhysicalDevice` (false on emulators
///   advertising via the standard Android Build properties).
/// - Desktop targets (macOS, Windows, Linux): treated as physical because
///   there is no widely-deployed "desktop simulator" of the host OS that
///   the demo needs to differentiate.
library;

import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';

Future<bool> detectIsPhysicalDevice() async {
  final plugin = DeviceInfoPlugin();
  if (Platform.isIOS) {
    final info = await plugin.iosInfo;
    return info.isPhysicalDevice;
  }
  if (Platform.isAndroid) {
    final info = await plugin.androidInfo;
    return info.isPhysicalDevice;
  }
  return true;
}
