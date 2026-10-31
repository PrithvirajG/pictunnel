#if os(iOS)
import Foundation
import Photos
import UIKit

/// Photo library changes while the app is in the foreground (a photo just taken, a limited-access
/// selection changed) request a run, debounced so a burst of changes makes one run.
///
/// It registers with PhotoKit only once read access exists: registering earlier could show the
/// access prompt at launch.
public final class LibraryWatcher: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    public static let debounceSeconds: TimeInterval = 3

    private let onChange: () -> Void
    private let lock = NSLock()
    private var registered = false
    private var pending: DispatchWorkItem?

    /// `onChange` runs on the main thread, in the foreground only.
    public init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    /// Registers once read access (full or limited) exists; safe to call again.
    public func registerIfAllowed() {
        guard PhotoKitLibrary.access() == .full || PhotoKitLibrary.access() == .limited else { return }
        lock.lock()
        let first = !registered
        registered = true
        lock.unlock()
        if first { PHPhotoLibrary.shared().register(self) }
    }

    /// Drops a run that is waiting for its debounce (unpairing).
    public func cancelPending() {
        DispatchQueue.main.async { [weak self] in
            self?.pending?.cancel()
            self?.pending = nil
        }
    }

    public func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async { [weak self] in
            guard let self, UIApplication.shared.applicationState == .active else { return }
            self.pending?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, UIApplication.shared.applicationState == .active else { return }
                self.pending = nil
                self.onChange()
            }
            self.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceSeconds, execute: work)
        }
    }
}
#endif
