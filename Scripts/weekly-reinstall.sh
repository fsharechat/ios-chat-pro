#!/usr/bin/env bash
# 每周日由 launchd（~/Library/LaunchAgents/cn.comsince.fschat.weekly-reinstall.plist）触发：
# 刷新免费账号的 7 天描述文件并无线重装到测试机，让到期日固定落在周日。
# 前提：Mac 开机、手机与 Mac 同一 Wi-Fi、Xcode Devices 窗口已勾选 "Connect via network"。
set -uo pipefail

DEVICE_UDID="00008120-001945391147401E"
BUNDLE_ID="cn.comsince.fschat"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/ios-chat-pro-weekly"

log() { echo "[$(date '+%F %T')] $*"; }
notify() { osascript -e "display notification \"$1\" with title \"fschat 每周重装\"" >/dev/null 2>&1 || true; }
fail() { log "失败：$*"; notify "失败：$*"; exit 1; }

log "===== 开始 ====="

# 1. 删除本 App 的旧描述文件，否则 Xcode 会复用未过期的那份，到期日不会刷新
for f in "$PROFILE_DIR"/*.mobileprovision; do
  [ -e "$f" ] || continue
  appid=$(security cms -D -i "$f" 2>/dev/null | plutil -extract Entitlements.application-identifier raw -o - - 2>/dev/null)
  if [[ "$appid" == *".$BUNDLE_ID" ]]; then
    log "删除旧描述文件 $(basename "$f")"
    rm -f "$f"
  fi
done

# 2. 编译（会自动重新申请描述文件）
log "编译中…"
xcodebuild -project "$PROJECT_DIR/ios-chat-pro.xcodeproj" -scheme App \
  -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates build > "$DERIVED_DATA.build.log" 2>&1 \
  || fail "编译失败，详见 $DERIVED_DATA.build.log"

APP="$DERIVED_DATA/Build/Products/Debug-iphoneos/App.app"
expiry=$(security cms -D -i "$APP/embedded.mobileprovision" | plutil -extract ExpirationDate raw -o - -)
log "新描述文件到期：$expiry"

# 3. 安装；失败重试，第 2 次失败后重启用户态 CoreDeviceService（隧道卡住时需要）
for attempt in 1 2 3 4; do
  if xcrun devicectl device install app --device "$DEVICE_UDID" "$APP" 2>&1; then
    log "安装成功，到期 $expiry"
    notify "安装成功，描述文件到期 $expiry"
    exit 0
  fi
  log "安装失败（第 $attempt 次），30 秒后重试"
  [ "$attempt" = 2 ] && pkill -f 'CoreDeviceService.xpc/Contents/MacOS/CoreDeviceService' && log "已重启 CoreDeviceService"
  sleep 30
done
fail "设备不可用或安装失败（手机是否解锁、与 Mac 同一 Wi-Fi？）"
