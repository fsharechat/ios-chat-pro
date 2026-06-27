# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> **语言约定：** 所有回复统一使用中文。

## 构建与运行

### 生成 Xcode 工程

`ios-chat-pro.xcodeproj` 由 XcodeGen 从 `project.yml` 生成，不要手工编辑 `.xcodeproj`：

```bash
bash Scripts/generate-xcodeproj.sh
```

首次运行会自动下载 xcodegen 二进制到 `.tools/`。

### 编译 App

```bash
xcodebuild -project ios-chat-pro.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' build
```

### 运行 SPM 单元测试

```bash
# 全部测试
swift test

# 单个模块
swift test --filter IMStorageTests
swift test --filter IMClientTests

# 单个测试用例
swift test --filter IMStorageTests/MessageStoreTests/testXxx
```

### 重新生成 Protobuf 代码

`.proto` 文件改动后：

```bash
bash Scripts/generate-proto.sh
```

输出写入 `Sources/IMProto/Generated/`，结果需要提交。  
**不要** 使用系统 `protoc`（版本钉死在 2.5.0 供兄弟项目使用，与本插件不兼容）。

---

## 模块架构

整个代码库是一个 Swift Package（`Package.swift`，包名 `IMCore`），外加一个 iOS App target（通过 `project.yml` 管理）。层次从底到顶：

```
IMProto         Protobuf 生成代码（WFCMessage.pb.swift）
IMTransport     TCP 帧传输（NWConnection）：Frame / FrameDecoder / FrameEncoder
IMClient        连接生命周期：登录握手(AES)、心跳、断线重连（最多4次+退避）
IMStorage       SQLite（GRDB）存储门面：MessageStore / ConversationStore /
                UserStore / GroupStore / FriendRequestStore / SyncStateStore
IMMessaging     消息收发：MessagingService + 各 Handler（send/receive/recall/notify）
IMContacts      好友 & 好友申请同步
IMGroups        群组管理：创建/同步/成员变更
IMMedia         媒体上传：MinIO 预签名 URL 方案
IMCall          WebRTC 音视频通话（stasel/WebRTC@149.0.0 pinned exact）
IMKit           UIKit-agnostic ViewModels（Combine），供 App target 绑定
AppCore         依赖容器 AppEnvironment + AppConfig（服务器地址/ICE 配置）
App             UIKit ViewControllers，入口为 SceneDelegate
```

**依赖方向严格单向**，较低层不得反向引用较高层。

### 关键设计约定

- **线程模型：无内部锁，全部从主队列调用。** `IMClient`、`MessagingService`、`AppEnvironment` 等均无锁，调用方必须在主队列上操作。
- **AppEnvironment** 是唯一的依赖容器。`SceneDelegate` 持有它；所有 ViewController 通过闭包或初始化参数接收所需服务，不使用单例。
- **IMStorage** 是存储门面，生产代码只能通过六个 store 访问，不暴露裸 `DatabaseQueue`（测试有 `dbQueueForTesting` 逃生口）。
- **IMKit ViewModels** 通过 GRDB 的 `ValueObservation`/`Publisher` 驱动，直接监听数据库变更，无需额外通知机制。
- **ConnectAck** 触发增量消息拉取（`pullMessagesSinceLastSync`）+ 联系人 & 群组同步，入口在 `AppEnvironment.connectIfPossible()`。

### 生产服务器

- HTTP API：`https://backend-http.fsharechat.cn`
- IM TCP：`backend-tcp.fsharechat.cn:6789`（主）/ `backend-tcp-s2.fsharechat.cn:6789`（备）
- 配置统一在 `AppCore/AppConfig.swift` 的 `AppConfig.production`。

### proto 与代码生成

- proto 源文件：`Proto/WFCMessage.proto`
- 生成输出：`Sources/IMProto/Generated/WFCMessage.pb.swift`
- 工具链：`.tools/protoc-35.1/bin/protoc` + SPM checkout 内的 `protoc-gen-swift`

---

## 常见改动模式

| 改动类型 | 影响范围 |
|---|---|
| 新增消息类型 | `IMProto`（proto） → `IMStorage`（枚举/表字段） → `IMMessaging`（Handler） → `IMKit`（ViewModel/Row） → `App`（Cell/VC） |
| 新增群组能力 | `IMGroups` → `IMKit` → `GroupInfoViewController` |
| 修改存储 schema | `IMStorage` 中对应 store 的 `createTable` 迁移块，同步更新 `Stored*` 模型 |
| 修改服务器地址 | 仅改 `AppCore/AppConfig.swift` |
| 修改 Xcode 工程配置 | 只改 `project.yml`，然后运行 `generate-xcodeproj.sh` |
