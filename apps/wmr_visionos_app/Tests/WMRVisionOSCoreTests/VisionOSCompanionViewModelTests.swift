import Combine
import XCTest
@testable import WMRVisionOSCore
import WMRCompanionKit

@MainActor
final class VisionOSCompanionViewModelTests: XCTestCase {
    func testTrackingSnapshotPublishesHeadAndHandPoses() {
        let model = VisionOSCompanionViewModel(
            composer: VisionOSControllerPoseComposer(wristOffset: .identity)
        )
        let head = VisionOSHeadPose(
            pose: VisionOSPose(position: WMRVector3(x: 0, y: 1.6, z: 0)),
            isTracked: true,
            timestamp: 11
        )
        let wrist = VisionOSPose(position: WMRVector3(x: 0.25, y: 1, z: -0.5))
        let snapshot = VisionOSTrackingSnapshot(
            head: head,
            hands: [.left: VisionOSHandPose(hand: .left, joints: [.wrist: wrist])],
            timestamp: 11
        )

        model.ingest(snapshot)

        XCTAssertEqual(model.headPose, head)
        XCTAssertEqual(model.trackingSnapshot, snapshot)
        XCTAssertEqual(model.trackingSnapshot.wrist(for: .left), wrist)
    }

    func testComposesWristPositionWithCompanionKitOrientation() {
        let model = VisionOSCompanionViewModel(
            composer: VisionOSControllerPoseComposer(wristOffset: .identity)
        )
        let wrist = VisionOSPose(position: WMRVector3(x: 0.25, y: 1, z: -0.5))
        model.ingest(
            VisionOSTrackingSnapshot(
                hands: [.left: VisionOSHandPose(hand: .left, joints: [.wrist: wrist])],
                timestamp: 12
            )
        )

        let state = WMRControllerState(
            hand: .left,
            isConnected: true,
            orientation: (w: 0.9238795, x: 0.3826834, y: 0, z: 0)
        )
        let pose = model.updateControllerState(state)

        XCTAssertEqual(pose?.pose.position, wrist.position)
        XCTAssertEqual(pose?.pose.orientation.w ?? 0, 0.9238795, accuracy: 1e-5)
        XCTAssertEqual(pose?.pose.orientation.x ?? 0, 0.3826834, accuracy: 1e-5)
        XCTAssertEqual(pose?.hand, WMRHand.left)
        XCTAssertEqual(model.leftControllerPose, pose)
        XCTAssertNil(model.rightControllerPose)
    }

    func testControllerPoseClearsWithoutWristOrConnection() {
        let model = VisionOSCompanionViewModel(
            composer: VisionOSControllerPoseComposer(wristOffset: .identity)
        )
        let connected = WMRControllerState(hand: .right, isConnected: true)

        XCTAssertNil(model.updateControllerState(connected))

        let wrist = VisionOSPose(position: WMRVector3(x: 0, y: 1, z: 0))
        model.ingest(
            VisionOSTrackingSnapshot(
                hands: [.right: VisionOSHandPose(hand: .right, joints: [.wrist: wrist])]
            )
        )
        XCTAssertNotNil(model.rightControllerPose)

        let disconnected = WMRControllerState(hand: .right, isConnected: false)
        XCTAssertNil(model.updateControllerState(disconnected))
        XCTAssertNil(model.rightControllerPose)
    }

    func testEachHandUsesItsOwnWristAndControllerState() {
        let offset = VisionOSPose(position: WMRVector3(x: 0, y: 0, z: -0.1))
        let model = VisionOSCompanionViewModel(
            composer: VisionOSControllerPoseComposer(wristOffset: offset)
        )
        let leftWrist = VisionOSPose(position: WMRVector3(x: -0.2, y: 1, z: 0))
        let rightWrist = VisionOSPose(position: WMRVector3(x: 0.2, y: 1, z: 0))
        model.ingest(
            VisionOSTrackingSnapshot(
                hands: [
                    .left: VisionOSHandPose(hand: .left, joints: [.wrist: leftWrist]),
                    .right: VisionOSHandPose(hand: .right, joints: [.wrist: rightWrist])
                ]
            )
        )

        model.updateControllerState(
            WMRControllerState(hand: .left, isConnected: true)
        )
        model.updateControllerState(
            WMRControllerState(hand: .right, isConnected: true)
        )

        XCTAssertEqual(model.leftControllerPose?.pose.position, WMRVector3(x: -0.2, y: 1, z: -0.1))
        XCTAssertEqual(model.rightControllerPose?.pose.position, WMRVector3(x: 0.2, y: 1, z: -0.1))
        XCTAssertEqual(model.leftControllerPose?.pose.orientation, .identity)
        XCTAssertEqual(model.rightControllerPose?.pose.orientation, .identity)
    }

    func testWristUpdatesRecomposeStoredControllerState() {
        let model = VisionOSCompanionViewModel(
            composer: VisionOSControllerPoseComposer(wristOffset: .identity)
        )
        model.updateControllerState(
            WMRControllerState(hand: .left, isConnected: true)
        )
        XCTAssertNil(model.leftControllerPose)

        let firstWrist = VisionOSPose(position: WMRVector3(x: 0, y: 1, z: 0))
        model.ingest(
            VisionOSTrackingSnapshot(
                hands: [.left: VisionOSHandPose(hand: .left, joints: [.wrist: firstWrist])],
                timestamp: 31
            )
        )
        XCTAssertEqual(model.leftControllerPose?.pose.position, firstWrist.position)

        let secondWrist = VisionOSPose(position: WMRVector3(x: 0.3, y: 1.1, z: -0.4))
        model.ingest(
            VisionOSTrackingSnapshot(
                hands: [.left: VisionOSHandPose(hand: .left, joints: [.wrist: secondWrist])],
                timestamp: 32
            )
        )
        XCTAssertEqual(model.leftControllerPose?.pose.position, secondWrist.position)
        XCTAssertEqual(model.leftControllerPose?.pose.orientation, .identity)
    }

    func testBindToClientAppliesControllerStatesFromSession() async {
        let model = VisionOSCompanionViewModel(
            composer: VisionOSControllerPoseComposer(wristOffset: .identity)
        )
        let leftWrist = VisionOSPose(position: WMRVector3(x: -0.2, y: 1, z: -0.3))
        let rightWrist = VisionOSPose(position: WMRVector3(x: 0.2, y: 1, z: -0.3))
        model.ingest(
            VisionOSTrackingSnapshot(
                hands: [
                    .left: VisionOSHandPose(hand: .left, joints: [.wrist: leftWrist]),
                    .right: VisionOSHandPose(hand: .right, joints: [.wrist: rightWrist])
                ],
                timestamp: 21
            )
        )

        let session = WMRBridgeSession()
        let client = WMRCompanionClient(session: session)
        model.bind(to: client)

        let leftApplied = expectation(description: "left controller bound")
        let rightApplied = expectation(description: "right controller bound")
        let subscriptions = [
            model.$leftControllerPose.dropFirst().sink { pose in
                if pose != nil { leftApplied.fulfill() }
            },
            model.$rightControllerPose.dropFirst().sink { pose in
                if pose != nil { rightApplied.fulfill() }
            }
        ]
        defer { subscriptions.forEach { $0.cancel() } }

        session.leftStatePublisher.send(WMRControllerState(hand: .left, isConnected: true))
        session.rightStatePublisher.send(WMRControllerState(hand: .right, isConnected: true))

        await fulfillment(of: [leftApplied, rightApplied], timeout: 2)

        XCTAssertEqual(model.leftControllerPose?.pose.position, leftWrist.position)
        XCTAssertEqual(model.rightControllerPose?.pose.position, rightWrist.position)
    }

    func testStartTrackingIngestsSnapshotsAndStopEndsStream() async throws {
        let provider = SimulatedVisionOSTrackingProvider()
        let model = VisionOSCompanionViewModel(
            composer: VisionOSControllerPoseComposer(wristOffset: .identity),
            provider: provider
        )
        try await model.startTracking()
        XCTAssertTrue(provider.isRunning)

        let ingested = expectation(description: "tracking snapshot ingested")
        let subscription = model.$trackingSnapshot
            .dropFirst()
            .sink { snapshot in
                if snapshot.head != nil { ingested.fulfill() }
            }
        defer { subscription.cancel() }

        let head = VisionOSPose(position: WMRVector3(x: 0, y: 1.6, z: 0))
        let wrist = VisionOSPose(position: WMRVector3(x: 0.25, y: 1, z: -0.5))
        provider.send(head: head, hand: .left, wrist: wrist, timestamp: 7)
        await fulfillment(of: [ingested], timeout: 2)

        XCTAssertEqual(model.headPose?.pose, head)
        XCTAssertEqual(model.trackingSnapshot.wrist(for: .left), wrist)
        XCTAssertNotNil(
            model.updateControllerState(WMRControllerState(hand: .left, isConnected: true))
        )

        model.stopTracking()
        XCTAssertFalse(provider.isRunning)

        let streamEnded = expectation(description: "update stream finishes after stop")
        Task {
            for await _ in provider.updates() {}
            streamEnded.fulfill()
        }
        await fulfillment(of: [streamEnded], timeout: 2)
    }
}
