import SwiftUI
import WMRVisionOSCore

/// Identifier used by `WMRVisionOSApp` to open the 6DoF `ImmersiveSpace`.
public enum ControllerImmersiveSpace {
    public static let id = "WMRControllerSpace"
}

#if os(visionOS)
import RealityKit
import UIKit
import simd

/// RealityKit scene for the 6DoF `ImmersiveSpace`.
///
/// The bridge supplies controller orientation; ARKit hand tracking supplies
/// the wrist translation. `VisionOSCompanionViewModel` composes them into a
/// world-space controller pose, which this view maps onto one entity per hand
/// plus one for the head.
public struct ControllerRealityView: View {
    @ObservedObject private var model: VisionOSCompanionViewModel

    public init(model: VisionOSCompanionViewModel) {
        self.model = model
    }

    public var body: some View {
        RealityView { content in
            content.add(Self.makeFloor())
            content.add(Self.makeMarker(name: "head", radius: 0.09, color: .white))
            content.add(Self.makeMarker(name: "left", radius: 0.04, color: .blue))
            content.add(Self.makeMarker(name: "right", radius: 0.04, color: .orange))
        } update: { content in
            Self.apply(model.headPose?.pose, to: content.entities.first { $0.name == "head" })
            Self.apply(model.leftControllerPose?.pose, to: content.entities.first { $0.name == "left" })
            Self.apply(model.rightControllerPose?.pose, to: content.entities.first { $0.name == "right" })
        }
    }

    private static func makeFloor() -> ModelEntity {
        let floor = ModelEntity(
            mesh: .generateBox(size: SIMD3<Float>(2, 0.01, 2)),
            materials: [SimpleMaterial(color: .gray, isMetallic: false)]
        )
        floor.name = "floor"
        floor.position = SIMD3<Float>(0, 0, -0.8)
        return floor
    }

    private static func makeMarker(
        name: String,
        radius: Float,
        color: UIColor
    ) -> ModelEntity {
        let marker = ModelEntity(
            mesh: .generateSphere(radius: radius),
            materials: [SimpleMaterial(color: color, isMetallic: false)]
        )
        marker.name = name
        marker.isEnabled = false
        return marker
    }

    private static func apply(_ pose: VisionOSPose?, to entity: Entity?) {
        guard let entity, let pose else {
            entity?.isEnabled = false
            return
        }

        entity.isEnabled = true
        entity.position = SIMD3<Float>(pose.position.x, pose.position.y, pose.position.z)
        entity.orientation = simd_quatf(
            ix: pose.orientation.x,
            iy: pose.orientation.y,
            iz: pose.orientation.z,
            r: pose.orientation.w
        )
    }
}
#else
/// Non-visionOS placeholder so the package, and its dashboard, still build on
/// the macOS runner used by CI.
public struct ControllerRealityView: View {
    public init(model: VisionOSCompanionViewModel) {}

    public var body: some View {
        ContentUnavailableView(
            "6DoF visualization requires visionOS",
            systemImage: "arkit"
        )
    }
}
#endif
