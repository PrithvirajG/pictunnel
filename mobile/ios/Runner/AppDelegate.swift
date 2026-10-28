import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Before returning: BGTaskScheduler handlers must be registered, and the background upload
    // session must exist to receive the events of a relaunch.
    EngineHost.shared.bootstrap()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PicTunnelEngineHost") {
      EngineHost.shared.attach(messenger: registrar.messenger())
    }
  }

  /// The background upload session finished its events (M§6): the engine applies the completions,
  /// then calls `completionHandler`.
  override func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    if !EngineHost.shared.handleBackgroundSessionEvents(identifier: identifier, completionHandler: completionHandler) {
      super.application(application, handleEventsForBackgroundURLSession: identifier, completionHandler: completionHandler)
    }
  }
}
