import AVFoundation
import IMCall

/// 来电/去电铃声(资源复用 android-chat-pro 的 raw 音频,行为对齐:
/// incoming 循环放来电铃声、outgoing 循环放回铃音,离开这两个状态即停)。
/// 由 SceneDelegate 在 CallManager.$state 变化时驱动 —— 状态一进入
/// connecting(接听)或 idle(挂断/超时)铃声即停,不需要额外事件。
///
/// **静音拨片也要响(用户决策):** 对齐 Android(`STREAM_RING`,不受静音
/// 开关影响)与微信的来电铃声行为 —— `AVAudioSession` 默认的
/// `.soloAmbient` 会话在静音拨片拨上时会被系统直接静音,所以 `play(_:)`
/// 在真正创建 player 前显式切到 `.playback` 分类并激活会话。`stop()`
/// 对称地 deactivate,但**只在铃声确实在播放时才做**(`player != nil`
/// 判断)—— 接听后 `WebRTCClient` 会自己 `setCategory(.playAndRecord)`
/// 建立通话会话,如果 `stop()` 无条件 deactivate,会把刚建立的通话会话
/// 也带下去。
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
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "mp3") else {
            print("[CallRingtonePlayer] resource not found: \(resourceName).mp3")
            return
        }
        // 静音拨片也要响 —— 见本类型的 doc comment。
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        guard let newPlayer = try? AVAudioPlayer(contentsOf: url) else {
            print("[CallRingtonePlayer] failed to init AVAudioPlayer for \(resourceName).mp3")
            return
        }
        newPlayer.numberOfLoops = -1
        newPlayer.play()
        player = newPlayer
        currentMode = mode
    }

    private func stop() {
        // 只有铃声确实在播放(player 非 nil)才 deactivate —— 见本类型的
        // doc comment,避免踩掉接听后刚建立的 .playAndRecord 通话会话。
        if player != nil {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        player?.stop()
        player = nil
        currentMode = nil
    }
}
