# ios-chat-pro 迁移架构设计

日期:2026-06-17

## 1. 背景

`android-chat-pro`(飞享 IM)是基于自定义 Java NIO TCP 协议、protobuf 二进制消息(`chat-proto`)与 `chat-server-pro`(push-connector / push-group / push-api 三服务架构)的即时通讯客户端,支持私聊、群聊、一对一音视频通话、频道订阅等功能。

`ios-chat-pro` 的目标是用 Swift 原生重新实现同一套客户端能力,复用现有协议与服务端,不修改服务端(APNs 推送除外,见 §8)。

本设计文档覆盖:**总体架构 + 全量迁移路线图**,并对 **Phase 1(MVP)** 给出详细设计。Phase 2 及之后只做模块级规划,留待各自单独 brainstorm → plan。

## 2. 范围与路线图

| 阶段 | 范围 | 状态 |
|---|---|---|
| Phase 1(MVP) | 登录注册 → TCP 长连接/心跳/重连 → protobuf 编解码 → 本地存储 → 会话列表 → 单聊(文本+图片) → 联系人列表(静态展示) | 本文档详细设计 |
| Phase 2 | 群聊(创建/成员管理/群消息)、好友管理(申请/通过/删除) | 仅模块级规划,待后续单独 brainstorm |
| Phase 3 | 音视频通话(WebRTC,对应 Android `p2penginekit`/`avenginekit`) | 仅模块级规划 |
| Phase 4 | 频道/订阅号、二维码加好友、全局搜索、设置/换肤、APNs 推送(需服务端小幅适配) | 仅模块级规划 |

每个阶段独立走 spec → plan → implementation → review 流程,不会一次性产出所有模块的详细实现计划。

## 3. 技术栈

| 维度 | 选择 | 备注 |
|---|---|---|
| UI 框架 | UIKit 为主 | 少量场景(如摄像头预览)可后续按需引入 SwiftUI 桥接,但 Phase 1 不涉及 |
| 架构模式 | MVVM + Combine | ViewModel 暴露 `@Published`,ViewController 通过 Combine `sink` 订阅刷新 UI |
| 异步模型 | `async/await`(网络层、数据层)+ Combine(UI 绑定层) | |
| 本地存储 | GRDB.swift(SQLite) | 对应 Android `SqliteDatabaseStore` |
| 网络层 | `Network.framework`(`NWConnection`)+ 自实现帧解析 | 无第三方网络依赖 |
| 协议序列化 | SwiftProtobuf 官方库 | 从 `chat-proto/*.proto`(proto2 语法)生成,与 Android `protoc --java_out` 对齐 |
| 最低支持版本 | iOS 15+ | |
| 依赖管理 | Swift Package Manager | |
| 代码组织 | 本地 SPM 包 + 单 App 主面板 | |

## 4. 代码组织

```
ios-chat-pro/
├── App/                      # 主 App target:页面组装、启动流程、AppDelegate/SceneDelegate
├── Packages/
│   ├── IMTransport/          # 对应 push-sdk:NWConnection 封装、二进制帧编解码、字节缓冲
│   ├── IMProto/              # 对应 chat-proto:SwiftProtobuf 生成代码 + .proto 源文件
│   ├── IMClient/             # 对应 client:连接生命周期、心跳、重连、消息分发、Handler 注册表
│   ├── IMStorage/            # 对应 store/:GRDB 数据库、消息/会话/联系人模型与 DAO
│   ├── IMKit/                # 对应 chat/kit:UI 组件 — 会话列表、聊天界面、联系人(ViewModel+VC)
│   ├── EmojiKit/              # 对应 emojilibrary
│   └── MediaPickerKit/       # 对应 imagepicker
└── ios-chat-pro.xcodeproj
```

依赖方向单向:`IMKit → IMClient → IMTransport`;`IMClient/IMKit → IMStorage`;`IMTransport/IMClient → IMProto`。App target 只做组装,不写业务逻辑。Phase 1 实际只需要 `IMTransport`/`IMProto`/`IMClient`/`IMStorage`/`IMKit` 五个包;`EmojiKit`/`MediaPickerKit` 在 Phase 1 中 `IMKit` 的图片消息发送需要用到基础的系统相册选择能力,先用 `PHPickerViewController` 直接满足,不创建独立包,留到功能更丰富时(贴纸/裁剪等)再拆出 `MediaPickerKit`。

## 5. 网络与协议层架构(`IMTransport` + `IMProto` + `IMClient`)

### 5.1 二进制帧协议

逐字节复刻 Android `push-sdk` 的 `Header`:

```
┌────────┬─────────┬────────┬───────────────┬───────────┬──────────────────┐
│ Magic  │ Version │ Signal │ Length(4B,BE) │ SubSignal │ MessageId(2B,BE) │
│ 0xf8   │   2     │  1B    │  body 字节长度 │    1B     │  循环 0~65535     │
└────────┴─────────┴────────┴───────────────┴───────────┴──────────────────┘
```
10 字节固定头 + 可变长 body。`PING`/`CONNECT` 等信令的 body 是 JSON 字符串,`PUBLISH`/`PUB_ACK` 的 body 是 protobuf 二进制。Signal/SubSignal 用 `enum: UInt8`,序号与 Java 端枚举顺序一一对应,直接从 `Header.java` 移植,不重新编号。

iOS 侧用 `NWConnection` 接收字节流,实现一个 `FrameDecoder` 状态机(等待 10 字节头 → 解析 Length → 等待 body 凑齐 → 产出完整帧),逐帧上抛给 `IMClient`。需要处理 TCP 粘包/半包/一次读取多帧的情况。

### 5.2 心跳(`HeartbeatManager`)

自适应算法,移植自 Android:
- 初始/最小间隔 30s,步长 5s
- 白天(7:00–22:00)上限 60s,夜间上限 120s
- 心跳响应成功累计达到 `当前间隔/步长` 次后,间隔上调一档(+5s)
- 心跳失败时按"实际超时与计划时间的偏差"分档回退:偏差 <10s 减 5s;10–20s 减偏差的一半;20–60s 减 10s;≥60s 减 20s 且暂停上调探测
- 间隔下限 15s,上限为当前时段上限
- 间隔 >45s 时引入随机抖动,避免大量客户端心跳同步打到服务端
- 编码为 `Signal.PING`,body 为 `{"interval": <毫秒数>}` JSON

### 5.3 重连与集群

- `IM_SERVER_HOST` 配置多个域名,以 `:` 分隔
- `RoundRobinHostSelector`:每次取下一个连接目标,按数组下标轮询(取模回绕),非随机
- 断线重连退避:`delay = min(reconnectNum, 3) × 2s`(即 2/4/6/6...s 递增到封顶),连接成功后 `reconnectNum` 归零
- 心跳响应超时 5s 触发 `forceConnect()` 强制重连

### 5.4 登录与建连流程

```
HTTP POST /send_code  {mobile}                  → {"code":0,"message":"success","result":true}
HTTP POST /login      {mobile, code, clientId}   → {"code":0,"message":"success","result":{"userId":"...","token":"...","register":false}}
  (响应外层是 RestResult 包装:code/message/result,不是 code/data;以 chat-server-pro 的
   LoginController/LoginResponse/RestResult 源码为准,Plan B 实现时已按此修正)

token 解析(必须与服务端字节级对齐,已在 Plan B 用真实 Java AES 实现生成的字节向量验证通过):
  1. Base64 解码 token
  2. AES/CBC/PKCS7 解密(默认内置 key,IV=key)→ 得到形如 "password(base64)|secret|其他" 的管道分隔字符串(不是 JSON),按 "|" 取出 password、secret 两段
  3. 用 secret 派生 key(取前16字符按字节截断),对 password 的字节做 AES/CBC/PKCS7 加密 → Base64 编码 → 得到 TCP 连接密码

TCP  Signal.CONNECT     {userName: userId, password: 上一步算出的密码, clientIdentifier: 设备标识}
TCP  Signal.CONNECT_ACK → ConnectAckPayload{msg_head, friend_head, friend_rq_head, setting_head, server_time, node_addr?, node_port?}
                          (后续按各 head 序号向服务端发起增量拉取,同步消息/好友/设置)
```

iOS 端用 CryptoKit/CommonCrypto 实现等价的 AES 模式;具体的 mode(ECB/CBC)与 padding 需要在实现阶段对照 Android `AES.java` 源码逐字节验证后再编码进 `IMClient`,不能凭推测实现。

### 5.5 消息去重(local_message_id)

客户端发送消息时在 `PUBLISH` 帧中附带本地生成的 `local_message_id`;服务端在 `PUB_ACK` 与后续推送中回传同一个值。客户端用它匹配本地未确认消息记录,断线重连后避免重复插入,只需要把本地记录的状态更新为"已确认"并补上服务端分配的 `message_id`。此特性要求服务端版本 ≥ 2.2.0,Phase 1 启动前需确认 `chat-server-pro` 部署版本满足要求。

### 5.6 Handler 架构

每个服务端消息类型对应一个 `MessageHandler`,与 Android `client/handler/` 一一移植,职责单一、可独立单测:`ReceiveMessageHandler`、`SendMessageHandler`、`RecallMessageHandler`、`DeliveryReportHandler`、`ReadReportHandler`、`ConnectAckMessageHandler` 等。`IMClient` 维护一个 `[SubSignal: MessageHandler]` 注册表,收到帧后按 SubSignal 路由。

## 6. 数据层架构(`IMStorage`)

GRDB 数据库,启动时执行迁移脚本(对应 Android `SqliteDatabaseStore` 表结构):

- **messages**:`message_uid`(服务端ID)、`local_message_id`、`conversation_type`、`target`、`line`、`from`、`content_type`、`content`、`timestamp`、`status`(发送中/成功/失败/已读)、`direction`
  - 索引:`(conversation_type, target, line, timestamp)` 用于会话内分页拉取;`(local_message_id)` 用于去重匹配
- **conversations**:`(type, target, line)` 复合主键、`last_message_uid`、`unread_count`、`top`、`mute`、`draft`
- **users / groups / group_members**:联系人与群组静态信息缓存
- **sync_state**:存 `msg_head/friend_head/friend_rq_head/setting_head`,对应 `ConnectAckPayload` 返回值,作为断线重连后增量同步的起点

数据流向:
```
NWConnection 收到帧 → IMClient 按 SubSignal 分发到 MessageHandler(纯逻辑,无 UI 依赖)
  → Handler 写入 GRDB(IMStorage)
  → IMStorage 用 GRDB ValueObservation 发出变更通知
  → ViewModel 把 ValueObservation 桥接为 Combine Publisher → 更新 @Published 属性
  → ViewController 通过 Combine sink 刷新 UI
```

## 7. Phase 1 业务/UI 架构(`IMKit`)

| 模块 | 对应 Android | 说明 |
|---|---|---|
| `LoginViewController` | `app/login` | 手机号 + 验证码登录,登录成功后触发 `IMClient` 建连 |
| `ConversationListViewController` | `kit/conversationlist` | `UITableView` + `UITableViewDiffableDataSource`,订阅 `conversations` 表变更 |
| `ConversationViewController` | `kit/conversation` | 消息流(`UICollectionView` + Compositional Layout)、输入栏、文本/图片消息气泡、发送/接收/已读状态 |
| `ContactListViewController` | `kit/contact`(Phase 1 仅静态展示) | 联系人列表 + 索引字母条,数据来自登录后一次性拉取,不支持增删 |

## 8. 视觉设计方向

通过浏览器可视化对比三个候选风格(暖调人文风/北欧极简风/深色高对比风)后,确定方向:**深色高对比风,日间/夜间双主题对称设计**。

- **深色主题**:背景 `#14151A` 系做三级分层(导航栏/列表/卡片),强调色用荧光绿系(`#3DDC84`);自己发送的气泡用强调色填充配深色文字,对方气泡用 `#1F212B` 浅一级灰
- **日间主题**:同一套间距/圆角/字阶 token,背景换为纯白/浅灰分层,强调色保留同一色相但降低饱和度、提亮以避免刺眼
- **字体**:系统 San Francisco,不引入衬线字体;用字重和字号建立层级
- **强调色收紧使用范围**:仅用于未读徽标、发送气泡、主操作按钮、选中态,避免到处撒色造成廉价感
- **圆角/间距统一为设计 token**(头像圆形、气泡 14px、卡片/按钮统一来源),不允许不同界面各自发明数值

具体到每个界面的视觉细节,在 Phase 1 实现阶段按需调用 frontend-design 技能逐屏落地,本文档只定调色板与基调,不展开逐屏视觉稿。

## 9. 推送通知与服务端边界

Phase 1–3 客户端只需保证 App 在前台/TCP 连接保持时能正常收发消息,不依赖任何推送机制。

APNs 推送规划在 **Phase 4**:`chat-server-pro` 的 `push-api` 需要新增一个 APNs 推送适配通道,与现有小米/华为/魅族通道并列。这部分**服务端改动不属于"纯客户端迁移"范围**,是 Phase 4 单独要评估和实施的工作,不在本文档涉及的 Phase 1 范围内,也不在 Phase 1-3 的客户端实现中预留相关代码。

## 10. 测试策略

- `IMTransport`:帧编解码用固定字节数组做单测(取 Android 端真实抓包样本做夹具),覆盖粘包/半包/一次读取多帧拼接场景
- `IMClient`:心跳算法、重连退避、`RoundRobinHostSelector` 轮询逐一写纯逻辑单测,不依赖真实网络连接
- `IMStorage`:DAO 层用内存 SQLite 做单测,覆盖去重(`local_message_id` 匹配)、未读数统计、分页查询
- `IMKit`:ViewModel 层做单测(给定 mock 数据流,断言 `@Published` 输出变化);ViewController 层不强制覆盖,关键路径(发送/接收/已读)做一次手工走查
- **Phase 1 验收标准**:使用同一测试账号(`13800000000`/`13800000001`/`13800000002`,验证码 `556677`),iOS 与 Android 客户端互发文本/图片消息,双端都能正确收发、正确显示已读状态,断网重连后不丢消息、不重复插入消息

## 11. 风险与待确认事项

1. ~~**AES 握手细节**~~ —— **已在 Plan B 解决**:对照 `AES.java`(client/server 字节级相同)逐行复刻为 `WireCrypto`(AES/CBC/PKCS7,IV=key,4字节小时戳前缀含原版的"最高位恒为0"bug),并用真实编译运行的 Java `Cipher` 生成的密文做了交叉验证(而非仅自我一致性测试),CommonCrypto 在本工具链下可直接 `import` 无需额外 module map。详见 `docs/superpowers/plans/2026-06-17-phase1-plan-b-im-client.md` Task 5
2. **协议版本要求** —— `local_message_id` 等字段要求服务端 ≥ 2.2.0,Phase 1 启动前需确认 `chat-server-pro` 当前部署版本满足要求
3. **`NWConnection` 行为差异** —— Apple TCP 框架在后台/锁屏/网络切换时的行为与 Android NIO 不同,心跳/重连的具体参数可能需要根据 iOS 实测调整,不能机械照搬 Android 数值
4. **图片消息对象存储** —— Android 用 MinIO/七牛上传(`GetMinioUploadUrlHandler`/`QiniuTokenHandler`),iOS 需要复用同一套上传协议,实现阶段要确认是直传 URL 还是分片上传
5. **重连在连续失败4次后彻底停止**(Plan B 已按 Android `AbstractProtoService.receiveException` 的 `reconnectNum<=3` 行为原样复刻)——恢复需要外部触发(前台事件/网络可达性变化),这部分触发器**不在 Plan B 范围内**,Phase 4(或更早的 Plan B 后续小补丁)必须补上,否则真机断网几分钟后将永远不会自动重连
6. **`IMClient` 无内部加锁,要求调用方使用单一队列驱动**(`connect`/`disconnect`/`register` 与所有回调必须来自同一队列,约定为 main,与 `DispatchQueueScheduler`/`NWConnectionTransport` 的默认值一致)——Plan C/D 在集成 `IMClient` 时必须遵守这个约定,否则会出现真实的跨队列数据竞争。详见 `docs/superpowers/plans/2026-06-17-phase1-plan-b-im-client.md` Task 10 的 "Threading contract" 文档注释
7. **`IMClient`/`IMTransport`/`IMProto` 目前没有任何日志设施**——`ConnectAckHandler` 等组件遇到异常数据时静默丢弃,无法追踪;Plan C/D 在真机调试连接/心跳/重连问题之前需要补上日志钩子

## 12. 下一步

本设计文档评审通过后,针对 **Phase 1** 调用 `writing-plans` 技能产出详细实施计划(任务拆分、文件级改动、验证步骤),再进入开发。Phase 2/3/4 在各自启动前重新走一遍 brainstorming 流程。
