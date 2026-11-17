/*
 * Copyright 2026 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// Unseal: per-participant keys rotated as Element Call does and as im's `LiveKitCallEngine` does
/// (`CallKeyRollout`): the new key goes to the others in the next slot first, and the publisher
/// encrypts with it a second later (`setKey` for its own identity, then `setCurrentKeyIndex`).
///
/// Ways it could fail:
///  P1 the subscriber stops decrypting while the publisher switches slots (missing key or failure)
///  P2 the publisher's frames don't move to the new slot (`setCurrentKeyIndex` doesn't reach its sender)
///  P3 the test can't see a gap: switching before the subscriber has the key must show one (control)
///  P4 overwriting the slot in use, as im did before 2.19 (slot 0 only), must show one too (control)
@Suite(.serialized, .tags(.e2e, .e2ee, .media), TestLimits.e2e)
struct PerParticipantRolloutTests {
    private final class Watcher: RoomDelegate, @unchecked Sendable {
        private let _states = StateSync([E2EEState]())
        var states: [E2EEState] { _states.copy() }

        func room(_: Room, trackPublication _: TrackPublication, didUpdateE2EEState state: E2EEState) {
            _states.mutate { $0.append(state) }
        }
    }

    private enum Order {
        /// Others get the key, then the publisher uses it a second later (im, Element Call).
        case deliverThenSwitch
        /// The publisher uses the new slot before the others have the key.
        case switchThenDeliver
        /// The new key overwrites slot 0, in use, on both sides a second apart.
        case overwriteSlotZero
    }

    /// As im's `LiveKitCallEngine.keyProviderOptions`, with failures reported at once.
    private static let options = KeyProviderOptions(sharedKey: false, ratchetWindowSize: 10, failureTolerance: 0,
                                                    keyRingSize: 256, keyDerivationAlgorithm: .hkdf)
    private static let dimensions: Dimensions = .h720_169

    private static func key() -> Data {
        Data((0 ..< 16).map { _ in UInt8.random(in: 0 ... 255) })
    }

    private static func waitUntil(timeout: TimeInterval = 30, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw LiveKitError(.timedOut, message: "Timed out")
    }

    /// The subscriber's states after the rotation started.
    private func rotate(_ order: Order) async throws -> (after: [E2EEState], publisherIndex: Int32) {
        let publisherKeys = BaseKeyProvider(options: Self.options)
        let subscriberKeys = BaseKeyProvider(options: Self.options)
        let subscriber = Watcher()
        let rooms = [
            RoomTestingOptions(encryptionOptions: EncryptionOptions(keyProvider: publisherKeys), canPublish: true),
            RoomTestingOptions(delegate: subscriber, encryptionOptions: EncryptionOptions(keyProvider: subscriberKeys), canSubscribe: true),
        ]
        var after: [E2EEState] = []
        try await TestEnvironment.withRooms(rooms) { rooms in
            let publisher = try #require(rooms.first)
            let identity = try #require(publisher.localParticipant.identity?.stringValue)
            let first = Self.key()
            publisherKeys.setKey(keyData: first, participantId: identity, index: 0)
            publisherKeys.setCurrentKeyIndex(0)
            subscriberKeys.setKey(keyData: first, participantId: identity, index: 0)

            let track = await LocalVideoTrack.createBufferTrack(name: "camera", source: .camera,
                                                                options: BufferCaptureOptions(dimensions: Self.dimensions))
            let capturer = try #require(track.capturer as? BufferCapturer)
            let feeder = capturer.startFeedingFrames(dimensions: Self.dimensions).cancellable()
            defer { feeder.cancel() }
            _ = try await publisher.localParticipant.publish(videoTrack: track)
            try await Self.waitUntil { subscriber.states.last == .ok }
            // Frames at slot 0 for a while.
            try await Task.sleep(nanoseconds: 1_000_000_000)

            let seen = subscriber.states.count
            let second = Self.key()
            switch order {
            case .deliverThenSwitch:
                subscriberKeys.setKey(keyData: second, participantId: identity, index: 1)
                try await Task.sleep(nanoseconds: 1_000_000_000)
                publisherKeys.setKey(keyData: second, participantId: identity, index: 1)
                publisherKeys.setCurrentKeyIndex(1)
            case .switchThenDeliver:
                publisherKeys.setKey(keyData: second, participantId: identity, index: 1)
                publisherKeys.setCurrentKeyIndex(1)
                try await Task.sleep(nanoseconds: 1_000_000_000)
                subscriberKeys.setKey(keyData: second, participantId: identity, index: 1)
            case .overwriteSlotZero:
                publisherKeys.setKey(keyData: second, participantId: identity, index: 0)
                publisherKeys.setCurrentKeyIndex(0)
                try await Task.sleep(nanoseconds: 1_000_000_000)
                subscriberKeys.setKey(keyData: second, participantId: identity, index: 0)
            }
            // Frames with the new key for a while.
            try await Task.sleep(nanoseconds: 3_000_000_000)
            after = Array(subscriber.states.dropFirst(seen))
        }
        print("[rollout] \(order): subscriber after the rotation \(after.map { $0.toString() }), publisher index \(publisherKeys.getCurrentKeyIndex())")
        return (after, publisherKeys.getCurrentKeyIndex())
    }

    @Test func deliveredBeforeUseNeverInterrupts() async throws {  // P1, P2
        let result = try await rotate(.deliverThenSwitch)
        #expect(!result.after.contains(.missing_key) && !result.after.contains(.decryption_failed),
                "subscriber after the rotation: \(result.after.map { $0.toString() })")
        #expect(result.publisherIndex == 1)
    }

    @Test func usedBeforeDeliveredInterrupts() async throws {  // P3
        let result = try await rotate(.switchThenDeliver)
        #expect(result.after.contains(.missing_key) || result.after.contains(.decryption_failed),
                "subscriber after the rotation: \(result.after.map { $0.toString() })")
        #expect(result.after.last == .ok, "never recovered: \(result.after.map { $0.toString() })")
    }

    @Test func overwritingTheSlotInUseInterrupts() async throws {  // P4
        let result = try await rotate(.overwriteSlotZero)
        #expect(result.after.contains(.missing_key) || result.after.contains(.decryption_failed),
                "subscriber after the rotation: \(result.after.map { $0.toString() })")
    }
}
