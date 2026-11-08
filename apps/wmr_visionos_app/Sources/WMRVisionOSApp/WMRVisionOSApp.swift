import SwiftUI

/// SwiftUI application definition for the native visionOS companion.
///
/// The package builds this as a library so `swift build` and `swift test` can
/// run on macOS. A visionOS application target supplies the bundle entry point
/// and hosts `WMRVisionOSApp.main()`.
public struct WMRVisionOSApp: App {
    @StateObject private var model = CompanionDashboardModel()

    public init() {}

    public var body: some Scene {
        WindowGroup {
            CompanionDashboardView(model: model)
        }

        #if os(visionOS)
        ImmersiveSpace(id: ControllerImmersiveSpace.id) {
            ControllerRealityView(model: model.tracking)
        }
        #endif
    }
}
