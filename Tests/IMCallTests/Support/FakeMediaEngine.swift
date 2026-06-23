import Foundation
@testable import IMCall

final class FakeMediaEngine: MediaEngine {
    var onLocalCandidate: ((Int32, String, String) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?

    private(set) var startCalls: [Bool] = []
    private(set) var createOfferCallCount = 0
    private(set) var createAnswerCalls: [String] = []
    private(set) var remoteAnswers: [String] = []
    private(set) var remoteCandidates: [(Int32, String, String)] = []
    private(set) var audioOnlyCalls: [Bool] = []
    private(set) var closeCallCount = 0

    var offerSDPToReturn = "fake-offer-sdp"
    var answerSDPToReturn = "fake-answer-sdp"

    func start(audioOnly: Bool) {
        startCalls.append(audioOnly)
    }

    func createOffer(completion: @escaping (String) -> Void) {
        createOfferCallCount += 1
        completion(offerSDPToReturn)
    }

    func createAnswer(forRemoteOffer sdp: String, completion: @escaping (String) -> Void) {
        createAnswerCalls.append(sdp)
        completion(answerSDPToReturn)
    }

    func setRemoteAnswer(_ sdp: String) {
        remoteAnswers.append(sdp)
    }

    func addRemoteCandidate(sdpMLineIndex: Int32, sdpMid: String, candidate: String) {
        remoteCandidates.append((sdpMLineIndex, sdpMid, candidate))
    }

    func setAudioOnly(_ audioOnly: Bool) {
        audioOnlyCalls.append(audioOnly)
    }

    func close() {
        closeCallCount += 1
    }

    func simulateConnected() {
        onConnected?()
    }

    func simulateDisconnected() {
        onDisconnected?()
    }

    func simulateLocalCandidate(sdpMLineIndex: Int32 = 0, sdpMid: String = "audio", candidate: String = "candidate:1...") {
        onLocalCandidate?(sdpMLineIndex, sdpMid, candidate)
    }
}
