#!/bin/bash
set -e
export THEOS="${THEOS:-$HOME/theos}"

# 1. 只编译 dylib（不 make package，避免 staging 时缺 plist 报错）
make clean 2>/dev/null || true
make FINALPACKAGE=1 2>&1

# 2. 获取编译好的 dylib
DYLIB=$(find .theos/obj -name "YSHGrab.dylib" 2>/dev/null | head -1)
[ -z "$DYLIB" ] && { echo "ERROR: dylib not found"; find .theos/obj -name "*.dylib" 2>/dev/null; exit 1; }
echo "Using dylib: $DYLIB"
echo "=== dylib arch ==="
lipo -info "$DYLIB" 2>/dev/null || true

# 3. 修复 load commands（对齐参考 1.4.0 的 rootless 注入方式）
# a) CydiaSubstrate 依赖: 绝对路径 → @rpath（rootless 下 /Library/Frameworks/ 不存在）
echo "=== 修复 CydiaSubstrate 依赖路径 ==="
otool -L "$DYLIB" | grep -i substrate
# 对 fat binary 直接操作，install_name_tool 会自动处理所有切片
install_name_tool \
  -change /Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate @rpath/CydiaSubstrate.framework/CydiaSubstrate \
  -change @rpath/CydiaSubstrate.framework/CydiaSubstrate @rpath/CydiaSubstrate.framework/CydiaSubstrate \
  "$DYLIB" 2>/dev/null || true

# b) install_name: 绝对路径 → @rpath
install_name_tool -id @rpath/YSHGrab.dylib "$DYLIB" 2>/dev/null || true

# c) 重新签名（install_name_tool 会破坏签名）
ldid -S "$DYLIB" 2>/dev/null || codesign -f -s - "$DYLIB" 2>/dev/null || true

echo "=== 修复后依赖 ==="
otool -L "$DYLIB" | head -15
echo "=== 修复后 rpath ==="
otool -l "$DYLIB" | grep -A2 LC_RPATH

# 4. 生成 binary plist (30 bundles)
python3 -c "
import plistlib
bundles = ['com.apple.mobilesafari','com.apple.SafariViewService','com.apple.WebSheet','com.apple.DocumentsApp','com.google.chrome.ios','org.mozilla.ios.Firefox','com.microsoft.edgemobile','com.brave.ios.Browser','com.alook.browser','com.quark.browser','com.ucweb.iphone.launcher','com.tencent.mtt','com.operasoftware.Opera','com.duckduckgo.mobile.ios','com.ss.iphone.ugc.Aweme','com.ss.iphone.ugc.Ame','com.zhiliaoapp.musically','com.dragon.read','com.jiangjia.gif','com.kuaishou.nebula','com.xingin.discover','com.sina.weibo','com.zhihu.ios','com.tencent.xin','com.tencent.mqq','tv.danmaku.bilianime','com.google.ios.youtube','com.tencent.live4iphone','com.iqiyi.iphone','com.youku.YouKu']
plistlib.dump({'Filter':{'Bundles':bundles}}, open('YSHGrab.plist','wb'), fmt=plistlib.FMT_BINARY)
print('plist generated:', len(bundles), 'bundles')
"

# 5. 手动 staging + 打包
ST=$(mktemp -d)
mkdir -p "$ST/DEBIAN"
mkdir -p "$ST/var/jb/Library/MobileSubstrate/DynamicLibraries"
mkdir -p "$ST/var/jb/usr/bin"
cp "$DYLIB" "$ST/var/jb/Library/MobileSubstrate/DynamicLibraries/YSHGrab.dylib"
cp YSHGrab.plist "$ST/var/jb/Library/MobileSubstrate/DynamicLibraries/YSHGrab.plist"
cp control "$ST/DEBIAN/control"
cp postinst "$ST/DEBIAN/postinst"
chmod 755 "$ST/DEBIAN/postinst"
cp yshgrab "$ST/var/jb/usr/bin/yshgrab"
chmod 755 "$ST/var/jb/usr/bin/yshgrab"

mkdir -p packages
OUT="packages/com.minis.yshgrab_1.4.0_iphoneos-arm64.deb"
dpkg-deb --build --root-owner-group "$ST" "$OUT"
rm -rf "$ST"

echo "=== Built: $OUT ==="
dpkg-deb -c "$OUT"
echo "=== dylib arch (from deb) ==="
TMPV=$(mktemp -d)
dpkg-deb -x "$OUT" "$TMPV"
DYLIB2="$TMPV/var/jb/Library/MobileSubstrate/DynamicLibraries/YSHGrab.dylib"
lipo -info "$DYLIB2" 2>/dev/null || true
echo "=== paciza count (arm64e PAC stubs, should be >0) ==="
otool -tv "$DYLIB2" 2>/dev/null | grep -c paciza || echo "0 paciza"
echo "=== pacibsp count ==="
otool -tv "$DYLIB2" 2>/dev/null | grep -c pacibsp || echo "0 pacibsp"
echo "=== substrate 依赖路径 (应为 @rpath/) ==="
otool -L "$DYLIB2" 2>/dev/null | grep -i substrate
echo "=== LC_RPATH (应有4个) ==="
otool -l "$DYLIB2" 2>/dev/null | grep -A2 LC_RPATH
echo "=== install_name (应为 @rpath/) ==="
otool -D "$DYLIB2" 2>/dev/null
echo "=== cryptid ==="
otool -l "$DYLIB2" 2>/dev/null | grep cryptid | head -2
rm -rf "$TMPV"
