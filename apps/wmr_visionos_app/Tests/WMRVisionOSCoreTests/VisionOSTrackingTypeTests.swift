import XCTest
@testable import WMRVisionOSCore
import WMRCompanionKit

final class VisionOSTrackingTypeTests: XCTestCase {
    func testSnapshotResolvesWristByWMRHand() {
        let wrist = VisionOSPose(position: WMRVector3(x: 0.1, y: 1.2, z: -0.3))
        let snapshot = VisionOSTrackingSnapshot(
            hands: [
                .left: VisionOSHandPose(hand: .left, joints: [.wrist: wrist])
            ]
        )

        XCTAssertEqual(snapshot.wrist(for: .left), wrist)
        XCTAssertNil(snapshot.wrist(for: .right))
        XCTAssertEqual(VisionOSHand(.right).wmrHand, .right)
        XCTAssertEqual(VisionOSHand(.left).wmrHand, .left)
    }

    func testSimulatedProviderPublishesHeadAndHandPoses() async throws {
        let provider = SimulatedVisionOSTrackingProvider()
        try await provider.start()

        let updates = provider.updates()
        var iterator = updates.makeAsyncIterator()

        let head = VisionOSPose(position: WMRVector3(x: 0, y: 1.6, z: 0.2))
        let wrist = VisionOSPose(position: WMRVector3(x: -0.2, y: 1.1, z: -0.4))
        provider.send(head: head, hand: .right, wrist: wrist, timestamp: 42)

        let snapshot = await iterator.next()
        XCTAssertEqual(snapshot?.head?.pose, head)
        XCTAssertTrue(snapshot?.head?.isTracked ?? false)
        XCTAssertEqual(snapshot?.wrist(for: .right), wrist)
        XCTAssertEqual(snapshot?.timestamp, 42)
        XCTAssertEqual(provider.latestSnapshot, snapshot)
    }

    func testSimulatedProviderFinishesStreamOnStop() async throws {
        let provider = SimulatedVisionOSTrackingProvider()
        try await provider.start()
        var iterator = provider.updates().makeAsyncIterator()

        provider.stop()

        let snapshot = await iterator.next()
        XCTAssertNil(snapshot)
        XCTAssertFalse(provider.isRunning)
    }
}
