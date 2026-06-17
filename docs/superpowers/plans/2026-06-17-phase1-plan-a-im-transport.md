# Phase 1 / Plan A: IMProto + IMTransport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the two foundational, UI-independent Swift packages for the IM protocol stack: `IMProto` (SwiftProtobuf-generated message types from `chat-proto/WFCMessage.proto`) and `IMTransport` (the 10-byte binary frame header + an incremental frame decoder/encoder that exactly mirrors the Android `push-sdk` wire format).

**Architecture:** A single root SwiftPM package (`Package.swift` at repo root) hosts both libraries as independent targets with their own test targets. `IMTransport` has zero dependencies and only deals with raw `Data` — it knows nothing about protobuf or message semantics. `IMProto` depends on `SwiftProtobuf` and contains only generated code plus the vendored `.proto` source. Neither target depends on the other; `IMClient` (Plan B) will depend on both. Everything in this plan is verified with `swift test` — no Xcode project is needed yet (that's introduced in Plan D when UI work starts).

**Tech Stack:** Swift 5.8+, Swift Package Manager, SwiftProtobuf (apple/swift-protobuf), protoc + protoc-gen-swift (build-time codegen, output checked into git).

**Reference facts this plan is built from** (verified by reading the actual Android source, not assumed):
- Frame header layout, byte-for-byte: `android-chat-pro/push-sdk/src/main/java/com/comsince/github/push/Header.java`
- `Signal` enum ordinals: `android-chat-pro/push-sdk/src/main/java/com/comsince/github/push/Signal.java`
- `SubSignal` enum ordinals: `android-chat-pro/push-sdk/src/main/java/com/comsince/github/push/SubSignal.java`
- Proto source: `chat-proto/WFCMessage.proto` (proto2 syntax, package `im`, no imports, self-contained)

---

## Task 1: Root SwiftPM package scaffold

**Files:**
- Create: `Package.swift`
- Create: `Sources/IMProto/.gitkeep`
- Create: `Sources/IMTransport/.gitkeep`
- Create: `Tests/IMProtoTests/.gitkeep`
- Create: `Tests/IMTransportTests/.gitkeep`

- [ ] **Step 1: Create the root package manifest**

```swift
// swift-tools-version:5.8
import PackageDescription

let package = Package(
    name: "IMCore",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "IMProto", targets: ["IMProto"]),
        .library(name: "IMTransport", targets: ["IMTransport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.25.0"),
    ],
    targets: [
        .target(
            name: "IMProto",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(name: "IMProtoTests", dependencies: ["IMProto"]),
        .target(name: "IMTransport"),
        .testTarget(name: "IMTransportTests", dependencies: ["IMTransport"]),
    ]
)
```

- [ ] **Step 2: Create empty source/test directories so the targets resolve**

```bash
mkdir -p Sources/IMProto Sources/IMTransport Tests/IMProtoTests Tests/IMTransportTests
touch Sources/IMProto/.gitkeep Sources/IMTransport/.gitkeep Tests/IMProtoTests/.gitkeep Tests/IMTransportTests/.gitkeep
```

- [ ] **Step 3: Resolve dependencies and build**

Run: `swift build`
Expected: Fetches `swift-protobuf`, then fails with something like `error: Source files for target IMProto should be located under 'Sources/IMProto'... build the target anyway` is NOT expected — empty targets with only a `.gitkeep` build fine as empty modules. Expected final line: `Build complete!`

If it instead errors with "target ... has no source files", remove the `.gitkeep` approach and add one trivial `.swift` file per target instead:
```bash
echo "// IMProto placeholder, removed in Task 2" > Sources/IMProto/_Scaffold.swift
echo "// IMTransport placeholder, removed in Task 3" > Sources/IMTransport/_Scaffold.swift
rm Sources/IMProto/.gitkeep Sources/IMTransport/.gitkeep
```
Re-run `swift build` and confirm `Build complete!`.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Package.resolved Sources Tests
git commit -m "chore: scaffold IMProto and IMTransport SwiftPM targets"
```

---

## Task 2: Vendor the proto file and generate Swift types

**Files:**
- Create: `Proto/WFCMessage.proto` (copied verbatim from `../chat-proto/WFCMessage.proto`)
- Create: `Scripts/generate-proto.sh`
- Create: `Sources/IMProto/Generated/WFCMessage.pb.swift` (generated output, committed to git)
- Modify: `.gitignore` (add `.tools/`)
- Test: `Tests/IMProtoTests/ConnectAckPayloadCodingTests.swift`

- [ ] **Step 1: Vendor the proto source**

```bash
mkdir -p Proto
cp ../chat-proto/WFCMessage.proto Proto/WFCMessage.proto
```

Confirm it copied correctly:
Run: `head -5 Proto/WFCMessage.proto`
Expected:
```
package im;
option java_package = "cn.wildfirechat.proto";
option java_outer_classname = "WFCMessage";

message ConnectAckPayload
```

- [ ] **Step 2: Get a codegen toolchain that does NOT touch the system `protoc`**

This repo's host already has a system `protoc` at `/usr/local/bin/protoc`, version **2.5.0** — pinned there because the sibling `chat-proto` repo's Java codegen pipeline requires exactly that version. Do not `brew install`/upgrade it; a 2.5.0-vs-modern mismatch was confirmed in practice to make `protoc-gen-swift` crash (SIGILL) when fed a `CodeGeneratorRequest` built by protoc 2.5 — the plugin wire format isn't compatible across that big a version gap. Everything below is scoped to this repo only and never modifies `/usr/local/bin/protoc`.

1. Build `protoc-gen-swift` from the `swift-protobuf` SPM dependency already checked out by `swift build` in Task 1:
   ```bash
   cd .build/checkouts/swift-protobuf
   swift build -c release --product protoc-gen-swift
   cd -
   find .build/checkouts/swift-protobuf/.build -name protoc-gen-swift -type f
   ```
   Expected: one path printed, e.g. `.build/checkouts/swift-protobuf/.build/<arch>-apple-macosx/release/protoc-gen-swift`.

2. Download a modern `protoc` binary, scoped to this repo, into a gitignored `.tools/` directory (never installed system-wide, never affects `/usr/local/bin/protoc`):
   ```bash
   mkdir -p .tools
   curl -sL -o .tools/protoc.zip \
     https://github.com/protocolbuffers/protobuf/releases/download/v35.1/protoc-35.1-osx-universal_binary.zip
   unzip -q -o .tools/protoc.zip -d .tools/protoc-35.1
   rm .tools/protoc.zip
   .tools/protoc-35.1/bin/protoc --version
   ```
   Expected: `libprotoc 35.1`. Add `.tools/` to `.gitignore` (the binaries should never be committed).

- [ ] **Step 3: Write the regeneration script**

The script resolves both tools from within the repo (building the plugin on demand if it's missing) and never touches anything outside this repo's `.build`/`.tools` directories or the system `protoc`.

```bash
#!/usr/bin/env bash
# Scripts/generate-proto.sh
# Regenerates Sources/IMProto/Generated/WFCMessage.pb.swift from Proto/WFCMessage.proto.
# Run this after chat-proto/WFCMessage.proto changes; commit the regenerated output.
#
# Uses a repo-local modern protoc (.tools/protoc-35.1) and a protoc-gen-swift
# plugin built from the swift-protobuf SPM checkout — NEVER the system protoc,
# which is intentionally pinned to 2.5.0 for the sibling chat-proto Java build
# and is binary-incompatible with this plugin (confirmed: SIGILL on a modern
# CodeGeneratorRequest payload).
set -euo pipefail
cd "$(dirname "$0")/.."

PROTOC_BIN="${PROTOC_BIN:-.tools/protoc-35.1/bin/protoc}"
if [ ! -x "$PROTOC_BIN" ]; then
  echo "error: $PROTOC_BIN not found. Run the Step 2 download commands first." >&2
  exit 1
fi

PROTOC_GEN_SWIFT="${PROTOC_GEN_SWIFT:-}"
if [ -z "$PROTOC_GEN_SWIFT" ]; then
  PROTOC_GEN_SWIFT="$(find .build/checkouts/swift-protobuf/.build -name protoc-gen-swift -type f 2>/dev/null | head -1)"
fi
if [ -z "$PROTOC_GEN_SWIFT" ] || [ ! -x "$PROTOC_GEN_SWIFT" ]; then
  echo "Building protoc-gen-swift from the swift-protobuf SPM checkout..."
  (cd .build/checkouts/swift-protobuf && swift build -c release --product protoc-gen-swift)
  PROTOC_GEN_SWIFT="$(find .build/checkouts/swift-protobuf/.build -name protoc-gen-swift -type f | head -1)"
fi
echo "Using protoc: $PROTOC_BIN"
echo "Using protoc-gen-swift plugin: $PROTOC_GEN_SWIFT"

mkdir -p Sources/IMProto/Generated
"$PROTOC_BIN" \
  --proto_path=Proto \
  --plugin=protoc-gen-swift="$PROTOC_GEN_SWIFT" \
  --swift_out=Sources/IMProto/Generated \
  --swift_opt=Visibility=Public \
  Proto/WFCMessage.proto
echo "Generated Sources/IMProto/Generated/WFCMessage.pb.swift"
```

Note: modern `protoc` (3.5+) supports the generic `--swift_opt=` flag used above. This would NOT have worked with the system protoc 2.5.0 (`Unknown flag: --swift_opt` — confirmed), which is exactly why Step 2 vendors a modern one rather than trying to make 2.5.0 work.

```bash
chmod +x Scripts/generate-proto.sh
```

- [ ] **Step 4: Run codegen**

Run: `./Scripts/generate-proto.sh`
Expected: prints `Generated Sources/IMProto/Generated/WFCMessage.pb.swift` and the file exists with a `import SwiftProtobuf` line near the top and a `public struct ConnectAckPayload` definition.

Verify:
Run: `grep -n "public struct Im_ConnectAckPayload" Sources/IMProto/Generated/WFCMessage.pb.swift`
Expected: one match.

**Naming note:** `WFCMessage.proto` declares `package im;`. SwiftProtobuf has no concept of Java-style packages, so it prefixes every generated type with the package name: `ConnectAckPayload` in the `.proto` becomes `Im_ConnectAckPayload` in Swift, `Message` becomes `Im_Message`, `Conversation` becomes `Im_Conversation`, and so on for every message in the file. This is standard SwiftProtobuf behavior, not a workaround — every future task (Plan B/C/D) that references a generated message type must use the `Im_`-prefixed name.

- [ ] **Step 5: Remove the Task 1 scaffold file now that real source exists**

```bash
rm -f Sources/IMProto/_Scaffold.swift
```

- [ ] **Step 6: Write a round-trip test proving the generated code actually encodes/decodes**

```swift
// Tests/IMProtoTests/ConnectAckPayloadCodingTests.swift
import XCTest
@testable import IMProto

final class ConnectAckPayloadCodingTests: XCTestCase {
    func test_roundTripBinarySerialization() throws {
        var payload = Im_ConnectAckPayload()
        payload.msgHead = 1001
        payload.friendHead = 5
        payload.friendRqHead = 2
        payload.settingHead = 9
        payload.serverTime = 1_750_000_000

        let bytes = try payload.serializedData()
        let decoded = try Im_ConnectAckPayload(serializedBytes: bytes)

        XCTAssertEqual(decoded.msgHead, 1001)
        XCTAssertEqual(decoded.friendHead, 5)
        XCTAssertEqual(decoded.friendRqHead, 2)
        XCTAssertEqual(decoded.settingHead, 9)
        XCTAssertEqual(decoded.serverTime, 1_750_000_000)
    }

    func test_optionalFieldsDefaultToZeroWhenAbsent() throws {
        var payload = Im_ConnectAckPayload()
        payload.msgHead = 1

        let bytes = try payload.serializedData()
        let decoded = try Im_ConnectAckPayload(serializedBytes: bytes)

        XCTAssertEqual(decoded.msgHead, 1)
        XCTAssertEqual(decoded.friendHead, 0)
        XCTAssertFalse(decoded.hasNodeAddr)
    }
}
```

- [ ] **Step 7: Run the tests**

Run: `swift test --filter ConnectAckPayloadCodingTests`
Expected: `Executed 2 tests, with 0 failures`

- [ ] **Step 8: Commit**

```bash
git add Proto Scripts Sources/IMProto Tests/IMProtoTests Package.resolved .gitignore
git commit -m "feat(IMProto): vendor WFCMessage.proto and generate SwiftProtobuf types"
```

---

## Task 3: `Signal` and `SubSignal` wire enums

These map 1:1 to the Java enum ordinals in `Signal.java` / `SubSignal.java` — the raw byte value on the wire is the enum's ordinal position, not anything semantic, so the Swift `rawValue` order below must match the Java declaration order exactly.

**Files:**
- Create: `Sources/IMTransport/Signal.swift`
- Create: `Sources/IMTransport/SubSignal.swift`
- Test: `Tests/IMTransportTests/SignalTests.swift`
- Test: `Tests/IMTransportTests/SubSignalTests.swift`

- [ ] **Step 1: Write the failing tests first**

```swift
// Tests/IMTransportTests/SignalTests.swift
import XCTest
@testable import IMTransport

final class SignalTests: XCTestCase {
    func test_rawValuesMatchAndroidOrdinals() {
        XCTAssertEqual(Signal.none.rawValue, 0)
        XCTAssertEqual(Signal.sub.rawValue, 1)
        XCTAssertEqual(Signal.auth.rawValue, 2)
        XCTAssertEqual(Signal.ping.rawValue, 3)
        XCTAssertEqual(Signal.push.rawValue, 4)
        XCTAssertEqual(Signal.contact.rawValue, 5)
        XCTAssertEqual(Signal.connect.rawValue, 6)
        XCTAssertEqual(Signal.connectAck.rawValue, 7)
        XCTAssertEqual(Signal.disconnect.rawValue, 8)
        XCTAssertEqual(Signal.publish.rawValue, 9)
        XCTAssertEqual(Signal.pubAck.rawValue, 10)
    }

    func test_outOfRangeRawValueIsNil() {
        XCTAssertNil(Signal(rawValue: 11))
    }
}
```

```swift
// Tests/IMTransportTests/SubSignalTests.swift
import XCTest
@testable import IMTransport

final class SubSignalTests: XCTestCase {
    func test_rawValuesMatchAndroidOrdinals() {
        XCTAssertEqual(SubSignal.none.rawValue, 0)
        XCTAssertEqual(SubSignal.connectionAccepted.rawValue, 1)
        XCTAssertEqual(SubSignal.connectionRefusedUnacceptableProtocolVersion.rawValue, 2)
        XCTAssertEqual(SubSignal.connectionRefusedIdentifierRejected.rawValue, 3)
        XCTAssertEqual(SubSignal.connectionRefusedServerUnavailable.rawValue, 4)
        XCTAssertEqual(SubSignal.connectionRefusedBadUserNameOrPassword.rawValue, 5)
        XCTAssertEqual(SubSignal.connectionRefusedNotAuthorized.rawValue, 6)
        XCTAssertEqual(SubSignal.connectionRefusedUnexpectNode.rawValue, 7)
        XCTAssertEqual(SubSignal.connectionRefusedSessionNotExist.rawValue, 8)
        XCTAssertEqual(SubSignal.us.rawValue, 9)
        XCTAssertEqual(SubSignal.far.rawValue, 10)
        XCTAssertEqual(SubSignal.upui.rawValue, 11)
        XCTAssertEqual(SubSignal.frn.rawValue, 12)
        XCTAssertEqual(SubSignal.frus.rawValue, 13)
        XCTAssertEqual(SubSignal.frp.rawValue, 14)
        XCTAssertEqual(SubSignal.fhr.rawValue, 15)
        XCTAssertEqual(SubSignal.fp.rawValue, 16)
        XCTAssertEqual(SubSignal.mn.rawValue, 17)
        XCTAssertEqual(SubSignal.ms.rawValue, 18)
        XCTAssertEqual(SubSignal.mp.rawValue, 19)
        XCTAssertEqual(SubSignal.fn.rawValue, 20)
        XCTAssertEqual(SubSignal.gc.rawValue, 21)
        XCTAssertEqual(SubSignal.gpgi.rawValue, 22)
        XCTAssertEqual(SubSignal.gpgm.rawValue, 23)
        XCTAssertEqual(SubSignal.gam.rawValue, 24)
        XCTAssertEqual(SubSignal.gkm.rawValue, 25)
        XCTAssertEqual(SubSignal.gq.rawValue, 26)
        XCTAssertEqual(SubSignal.gmi.rawValue, 27)
        XCTAssertEqual(SubSignal.mmi.rawValue, 28)
        XCTAssertEqual(SubSignal.gqnut.rawValue, 29)
        XCTAssertEqual(SubSignal.mr.rawValue, 30)
        XCTAssertEqual(SubSignal.rmn.rawValue, 31)
        XCTAssertEqual(SubSignal.lrm.rawValue, 32)
        XCTAssertEqual(SubSignal.gd.rawValue, 33)
        XCTAssertEqual(SubSignal.gmurl.rawValue, 34)
        XCTAssertEqual(SubSignal.fals.rawValue, 35)
        XCTAssertEqual(SubSignal.mrn.rawValue, 36)
        XCTAssertEqual(SubSignal.mrp.rawValue, 37)
        XCTAssertEqual(SubSignal.mrr.rawValue, 38)
        XCTAssertEqual(SubSignal.mdr.rawValue, 39)
        XCTAssertEqual(SubSignal.sai.rawValue, 40)
    }

    func test_outOfRangeRawValueIsNil() {
        XCTAssertNil(SubSignal(rawValue: 41))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail (types don't exist yet)**

Run: `swift test --filter SignalTests\|SubSignalTests`
Expected: FAIL with `error: cannot find type 'Signal' in scope` (and same for `SubSignal`)

- [ ] **Step 3: Implement `Signal`**

```swift
// Sources/IMTransport/Signal.swift

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
```

- [ ] **Step 4: Implement `SubSignal`**

```swift
// Sources/IMTransport/SubSignal.swift

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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter SignalTests\|SubSignalTests`
Expected: `Executed 4 tests, with 0 failures`

- [ ] **Step 6: Commit**

```bash
git add Sources/IMTransport/Signal.swift Sources/IMTransport/SubSignal.swift Tests/IMTransportTests/SignalTests.swift Tests/IMTransportTests/SubSignalTests.swift
git commit -m "feat(IMTransport): add Signal and SubSignal wire enums"
```

---

## Task 4: `Header` — 10-byte frame header codec

Byte layout (verified against `Header.java`):

```
offset 0    : magic, always 0xf8
offset 1    : version, always 0x02
offset 2    : signal ordinal, bit 7 reserved/always 0 in this codebase
offset 3-6  : body length, uint32 big-endian
offset 7    : subSignal ordinal, bit 7 reserved/always 0 in this codebase
offset 8-9  : messageId, uint16 big-endian, wraps at 65535
```

**Files:**
- Create: `Sources/IMTransport/Header.swift`
- Test: `Tests/IMTransportTests/HeaderTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IMTransportTests/HeaderTests.swift
import XCTest
@testable import IMTransport

final class HeaderTests: XCTestCase {
    func test_encodeProducesExactByteLayout() {
        let header = Header(signal: .connect, subSignal: .none, bodyLength: 42, messageId: 7)
        let bytes = [UInt8](header.encode())

        XCTAssertEqual(bytes, [
            0xf8,       // magic
            0x02,       // version
            0x06,       // Signal.connect ordinal
            0x00, 0x00, 0x00, 0x2a, // bodyLength = 42, big-endian
            0x00,       // SubSignal.none ordinal
            0x00, 0x07, // messageId = 7, big-endian
        ])
    }

    func test_decodeIsInverseOfEncode() {
        let original = Header(signal: .publish, subSignal: .ms, bodyLength: 1234, messageId: 65000)
        let decoded = Header.decode(original.encode())

        XCTAssertEqual(decoded, original)
    }

    func test_messageIdAtUpperBound() {
        let header = Header(signal: .ping, subSignal: .none, bodyLength: 0, messageId: 65535)
        let bytes = [UInt8](header.encode())
        XCTAssertEqual(bytes[8], 0xff)
        XCTAssertEqual(bytes[9], 0xff)
        XCTAssertEqual(Header.decode(header.encode())?.messageId, 65535)
    }

    func test_decodeRejectsWrongMagicByte() {
        var bytes = [UInt8](Header(signal: .ping, subSignal: .none, bodyLength: 0, messageId: 1).encode())
        bytes[0] = 0x00
        XCTAssertNil(Header.decode(Data(bytes)))
    }

    func test_decodeRejectsTooShortData() {
        XCTAssertNil(Header.decode(Data([0xf8, 0x02, 0x06])))
    }

    func test_decodeRejectsNoneSignal() {
        var bytes = [UInt8](Header(signal: .ping, subSignal: .none, bodyLength: 0, messageId: 1).encode())
        bytes[2] = Signal.none.rawValue
        XCTAssertNil(Header.decode(Data(bytes)))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter HeaderTests`
Expected: FAIL with `error: cannot find type 'Header' in scope`

- [ ] **Step 3: Implement `Header`**

```swift
// Sources/IMTransport/Header.swift
import Foundation

/// The fixed 10-byte frame header used by every message on the wire.
/// Byte-for-byte port of `com.comsince.github.push.Header`.
public struct Header: Equatable {
    public static let length = 10
    public static let magicByte: UInt8 = 0xf8
    public static let version: UInt8 = 2

    public let signal: Signal
    public let subSignal: SubSignal
    public let bodyLength: UInt32
    public let messageId: UInt16

    public init(signal: Signal, subSignal: SubSignal, bodyLength: UInt32, messageId: UInt16) {
        self.signal = signal
        self.subSignal = subSignal
        self.bodyLength = bodyLength
        self.messageId = messageId
    }

    public func encode() -> Data {
        var bytes = [UInt8](repeating: 0, count: Header.length)
        bytes[0] = Header.magicByte
        bytes[1] = Header.version
        bytes[2] = signal.rawValue
        bytes[3] = UInt8((bodyLength >> 24) & 0xff)
        bytes[4] = UInt8((bodyLength >> 16) & 0xff)
        bytes[5] = UInt8((bodyLength >> 8) & 0xff)
        bytes[6] = UInt8(bodyLength & 0xff)
        bytes[7] = subSignal.rawValue
        bytes[8] = UInt8((messageId >> 8) & 0xff)
        bytes[9] = UInt8(messageId & 0xff)
        return Data(bytes)
    }

    public static func decode(_ data: Data) -> Header? {
        guard data.count >= length else { return nil }
        let bytes = [UInt8](data.prefix(length))
        guard bytes[0] == magicByte else { return nil }
        guard let signal = Signal(rawValue: bytes[2] & 0x7f), signal != .none else { return nil }
        let subSignal = SubSignal(rawValue: bytes[7] & 0x7f) ?? .none
        let bodyLength = (UInt32(bytes[3]) << 24) | (UInt32(bytes[4]) << 16) | (UInt32(bytes[5]) << 8) | UInt32(bytes[6])
        let messageId = (UInt16(bytes[8]) << 8) | UInt16(bytes[9])
        return Header(signal: signal, subSignal: subSignal, bodyLength: bodyLength, messageId: messageId)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter HeaderTests`
Expected: `Executed 6 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/IMTransport/Header.swift Tests/IMTransportTests/HeaderTests.swift
git commit -m "feat(IMTransport): add Header frame codec"
```

---

## Task 5: `Frame` + incremental `FrameDecoder`

TCP delivers an arbitrary stream of bytes — a single `read` can contain half a header, a header plus partial body, multiple complete frames, or any combination. `FrameDecoder` buffers incoming bytes and emits only fully-formed frames.

**Files:**
- Create: `Sources/IMTransport/Frame.swift`
- Create: `Sources/IMTransport/FrameDecoder.swift`
- Test: `Tests/IMTransportTests/FrameDecoderTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IMTransportTests/FrameDecoderTests.swift
import XCTest
@testable import IMTransport

final class FrameDecoderTests: XCTestCase {
    private func makeFrameBytes(signal: Signal, subSignal: SubSignal, messageId: UInt16, body: [UInt8]) -> Data {
        let header = Header(signal: signal, subSignal: subSignal, bodyLength: UInt32(body.count), messageId: messageId)
        return header.encode() + Data(body)
    }

    func test_singleCompleteFrameInOneChunk() {
        let decoder = FrameDecoder()
        let bytes = makeFrameBytes(signal: .ping, subSignal: .none, messageId: 1, body: [0x7b, 0x7d]) // "{}"

        let frames = decoder.feed(bytes)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].header.signal, .ping)
        XCTAssertEqual(frames[0].body, Data([0x7b, 0x7d]))
    }

    func test_frameSplitAcrossManyChunksByteByByte() {
        let decoder = FrameDecoder()
        let bytes = makeFrameBytes(signal: .connect, subSignal: .none, messageId: 2, body: Array("hello".utf8))

        var collected: [Frame] = []
        for byte in bytes {
            collected += decoder.feed(Data([byte]))
        }

        XCTAssertEqual(collected.count, 1)
        XCTAssertEqual(collected[0].header.signal, .connect)
        XCTAssertEqual(collected[0].body, Data("hello".utf8))
    }

    func test_multipleCompleteFramesInOneChunk() {
        let decoder = FrameDecoder()
        var combined = makeFrameBytes(signal: .ping, subSignal: .none, messageId: 1, body: [0x01])
        combined.append(makeFrameBytes(signal: .pubAck, subSignal: .ms, messageId: 2, body: [0x02, 0x03]))
        combined.append(makeFrameBytes(signal: .disconnect, subSignal: .none, messageId: 3, body: []))

        let frames = decoder.feed(combined)

        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames[0].header.messageId, 1)
        XCTAssertEqual(frames[1].header.signal, .pubAck)
        XCTAssertEqual(frames[1].body, Data([0x02, 0x03]))
        XCTAssertEqual(frames[2].header.signal, .disconnect)
        XCTAssertEqual(frames[2].body, Data())
    }

    func test_partialHeaderThenRestArrivesLater() {
        let decoder = FrameDecoder()
        let bytes = makeFrameBytes(signal: .auth, subSignal: .none, messageId: 9, body: [0xaa, 0xbb, 0xcc])

        let firstChunkFrames = decoder.feed(bytes.prefix(4))
        XCTAssertEqual(firstChunkFrames.count, 0)

        let secondChunkFrames = decoder.feed(bytes.suffix(from: 4))
        XCTAssertEqual(secondChunkFrames.count, 1)
        XCTAssertEqual(secondChunkFrames[0].body, Data([0xaa, 0xbb, 0xcc]))
    }

    func test_completeHeaderButPartialBodyThenRest() {
        let decoder = FrameDecoder()
        let bytes = makeFrameBytes(signal: .push, subSignal: .none, messageId: 4, body: Array(0..<20))

        let firstChunkFrames = decoder.feed(bytes.prefix(Header.length + 5))
        XCTAssertEqual(firstChunkFrames.count, 0)

        let secondChunkFrames = decoder.feed(bytes.suffix(from: Header.length + 5))
        XCTAssertEqual(secondChunkFrames.count, 1)
        XCTAssertEqual(secondChunkFrames[0].body, Data(Array(0..<20)))
    }

    func test_invalidMagicByteDropsBufferRatherThanLoopingForever() {
        let decoder = FrameDecoder()
        let garbage = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09])

        let frames = decoder.feed(garbage)

        XCTAssertEqual(frames.count, 0)
        // decoder must have discarded the garbage, not be stuck waiting on it forever
        let nextFrames = decoder.feed(makeFrameBytes(signal: .ping, subSignal: .none, messageId: 1, body: []))
        XCTAssertEqual(nextFrames.count, 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter FrameDecoderTests`
Expected: FAIL with `error: cannot find type 'FrameDecoder' in scope`

- [ ] **Step 3: Implement `Frame`**

```swift
// Sources/IMTransport/Frame.swift
import Foundation

/// A fully-decoded wire frame: header plus its complete body bytes.
public struct Frame: Equatable {
    public let header: Header
    public let body: Data

    public init(header: Header, body: Data) {
        self.header = header
        self.body = body
    }
}
```

- [ ] **Step 4: Implement `FrameDecoder`**

```swift
// Sources/IMTransport/FrameDecoder.swift
import Foundation

/// Buffers a raw incoming byte stream and emits complete `Frame`s as they
/// become available. Not thread-safe — callers must serialize access
/// (the owning `NWConnection` receive queue in IMClient does this).
///
/// Buffer is a plain `[UInt8]` rather than `Data` on purpose: `Data` does not
/// guarantee `startIndex == 0` after slicing/`removeSubrange`, which makes
/// absolute-offset indexing unsafe. `Array`'s `startIndex` is always `0`.
public final class FrameDecoder {
    private var buffer: [UInt8] = []

    public init() {}

    /// Feed newly-received bytes; returns zero or more frames that became
    /// complete as a result. Safe to call repeatedly with arbitrarily-sized
    /// chunks, including single bytes or many frames at once.
    public func feed(_ data: Data) -> [Frame] {
        buffer.append(contentsOf: data)
        var frames: [Frame] = []

        while true {
            guard buffer.count >= Header.length else { break }

            guard let header = Header.decode(Data(buffer.prefix(Header.length))) else {
                // Bad magic byte: the stream is desynchronized. There is no
                // safe resync point, so drop everything buffered so far
                // rather than spinning on the same invalid bytes forever.
                buffer.removeAll()
                break
            }

            let totalLength = Header.length + Int(header.bodyLength)
            guard buffer.count >= totalLength else { break }

            let body = Data(buffer[Header.length..<totalLength])
            frames.append(Frame(header: header, body: body))
            buffer.removeFirst(totalLength)
        }

        return frames
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter FrameDecoderTests`
Expected: `Executed 6 tests, with 0 failures`

- [ ] **Step 6: Commit**

```bash
git add Sources/IMTransport/Frame.swift Sources/IMTransport/FrameDecoder.swift Tests/IMTransportTests/FrameDecoderTests.swift
git commit -m "feat(IMTransport): add Frame and incremental FrameDecoder"
```

---

## Task 6: `FrameEncoder` convenience + full-stack round-trip test

**Files:**
- Create: `Sources/IMTransport/FrameEncoder.swift`
- Test: `Tests/IMTransportTests/FrameEncoderTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/IMTransportTests/FrameEncoderTests.swift
import XCTest
@testable import IMTransport

final class FrameEncoderTests: XCTestCase {
    func test_encodeThenDecodeRoundTripsThroughFrameDecoder() {
        let body = Data("{\"interval\":30000}".utf8)
        let wireBytes = FrameEncoder.encode(signal: .ping, subSignal: .none, messageId: 17, body: body)

        let decoder = FrameDecoder()
        let frames = decoder.feed(wireBytes)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].header.signal, .ping)
        XCTAssertEqual(frames[0].header.subSignal, .none)
        XCTAssertEqual(frames[0].header.messageId, 17)
        XCTAssertEqual(frames[0].body, body)
    }

    func test_encodedByteCountIsHeaderLengthPlusBodyLength() {
        let body = Data([1, 2, 3, 4, 5])
        let wireBytes = FrameEncoder.encode(signal: .publish, subSignal: .ms, messageId: 1, body: body)
        XCTAssertEqual(wireBytes.count, Header.length + body.count)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FrameEncoderTests`
Expected: FAIL with `error: cannot find 'FrameEncoder' in scope`

- [ ] **Step 3: Implement `FrameEncoder`**

```swift
// Sources/IMTransport/FrameEncoder.swift
import Foundation

/// Builds the on-the-wire bytes for a single message: header followed by body.
public enum FrameEncoder {
    public static func encode(signal: Signal, subSignal: SubSignal, messageId: UInt16, body: Data) -> Data {
        let header = Header(signal: signal, subSignal: subSignal, bodyLength: UInt32(body.count), messageId: messageId)
        return header.encode() + body
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter FrameEncoderTests`
Expected: `Executed 2 tests, with 0 failures`

- [ ] **Step 5: Run the full test suite for both targets**

Run: `swift test`
Expected: all tests across `IMProtoTests` and `IMTransportTests` pass, e.g. `Executed 20 tests, with 0 failures`

- [ ] **Step 6: Commit**

```bash
git add Sources/IMTransport/FrameEncoder.swift Tests/IMTransportTests/FrameEncoderTests.swift
git commit -m "feat(IMTransport): add FrameEncoder and round-trip test"
```

---

## Plan Self-Review Notes

- **Spec coverage:** This plan implements design doc §5.1 (binary frame protocol) in full, and the `IMProto` portion of §4 (code organization). §5.2–§5.6 (heartbeat, reconnect, login/AES handshake, handler dispatch) are explicitly out of scope — they belong to Plan B (`IMClient`), which depends on the two targets built here.
- **Flag bit (bit 7 of offset 2 and offset 7):** Android's `Header.java` reserves this bit but no caller in the codebase ever sets it to `1`. This plan's `Header` always encodes it as `0` and masks it off on decode, matching observed runtime behavior. If Plan B's real-traffic testing against `chat-server-pro` ever reveals a server response with that bit set, `Header` will need a documented follow-up change — flagged here rather than silently assumed away.
- **No placeholders:** every step above has complete, runnable code; nothing is left as "TODO" or "similar to above."
- **Unbounded frame body size (flagged during Task 5 code review, deliberately deferred):** `FrameDecoder` has no maximum on `Header.bodyLength` — a header claiming a multi-gigabyte body makes `feed` buffer indefinitely while waiting for bytes that may never arrive, which is an unbounded-memory-growth risk against a live, possibly-adversarial socket. Checked the Android source (`push-sdk`, `client/proto`, and `chat-server-pro`) for an existing cap to mirror: **none exists** — the original implementation doesn't bound this either, so this isn't a regression, but it's also not something to silently leave unaddressed. This is explicitly **out of scope for Plan A** (a pure framing layer with no policy decisions) and is **Plan B's responsibility** to address deliberately — e.g. a `maxBodyLength` parameter on `FrameDecoder` (treating an oversized header the same as a bad-magic-byte: drop and resync) with a cap chosen from real data (actual max message/attachment size in `chat-server-pro` config) rather than an arbitrary guess. Plan B's task list must include this explicitly — do not let it fall through the crack between "Plan A says it's not my problem" and "Plan B assumed Plan A handled it." The same Plan B work should also close the symmetric encode-side gap: `FrameEncoder.encode`'s `UInt32(body.count)` traps for a body ≥ 4 GiB (flagged in Task 6 code review) — add the same `maxBodyLength` guard to both the encode and decode paths together.
