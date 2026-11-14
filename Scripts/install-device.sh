#!/usr/bin/env bash
# Build the current source and replace the installed app without deleting its data or profiles.
# Run from a local Terminal with access to Xcode accounts, the signing keychain and the device.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE_UDID="${FSCHAT_DEVICE_UDID:-00008120-001945391147401E}"
BUILD_DIR="${FSCHAT_DEVICE_BUILD_DIR:-/tmp/ios-chat-pro-reinstall}"
BUNDLE_ID="cn.comsince.fschat"
PMD="$PROJECT_DIR/.tools/pymobiledevice3/bin/pymobiledevice3"
APP="$BUILD_DIR/Build/Products/Debug-iphoneos/App.app"
IPA="$BUILD_DIR/App.ipa"

if [[ ! -x "$PMD" ]]; then
  echo "缺少 pymobiledevice3，请按 CLAUDE.md 安装项目内工具。" >&2
  exit 1
fi
if ! env -u all_proxy -u ALL_PROXY "$PMD" version >/dev/null 2>&1; then
  echo "pymobiledevice3 无法运行，请按 CLAUDE.md 修复工具环境。" >&2
  exit 1
fi
mkdir -p "$BUILD_DIR"
cd "$PROJECT_DIR"

echo "构建当前源码，目标设备：$DEVICE_UDID"
# Use the project's normal package resolution and signing. A failed build stops before packaging,
# so an older App.app or App.ipa can never be installed as the new composer build by this script.
if ! xcodebuild -project ios-chat-pro.xcodeproj -scheme App \
    -destination 'generic/platform=iOS' -derivedDataPath "$BUILD_DIR" \
    -allowProvisioningUpdates build > "$BUILD_DIR/device-build.log" 2>&1; then
  echo "构建失败，未安装任何包。日志：$BUILD_DIR/device-build.log" >&2
  tail -n 35 "$BUILD_DIR/device-build.log" >&2
  exit 1
fi

codesign --verify --deep --strict "$APP"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/fschat-device.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
security cms -D -i "$APP/embedded.mobileprovision" > "$STAGE/profile.plist"
python3 - "$STAGE/profile.plist" "$APP/Info.plist" "$DEVICE_UDID" "$BUNDLE_ID" <<'PY'
import datetime
import plistlib
import sys

with open(sys.argv[1], 'rb') as source:
    profile = plistlib.load(source)
with open(sys.argv[2], 'rb') as source:
    info = plistlib.load(source)
if info.get('CFBundleIdentifier') != sys.argv[4]:
    raise SystemExit('应用 bundle ID 不符，停止安装。')
expiry = profile['ExpirationDate']
if expiry <= datetime.datetime.utcnow():
    raise SystemExit('描述文件已过期，停止安装；请检查 Xcode 签名账号。')
if not profile.get('ProvisionsAllDevices') and sys.argv[3] not in profile.get('ProvisionedDevices', []):
    raise SystemExit('描述文件未包含目标设备，停止安装；请检查 Xcode 设备注册。')
print('待安装版本：%s (%s)，描述文件到期：%s UTC' % (
    info['CFBundleShortVersionString'], info['CFBundleVersion'], expiry.isoformat()))
PY

mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
(cd "$STAGE" && zip -qry App.ipa Payload)
mv -f "$STAGE/App.ipa" "$IPA"

echo "覆盖安装，保留应用数据…"
if env -u all_proxy -u ALL_PROXY "$PMD" apps install --native --udid "$DEVICE_UDID" "$IPA"; then
  query_transport=(--native)
elif env -u all_proxy -u ALL_PROXY "$PMD" apps install --udid "$DEVICE_UDID" "$IPA"; then
  query_transport=()
else
  echo "安装失败；请连接并解锁手机、确认信任，或检查同 Wi-Fi 的 CoreDevice 连接。" >&2
  exit 1
fi

echo "安装命令成功，核对设备上的应用信息…"
if ! env -u all_proxy -u ALL_PROXY "$PMD" apps query ${query_transport[@]+"${query_transport[@]}"} \
    --udid "$DEVICE_UDID" "$BUNDLE_ID"; then
  echo "安装已返回成功，但查询未完成，请在手机上确认版本。" >&2
  exit 1
fi
echo "请在手机上打开飞享IM，进入会话测试新输入栏。此工具链不能自动启动 iOS 27 App。"
