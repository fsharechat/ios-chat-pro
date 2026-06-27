# ios-chat-pro

基于自研 IM 协议的 iOS 即时通讯客户端，使用 Swift + UIKit 开发，对接 [chat-server-pro](https://github.com/fshare/chat-server-pro) 后端。

## 主要功能

- **单聊 & 群聊**：文字、图片、语音、文件消息收发，支持消息撤回
- **音视频通话**：基于 WebRTC（stasel/WebRTC）的一对一音频 & 视频通话，集成 CallKit
- **联系人管理**：好友搜索、好友申请、通讯录同步
- **群组管理**：创建群组、邀请成员、修改群公告、群二维码、收藏群
- **消息存储**：本地 SQLite（GRDB）持久化，增量消息同步
- **主题切换**：浅色 / 深色 / 跟随系统
- **媒体上传**：图片、语音、文件通过 MinIO 预签名 URL 上传

## 技术栈

| 层次 | 技术 |
|---|---|
| 语言 | Swift 5.8+，iOS 15+ |
| 网络传输 | NWConnection（TCP 自定义帧协议） |
| 序列化 | Protocol Buffers（swift-protobuf） |
| 本地存储 | SQLite via GRDB 6 |
| 音视频 | WebRTC（stasel/WebRTC@149.0.0） |
| 响应式 | Combine（ViewModels 层） |
| 工程管理 | XcodeGen（`project.yml` → `.xcodeproj`） |

## 环境要求

- Xcode 15+
- iOS 15+ 设备 / 模拟器
- Swift 5.8+
- macOS 12+（开发机）

## 安装与编译

### 1. 克隆仓库

```bash
git clone https://github.com/fshare/ios-chat-pro.git
cd ios-chat-pro
```

### 2. 生成 Xcode 工程

```bash
bash Scripts/generate-xcodeproj.sh
```

首次运行会自动下载 XcodeGen 工具到 `.tools/`，无需 Homebrew。

### 3. 用 Xcode 打开并运行

```bash
open ios-chat-pro.xcodeproj
```

在 Xcode 中选择 **App** scheme，选择目标设备，按 ▶️ 运行。

> **注意：** 音视频通话功能（麦克风 / 摄像头）必须在真机上测试，模拟器不支持媒体采集。

### 命令行编译

```bash
xcodebuild \
  -project ios-chat-pro.xcodeproj \
  -scheme App \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  build
```

## 测试

项目核心逻辑（`IMCore` Swift Package）有完整的单元测试，无需 Xcode 即可运行：

```bash
# 运行全部单元测试
swift test

# 运行指定模块测试
swift test --filter IMStorageTests
swift test --filter IMClientTests
swift test --filter IMMessagingTests
swift test --filter IMProtoTests
swift test --filter IMGroupsTests
swift test --filter IMCallTests

# 运行单个测试方法
swift test --filter IMStorageTests/MessageStoreTests/testInsertAndFetch
```

各模块测试目录位于 `Tests/<模块名>Tests/`。

## 服务器配置

生产服务器配置集中在 `Sources/AppCore/AppConfig.swift`：

```swift
public static let production = AppConfig(
    apiBaseURL: URL(string: "https://backend-http.fsharechat.cn")!,
    imHosts: "backend-tcp.fsharechat.cn:backend-tcp-s2.fsharechat.cn",
    imPort: 6789,
    iceServers: [ /* TURN 服务器 */ ]
)
```

修改此文件即可切换到自部署服务器。

## 代码结构

```
ios-chat-pro/
├── App/                        # UIKit ViewControllers & Views
│   ├── SceneDelegate.swift     # 应用入口，构建 AppEnvironment
│   ├── ConversationListViewController.swift
│   ├── ConversationViewController.swift
│   ├── GroupInfoViewController.swift
│   └── ...
├── Sources/                    # Swift Package 核心模块
│   ├── IMProto/                # Protobuf 生成代码
│   ├── IMTransport/            # TCP 帧传输
│   ├── IMClient/               # 连接生命周期、登录、心跳
│   ├── IMStorage/              # SQLite 存储（GRDB）
│   ├── IMMessaging/            # 消息收发
│   ├── IMContacts/             # 联系人同步
│   ├── IMGroups/               # 群组管理
│   ├── IMMedia/                # 媒体上传
│   ├── IMCall/                 # WebRTC 音视频
│   ├── IMKit/                  # Combine ViewModels
│   └── AppCore/                # 依赖容器 & 配置
├── Tests/                      # 各模块单元测试
├── Proto/                      # WFCMessage.proto 源文件
├── Scripts/
│   ├── generate-xcodeproj.sh   # 从 project.yml 生成 .xcodeproj
│   └── generate-proto.sh       # 从 .proto 生成 Swift 代码
├── project.yml                 # XcodeGen 工程描述
└── Package.swift               # Swift Package 声明
```

## Proto 代码生成

修改 `Proto/WFCMessage.proto` 后需重新生成：

```bash
bash Scripts/generate-proto.sh
```

生成结果 `Sources/IMProto/Generated/WFCMessage.pb.swift` 需提交到仓库。  
脚本使用仓库本地的 `protoc`（`.tools/protoc-35.1/`），不依赖系统 `protoc`。

## 相关项目

- [chat-server-pro](https://github.com/fshare/chat-server-pro) — 服务端
- [android-chat-pro](https://github.com/fshare/android-chat-pro) — Android 客户端
