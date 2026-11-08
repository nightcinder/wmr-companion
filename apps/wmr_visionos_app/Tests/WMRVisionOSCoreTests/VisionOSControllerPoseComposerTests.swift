import XCTest
@testable import WMRVisionOSCore
import WMRCompanionKit

final class VisionOSControllerPoseComposerTests: XCTestCase {
    private func assertPose(
        _ pose: VisionOSPose,
        position: WMRVector3,
        orientation: WMRQuaternion,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(pose.position.x, position.x, accuracy: 1e-5, file: file, line: line)
        XCTAssertEqual(pose.position.y, position.y, accuracy: 1e-5, file: file, line: line)
        XCTAssertEqual(pose.position.z, position.z, accuracy: 1e-5, file: file, line: line)
        XCTAssertEqual(pose.orientation.w, orientation.w, accuracy: 1e-5, file: file, line: line)
        XCTAssertEqual(pose.orientation.x, orientation.x, accuracy: 1e-5, file: file, line: line)
        XCTAssertEqual(pose.orientation.y, orientation.y, accuracy: 1e-5, file: file, line: line)
        XCTAssertEqual(pose.orientation.z, orientation.z, accuracy: 1e-5, file: file, line: line)
    }

    func testIdentityWristPassesControllerOrientationThrough() {
        let composer = VisionOSControllerPoseComposer(wristOffset: .identity)
        let imu = WMRQuaternion(w: 0.9238795, x: 0.3826834, y: 0, z: 0)

        let controller = composer.compose(
            hand: .left,
            wrist: .identity,
            controllerOrientation: imu,
            timestamp: 7
        )

        assertPose(controller.pose, position: .zero, orientation: imu)
        XCTAssertEqual(controller.hand, .left)
        XCTAssertEqual(controller.source, .composed)
        XCTAssertTrue(controller.isTracked)
        XCTAssertEqual(controller.timestamp, 7)
    }

    func testWristPositionAndOffsetAreRotatedIntoWorldSpace() {
        let composer = VisionOSControllerPoseComposer(
            wristOffset: VisionOSPose(position: WMRVector3(x: 1, y: 0, z: 0))
        )
        // 90 degrees of yaw about +Z.
        let wrist = VisionOSPose(
            position: WMRVector3(x: 2, y: 3, z: 4),
            orientation: WMRQuaternion(w: 0.70710678, x: 0, y: 0, z: 0.70710678)
        )

        let controller = composer.compose(
            hand: .right,
            wrist: wrist,
            controllerOrientation: .identity
        )

        // The +X grip offset rotates onto +Y, then the wrist translation is added.
        assertPose(controller.pose, position: WMRVector3(x: 2, y: 4, z: 4), orientation: .identity)
    }

    func testControllerOrientationIsComposedWithMountingOffset() {
        let mount = WMRQuaternion(w: 0.70710678, x: 0, y: 0, z: 0.70710678)
        let composer = VisionOSControllerPoseComposer(
            wristOffset: VisionOSPose(orientation: mount)
        )
        let imuYaw = WMRQuaternion(w: 0.70710678, x: 0, y: 0, z: 0.70710678)

        let controller = composer.compose(
            hand: .left,
            wrist: .identity,
            controllerOrientation: imuYaw
        )

        // Two 90-degree yaw rotations produce a 180-degree yaw.
        assertPose(
            controller.pose,
            position: .zero,
            orientation: WMRQuaternion(w: 0, x: 0, y: 0, z: 1)
        )
    }

    func testQuaternionVectorRotation() {
        let yaw = WMRQuaternion(w: 0.70710678, x: 0, y: 0, z: 0.70710678)
        let rotated = yaw.rotated(WMRVector3(x: 1, y: 0, z: 0))
        XCTAssertEqual(rotated.x, 0, accuracy: 1e-5)
        XCTAssertEqual(rotated.y, 1, accuracy: 1e-5)
        XCTAssertEqual(rotated.z, 0, accuracy: 1e-5)
    }
}
