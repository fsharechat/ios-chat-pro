/// Wire sub-signal, carried at header offset 7 (masked to 7 bits). Order
/// matches `com.comsince.github.push.SubSignal` exactly — do not reorder.
/// Names are transcribed verbatim from the Android source; their business
/// meaning is documented where each is actually used in Plan B/C handlers.
public enum SubSignal: UInt8 {
    case none = 0
    case connectionAccepted = 1
    case connectionRefusedUnacceptableProtocolVersion = 2
    case connectionRefusedIdentifierRejected = 3
    case connectionRefusedServerUnavailable = 4
    case connectionRefusedBadUserNameOrPassword = 5
    case connectionRefusedNotAuthorized = 6
    case connectionRefusedUnexpectNode = 7
    case connectionRefusedSessionNotExist = 8
    case us = 9
    case far = 10
    case upui = 11
    case frn = 12
    case frus = 13
    case frp = 14
    case fhr = 15
    case fp = 16
    case mn = 17
    case ms = 18
    case mp = 19
    case fn = 20
    case gc = 21
    case gpgi = 22
    case gpgm = 23
    case gam = 24
    case gkm = 25
    case gq = 26
    case gmi = 27
    case mmi = 28
    case gqnut = 29
    case mr = 30
    case rmn = 31
    case lrm = 32
    case gd = 33
    case gmurl = 34
    case fals = 35
    case mrn = 36
    case mrp = 37
    case mrr = 38
    case mdr = 39
    case sai = 40
}
