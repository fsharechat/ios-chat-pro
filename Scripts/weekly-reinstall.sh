#!/usr/bin/env bash
# 每周日由 launchd（~/Library/LaunchAgents/cn.comsince.fschat.weekly-reinstall.plist）触发：
# 刷新免费账号的 7 天描述文件并无线重装到测试机，让到期日固定落在周日。
# 前提：Mac 开机、手机与 Mac 同一 Wi-Fi、`xcrun devicectl list devices` 能看到手机（无线走 CoreDevice 隧道）。
# 手机升到 iOS 27 后 Xcode 15.2 的 DDI 挂不上，devicectl 装不了，改用 pymobiledevice3 走 installation_proxy
# 装 ipa（不需要 DDI）。工具装在 .tools/pymobiledevice3，缺失时本脚本自动安装。
set -uo pipefail

DEVICE_UDID="00008120-001945391147401E"
BUNDLE_ID="cn.comsince.fschat"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/ios-chat-pro-weekly"
PMD_VENV="$PROJECT_DIR/.tools/pymobiledevice3"
PMD="$PMD_VENV/bin/pymobiledevice3"

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

# 3. 准备 pymobiledevice3（去掉 SOCKS 代理变量：httpx 缺 socksio 会报错；
#    cryptography 只用预编译包：源码编译要经代理下载 Rust，会卡死）
#    已装好就直接用；跑不起来（未安装，或建 venv 的 Python 被升级/卸载）才重建
if ! "$PMD" version >/dev/null 2>&1; then
  log "安装 pymobiledevice3…"
  { python3 -m venv --clear "$PMD_VENV" \
    && env -u all_proxy -u ALL_PROXY "$PMD_VENV/bin/pip" install -q --disable-pip-version-check \
         --prefer-binary --only-binary=cryptography pymobiledevice3; } \
    || fail "pymobiledevice3 安装失败"
fi

# 4. 打包 ipa
IPA="$DERIVED_DATA/App.ipa"
STAGE="$DERIVED_DATA/ipa-stage"
rm -rf "$STAGE" "$IPA" && mkdir -p "$STAGE/Payload" && cp -R "$APP" "$STAGE/Payload/" \
  && (cd "$STAGE" && zip -qry "$IPA" Payload) || fail "打包 ipa 失败"

# 5. 安装；优先 --native 借 macOS CoreDevice 隧道（无线可用、无需 root），失败再走 usbmuxd（插线时）。
#    iOS 17+ 无线下旧 lockdown 服务会被直接断开，--mobdev2 / usbmuxd 无线路径都不可用
for attempt in 1 2 3 4; do
  extra=(--native)
  [ $((attempt % 2)) = 0 ] && extra=()
  if env -u all_proxy -u ALL_PROXY "$PMD" apps install ${extra[@]+"${extra[@]}"} --udid "$DEVICE_UDID" "$IPA" 2>&1; then
    log "安装成功，到期 $expiry"
    notify "安装成功，描述文件到期 $expiry"
    exit 0
  fi
  log "安装失败（第 $attempt 次），30 秒后重试"
  sleep 30
done
fail "设备不可用或安装失败（手机是否解锁、与 Mac 同一 Wi-Fi？usbmuxd 卡住需手动重启，见 CLAUDE.md）"
