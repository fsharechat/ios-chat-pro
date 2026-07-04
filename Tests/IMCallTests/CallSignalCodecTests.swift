import XCTest
import Foundation
import IMProto
@testable import IMCall

final class CallSignalCodecTests: XCTestCase {
    private func makeWireMessage(type: Int32, callId: String, data: Data? = nil) -> Im_Message {
        var message = Im_Message()
        message.fromUser = "them"
        var content = Im_MessageContent()
        content.type = type
        // Android 引擎(AnswerMessage/ByeMessage/SignalMessage 等)把 callId
        // 编在 MessagePayload.content → wire 的 content 字段,不是 searchableContent。
        content.content = callId
        if let data { content.data = data }
        message.content = content
        return message
    }

    func test_decodeAnswer_parsesCallIdAndAudioOnly() {
        let wire = makeWireMessage(type: 401, callId: "call-1", data: Data("1".utf8))
        XCTAssertEqual(CallSignalCodec.decode(wire), .answer(callId: "call-1", audioOnly: true))
    }

    func test_decodeAnswer_audioOnlyFalseWhenDataIsZero() {
        let wire = makeWireMessage(type: 401, callId: "call-1", data: Data("0".utf8))
        XCTAssertEqual(CallSignalCodec.decode(wire), .answer(callId: "call-1", audioOnly: false))
    }

    func test_decodeBye_parsesCallId() {
        let wire = makeWireMessage(type: 402, callId: "call-1")
        XCTAssertEqual(CallSignalCodec.decode(wire), .bye(callId: "call-1"))
    }

    func test_decodeModify_parsesCallIdAndAudioOnly() {
        let wire = makeWireMessage(type: 404, callId: "call-1", data: Data("1".utf8))
        XCTAssertEqual(CallSignalCodec.decode(wire), .modify(callId: "call-1", audioOnly: true))
    }

    func test_decodeSignal_offer_parsesSDP() {
        let wire = makeWireMessage(type: 403, callId: "call-1", data: Data("""
        {"type":"offer","sdp":"v=0..."}
        """.utf8))
        XCTAssertEqual(CallSignalCodec.decode(wire), .sdpOffer(callId: "call-1", sdp: "v=0..."))
    }

    func test_decodeSignal_answer_parsesSDP() {
        let wire = makeWireMessage(type: 403, callId: "call-1", data: Data("""
        {"type":"answer","sdp":"v=0...answer"}
        """.utf8))
        XCTAssertEqual(CallSignalCodec.decode(wire), .sdpAnswer(callId: "call-1", sdp: "v=0...answer"))
    }

    func test_decodeSignal_candidate_parsesLabelIdAndCandidate() {
        let wire = makeWireMessage(type: 403, callId: "call-1", data: Data("""
        {"type":"candidate","label":0,"id":"audio","candidate":"candidate:1 1 UDP..."}
        """.utf8))
        XCTAssertEqual(CallSignalCodec.decode(wire), .iceCandidate(callId: "call-1", sdpMLineIndex: 0, sdpMid: "audio", candidate: "candidate:1 1 UDP..."))
    }

    func test_decodeSignal_malformedData_returnsNil() {
        let wire = makeWireMessage(type: 403, callId: "call-1", data: Data("not json".utf8))
        XCTAssertNil(CallSignalCodec.decode(wire))
    }

    func test_decode_unsupportedType_returnsNil() {
        let wire = makeWireMessage(type: 1, callId: "call-1") // text — not a call signal
        XCTAssertNil(CallSignalCodec.decode(wire))
    }

    func test_encodeAnswer_returnsWireTypeCallIdAndAudioOnlyByte() {
        let encoded = CallSignalCodec.encode(.answer(callId: "call-1", audioOnly: true))
        XCTAssertEqual(encoded.wireType, 401)
        XCTAssertEqual(encoded.callId, "call-1")
        XCTAssertEqual(encoded.data, Data("1".utf8))
    }

    func test_encodeBye_returnsWireTypeAndCallIdNoData() {
        let encoded = CallSignalCodec.encode(.bye(callId: "call-1"))
        XCTAssertEqual(encoded.wireType, 402)
        XCTAssertNil(encoded.data)
    }

    func test_encodeSdpOffer_returnsWireType403WithJSON() throws {
        let encoded = CallSignalCodec.encode(.sdpOffer(callId: "call-1", sdp: "v=0..."))
        XCTAssertEqual(encoded.wireType, 403)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded.data!) as? [String: String])
        XCTAssertEqual(json["type"], "offer")
        XCTAssertEqual(json["sdp"], "v=0...")
    }

    func test_encodeIceCandidate_returnsWireType403WithLabelIdCandidate() throws {
        let encoded = CallSignalCodec.encode(.iceCandidate(callId: "call-1", sdpMLineIndex: 1, sdpMid: "video", candidate: "candidate:2..."))
        XCTAssertEqual(encoded.wireType, 403)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded.data!) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "candidate")
        XCTAssertEqual(json["label"] as? Int, 1)
        XCTAssertEqual(json["id"] as? String, "video")
        XCTAssertEqual(json["candidate"] as? String, "candidate:2...")
    }

    func test_encodeThenDecode_roundTripsForEverySignalShape() {
        let signals: [(OutgoingCallSignal, IncomingCallSignal)] = [
            (.answer(callId: "c1", audioOnly: false), .answer(callId: "c1", audioOnly: false)),
            (.bye(callId: "c1"), .bye(callId: "c1")),
            (.sdpOffer(callId: "c1", sdp: "sdp-1"), .sdpOffer(callId: "c1", sdp: "sdp-1")),
            (.sdpAnswer(callId: "c1", sdp: "sdp-2"), .sdpAnswer(callId: "c1", sdp: "sdp-2")),
            (.iceCandidate(callId: "c1", sdpMLineIndex: 0, sdpMid: "audio", candidate: "cand"), .iceCandidate(callId: "c1", sdpMLineIndex: 0, sdpMid: "audio", candidate: "cand")),
            (.modify(callId: "c1", audioOnly: true), .modify(callId: "c1", audioOnly: true)),
        ]
        for (outgoing, expectedIncoming) in signals {
            let encoded = CallSignalCodec.encode(outgoing)
            var wire = Im_Message()
            wire.fromUser = "them"
            var content = Im_MessageContent()
            content.type = encoded.wireType
            content.content = encoded.callId
            if let data = encoded.data { content.data = data }
            wire.content = content
            XCTAssertEqual(CallSignalCodec.decode(wire), expectedIncoming)
        }
    }

    func test_encode_answerT_producesType405WithAudioOnlyFlag() {
        let encoded = CallSignalCodec.encode(.answerT(callId: "call-1", audioOnly: true))
        XCTAssertEqual(encoded.wireType, 405)
        XCTAssertEqual(encoded.callId, "call-1")
        XCTAssertEqual(encoded.data, Data("1".utf8))
    }

    func test_decode_type405_decodesAsAnswer() {
        var wire = Im_Message()
        wire.content.type = 405
        wire.content.content = "call-1"
        wire.content.data = Data("0".utf8)
        XCTAssertEqual(CallSignalCodec.decode(wire), .answer(callId: "call-1", audioOnly: false))
    }

    func test_decode_removeCandidates_parsesCandidateList() {
        let json = #"{"type":"remove-candidates","candidates":[{"label":0,"id":"audio","candidate":"candidate:1"},{"label":1,"id":"video","candidate":"candidate:2"}]}"#
        var wire = Im_Message()
        wire.content.type = 403
        wire.content.content = "call-1"
        wire.content.data = Data(json.utf8)
        XCTAssertEqual(CallSignalCodec.decode(wire), .removeCandidates(callId: "call-1", candidates: [
            RemoteIceCandidate(sdpMLineIndex: 0, sdpMid: "audio", candidate: "candidate:1"),
            RemoteIceCandidate(sdpMLineIndex: 1, sdpMid: "video", candidate: "candidate:2"),
        ]))
    }
}
