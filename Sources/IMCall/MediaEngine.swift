import Foundation

/// `CallManager` 眼中的 WebRTC 实现 —— 协议化以便 `CallManagerTests` 用
/// `FakeMediaEngine` 驱动状态机而不链接真 WebRTC。生产实现是 `WebRTCClient`。
///
/// 两阶段模型(对齐 Android AVEngineKit):
/// 1. `startPreview(audioOnly:)` —— 建 capturer + 本地音/视频轨,不建
///    PeerConnection。主叫在拨出瞬间调用(本地预览立即可见),被叫在接听
///    时调用。
/// 2. `connect()` —— 建 PeerConnection 并把已有本地轨加进去。offer 的方向
///    由 CallManager 决定:被叫(initiator)在 connect 后调 `createOffer`;
///    主叫等远端 offer 走 `createAnswer`。
public protocol MediaEngine: AnyObject {
    /// 本地 ICE 候选产出 —— CallManager 包成 403 candidate 发出。
    var onLocalCandidate: ((_ sdpMLineIndex: Int32, _ sdpMid: String, _ candidate: String) -> Void)? { get set }
    /// ICE 首次连通 —— 驱动 `.connecting → .connected`。
    var onConnected: (() -> Void)? { get set }
    /// 连通后 ICE 断开且未恢复 —— CallManager 按 `.mediaFailure` 收场。
    var onDisconnected: (() -> Void)? { get set }

    func startPreview(audioOnly: Bool)
    func connect()
    func createOffer(completion: @escaping (String) -> Void)
    func createAnswer(forRemoteOffer sdp: String, completion: @escaping (String) -> Void)
    func setRemoteAnswer(_ sdp: String)
    func addRemoteCandidate(sdpMLineIndex: Int32, sdpMid: String, candidate: String)
    func removeRemoteCandidates(_ candidates: [RemoteIceCandidate])
    func setAudioOnly(_ audioOnly: Bool)
    func close()
}
