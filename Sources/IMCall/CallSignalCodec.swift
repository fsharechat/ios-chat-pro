import IMProto
import Foundation

/// Decoded shape of an incoming 401/402/403/404 wire message — see the
/// Phase 3 design doc §2's field-mapping table. `searchableContent`=callId,
/// `data`=either an ASCII "0"/"1" (Answer/Modify's audioOnly flag) or a JSON
/// blob (Signal's SDP/ICE payload), mirroring every other content type's
/// wire-field convention in this codebase (`IMMessaging.MessageContentCodec`).
public enum IncomingCallSignal: Equatable {
    case answer(callId: String, audioOnly: Bool)
    case bye(callId: String)
    case sdpOffer(callId: String, sdp: String)
    case sdpAnswer(callId: String, sdp: String)
    case iceCandidate(callId: String, sdpMLineIndex: Int32, sdpMid: String, candidate: String)
    case modify(callId: String, audioOnly: Bool)
}

/// What `CallManager` wants to send — `CallSignalCodec.encode` turns this
/// into the three raw pieces `MessagingService.sendCallControlMessage`
/// needs, keeping `IMCall` itself ignorant of `Im_MessageContent`'s exact
/// field layout outside this one file.
public enum OutgoingCallSignal: Equatable {
    case answer(callId: String, audioOnly: Bool)
    case bye(callId: String)
    case sdpOffer(callId: String, sdp: String)
    case sdpAnswer(callId: String, sdp: String)
    case iceCandidate(callId: String, sdpMLineIndex: Int32, sdpMid: String, candidate: String)
    case modify(callId: String, audioOnly: Bool)
}

public enum CallSignalCodec {
    /// `nil` for any `wireMessage.content.type` outside 401-404 — callers
    /// (`CallManager`) only ever invoke this after `ReceiveMessageHandler`
    /// has already filtered to call-signal types, but this stays
    /// total/safe rather than assuming that filtering happened.
    public static func decode(_ wireMessage: Im_Message) -> IncomingCallSignal? {
        let callId = wireMessage.content.hasSearchableContent ? wireMessage.content.searchableContent : ""
        let data = wireMessage.content.hasData ? wireMessage.content.data : Data()
        switch wireMessage.content.type {
        case 401:
            return .answer(callId: callId, audioOnly: audioOnlyFlag(from: data))
        case 402:
            return .bye(callId: callId)
        case 403:
            return decodeSignal(callId: callId, data: data)
        case 404:
            return .modify(callId: callId, audioOnly: audioOnlyFlag(from: data))
        default:
            return nil
        }
    }

    public static func encode(_ signal: OutgoingCallSignal) -> (wireType: Int32, callId: String, data: Data?) {
        switch signal {
        case .answer(let callId, let audioOnly):
            return (401, callId, Data((audioOnly ? "1" : "0").utf8))
        case .bye(let callId):
            return (402, callId, nil)
        case .sdpOffer(let callId, let sdp):
            return (403, callId, try? JSONEncoder().encode(SDPWireSignal(type: "offer", sdp: sdp)))
        case .sdpAnswer(let callId, let sdp):
            return (403, callId, try? JSONEncoder().encode(SDPWireSignal(type: "answer", sdp: sdp)))
        case .iceCandidate(let callId, let sdpMLineIndex, let sdpMid, let candidate):
            return (403, callId, try? JSONEncoder().encode(CandidateWireSignal(type: "candidate", label: sdpMLineIndex, id: sdpMid, candidate: candidate)))
        case .modify(let callId, let audioOnly):
            return (404, callId, Data((audioOnly ? "1" : "0").utf8))
        }
    }

    private static func audioOnlyFlag(from data: Data) -> Bool {
        (Int(String(decoding: data, as: UTF8.self)) ?? 0) > 0
    }

    private struct SignalTypePeek: Codable { let type: String }
    private struct SDPWireSignal: Codable { let type: String; let sdp: String }
    private struct CandidateWireSignal: Codable { let type: String; let label: Int32; let id: String; let candidate: String }

    private static func decodeSignal(callId: String, data: Data) -> IncomingCallSignal? {
        guard let peek = try? JSONDecoder().decode(SignalTypePeek.self, from: data) else { return nil }
        switch peek.type {
        case "offer":
            guard let parsed = try? JSONDecoder().decode(SDPWireSignal.self, from: data) else { return nil }
            return .sdpOffer(callId: callId, sdp: parsed.sdp)
        case "answer":
            guard let parsed = try? JSONDecoder().decode(SDPWireSignal.self, from: data) else { return nil }
            return .sdpAnswer(callId: callId, sdp: parsed.sdp)
        case "candidate":
            guard let parsed = try? JSONDecoder().decode(CandidateWireSignal.self, from: data) else { return nil }
            return .iceCandidate(callId: callId, sdpMLineIndex: parsed.label, sdpMid: parsed.id, candidate: parsed.candidate)
        default:
            return nil
        }
    }
}
