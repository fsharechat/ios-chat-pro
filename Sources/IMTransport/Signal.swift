/// Top-level wire signal. Raw value is the byte stored at header offset 2
/// (masked to 7 bits). Order matches `com.comsince.github.push.Signal` exactly —
/// do not reorder these cases.
public enum Signal: UInt8 {
    case none = 0
    case sub = 1
    case auth = 2
    case ping = 3
    case push = 4
    case contact = 5
    case connect = 6
    case connectAck = 7
    case disconnect = 8
    case publish = 9
    case pubAck = 10
}
