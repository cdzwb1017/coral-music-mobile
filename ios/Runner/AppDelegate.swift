import AppTrackingTransparency
import AVFAudio
import EventKit
import Flutter
import MediaPlayer
import Photos
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var userApiRunner: UserApiRunner?
  private var nativePlaybackCoordinator: NativePlaybackCoordinator?
  private let eventStore = EKEventStore()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    guard let controller = window?.rootViewController as? FlutterViewController else {
      return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
    let runner = UserApiRunner()
    userApiRunner = runner
    let playbackCoordinator = NativePlaybackCoordinator(runner: runner)
    nativePlaybackCoordinator = playbackCoordinator
    FlutterMethodChannel(
      name: "coral_music/user_api",
      binaryMessenger: controller.binaryMessenger
    ).setMethodCallHandler { call, result in
      switch call.method {
      case "load":
        let arguments = call.arguments as? [String: Any]
        runner.load(arguments?["script"] as? String ?? "", result: result)
      case "clear":
        runner.clear(result: result)
      case "resolveMusicUrl":
        runner.resolveMusicUrl(arguments: call.arguments as? [String: Any], result: result)
      case "resolveLyric":
        runner.resolveLyric(arguments: call.arguments as? [String: Any], result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    FlutterMethodChannel(
      name: "coral_music/native_playback",
      binaryMessenger: controller.binaryMessenger
    ).setMethodCallHandler { call, result in
      playbackCoordinator.handle(call, result: result)
    }
    FlutterEventChannel(
      name: "coral_music/native_playback_events",
      binaryMessenger: controller.binaryMessenger
    ).setStreamHandler(playbackCoordinator)
    DispatchQueue.main.async { [weak self] in
      self?.requestSystemPermissions()
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationWillTerminate(_ application: UIApplication) {
    userApiRunner?.dispose()
    super.applicationWillTerminate(application)
  }

  private func requestSystemPermissions() {
    PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] _ in
      self?.continueOnMain { $0.requestMicrophonePermission() }
    }
  }

  private func requestMicrophonePermission() {
    AVAudioSession.sharedInstance().requestRecordPermission { [weak self] _ in
      self?.continueOnMain { $0.requestMediaLibraryPermission() }
    }
  }

  private func requestMediaLibraryPermission() {
    MPMediaLibrary.requestAuthorization { [weak self] _ in
      self?.continueOnMain { $0.requestCalendarPermission() }
    }
  }

  private func requestCalendarPermission() {
    if #available(iOS 17.0, *) {
      eventStore.requestWriteOnlyAccessToEvents { [weak self] _, _ in
        self?.continueOnMain { $0.requestNotificationPermission() }
      }
    } else {
      eventStore.requestAccess(to: .event) { [weak self] _, _ in
        self?.continueOnMain { $0.requestNotificationPermission() }
      }
    }
  }

  private func requestNotificationPermission() {
    UNUserNotificationCenter.current().requestAuthorization(
      options: [.alert, .badge, .sound]
    ) { [weak self] _, _ in
      self?.continueOnMain { $0.requestTrackingPermission() }
    }
  }

  private func continueOnMain(_ action: @escaping (AppDelegate) -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
      guard let self else { return }
      action(self)
    }
  }

  private func requestTrackingPermission() {
    guard #available(iOS 14.0, *) else { return }
    ATTrackingManager.requestTrackingAuthorization { _ in }
  }
}
