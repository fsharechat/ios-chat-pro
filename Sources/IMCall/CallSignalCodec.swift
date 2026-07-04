import IMProto
import Foundation

/// 一条远端 ICE 候选的三元组 — Android Signal JSON 的 {label,id,candidate}。
/// 被 `IncomingCallSignal.removeCandidates` 与 `MediaEngine.removeRemoteCandidates` 共用。
public struct RemoteIceCandidate: Equatable {
    public var sdpMLineIndex: Int32
    public var sdpMid: String
    public var candidate: String

    public init(sdpMLineIndex: Int32, sdpMid: String, candidate: String) {
        self.sdpMLineIndex = sdpMLineIndex
        self.sdpMid = sdpMid
        self.candidate = candidate
    }
}

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
    case removeCandidates(callId: String, candidates: [RemoteIceCandidate])
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
    /// 405 AnswerT — Android 端接听时先于 401 发送的透传消息,服务器把它
    /// 同步给接听者自己的其他设备(多端"已被他端接听"信号);payload 与 401 相同。
    case answerT(callId: String, audioOnly: Bool)
    /// 403 remove-candidates —— 与 `IncomingCallSignal.removeCandidates` 对称,
    /// 目前仅供测试用 `CallSignalCodec.encode` 构造"对端发来的 remove-candidates"
    /// 这条 wire message(`CallManagerTests.deliverSignal`);`CallManager` 本身
    /// 尚不主动发送这一信令。
    case removeCandidates(callId: String, candidates: [RemoteIceCandidate])
}

public enum CallSignalCodec {
    /// `nil` for any `wireMessage.content.type` outside 401-404 — callers
    /// (`CallManager`) only ever invoke this after `ReceiveMessageHandler`
    /// has already filtered to call-signal types, but this stays
    /// total/safe rather than assuming that filtering happened.
    public static func decode(_ wireMessage: Im_Message) -> IncomingCallSignal? {
        // Android 引擎(AnswerMessage/ByeMessage/SignalMessage/ModifyMessage)
        // 把 callId 编在 MessagePayload.content → wire 的 content 字段;旧版
        // iOS 曾错放在 searchableContent,保留回退以兼容混跑的旧客户端。
        let callId: String
        if wireMessage.content.hasContent, !wireMessage.content.content.isEmpty {
            callId = wireMessage.content.content
        } else {
            callId = wireMessage.content.hasSearchableContent ? wireMessage.content.searchableContent : ""
        }
        let data = wireMessage.content.hasData ? wireMessage.content.data : Data()
        switch wireMessage.content.type {
        case 401:
            return .answer(callId: callId, audioOnly: audioOnlyFlag(from: data))
        case 405:
            // AnswerT 与 Answer 同构 —— Android 引擎里 AnswerTMessage 继承
            // AnswerMessage,接收侧按同一分支处理(多端接听同步就靠它)。
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
        case .answerT(let callId, let audioOnly):
            return (405, callId, Data((audioOnly ? "1" : "0").utf8))
        case .removeCandidates(let callId, let candidates):
            let payload = RemoveCandidatesWireSignal(
                type: "remove-candidates",
                candidates: candidates.map { CandidateEntry(label: $0.sdpMLineIndex, id: $0.sdpMid, candidate: $0.candidate) }
            )
            return (403, callId, try? JSONEncoder().encode(payload))
        }
    }

    private static func audioOnlyFlag(from data: Data) -> Bool {
        (Int(String(decoding: data, as: UTF8.self)) ?? 0) > 0
    }

    private struct SignalTypePeek: Codable { let type: String }
    private struct SDPWireSignal: Codable { let type: String; let sdp: String }
    private struct CandidateWireSignal: Codable { let type: String; let label: Int32; let id: String; let candidate: String }
    private struct RemoveCandidatesWireSignal: Codable { let type: String; let candidates: [CandidateEntry] }
    private struct CandidateEntry: Codable { let label: Int32; let id: String; let candidate: String }

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
        case "remove-candidates":
            guard let parsed = try? JSONDecoder().decode(RemoveCandidatesWireSignal.self, from: data) else { return nil }
            return .removeCandidates(callId: callId, candidates: parsed.candidates.map {
                RemoteIceCandidate(sdpMLineIndex: $0.label, sdpMid: $0.id, candidate: $0.candidate)
            })
        default:
            return nil
        }
    }
}
