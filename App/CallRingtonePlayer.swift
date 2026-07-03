import AVFoundation
import IMCall

/// 来电/去电铃声(资源复用 android-chat-pro 的 raw 音频,行为对齐:
/// incoming 循环放来电铃声、outgoing 循环放回铃音,离开这两个状态即停)。
/// 由 SceneDelegate 在 CallManager.$state 变化时驱动 —— 状态一进入
/// connecting(接听)或 idle(挂断/超时)铃声即停,不需要额外事件。
///
/// 铃声阶段 WebRTC 的 .playAndRecord 会话尚未激活(主叫 startPreview 已
/// 激活,音量走通话路由,与回铃音语义一致;被叫要到接听才激活),
/// AVAudioPlayer 直接用默认会话播放即可,无需自行改会话配置。
final class CallRingtonePlayer {
    private enum Mode { case incoming, outgoing }

    private var player: AVAudioPlayer?
    private var currentMode: Mode?

    func update(for state: CallState) {
        switch state {
        case .incoming: play(.incoming)
        case .outgoing: play(.outgoing)
        case .idle, .connecting, .connected: stop()
        }
    }

    private func play(_ mode: Mode) {
        guard currentMode != mode else { return }
        stop()
        let resourceName = mode == .incoming ? "incoming_call_ring" : "outgoing_call_ring"
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "mp3") else { return }
        guard let newPlayer = try? AVAudioPlayer(contentsOf: url) else { return }
        newPlayer.numberOfLoops = -1
        newPlayer.play()
        player = newPlayer
        currentMode = mode
    }

    private func stop() {
        player?.stop()
        player = nil
        currentMode = nil
    }
}
