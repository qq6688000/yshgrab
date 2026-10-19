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
lipo -info "$DYLIB" 2>/dev/null || otool -l "$DYLIB" | grep -A2 "Fat" || true

# 3. 生成 binary plist (30 bundles)
python3 -c "
import plistlib
bundles = ['com.apple.mobilesafari','com.apple.SafariViewService','com.apple.WebSheet','com.apple.DocumentsApp','com.google.chrome.ios','org.mozilla.ios.Firefox','com.microsoft.edgemobile','com.brave.ios.Browser','com.alook.browser','com.quark.browser','com.ucweb.iphone.launcher','com.tencent.mtt','com.operasoftware.Opera','com.duckduckgo.mobile.ios','com.ss.iphone.ugc.Aweme','com.ss.iphone.ugc.Ame','com.zhiliaoapp.musically','com.dragon.read','com.jiangjia.gif','com.kuaishou.nebula','com.xingin.discover','com.sina.weibo','com.zhihu.ios','com.tencent.xin','com.tencent.mqq','tv.danmaku.bilianime','com.google.ios.youtube','com.tencent.live4iphone','com.iqiyi.iphone','com.youku.YouKu']
plistlib.dump({'Filter':{'Bundles':bundles}}, open('YSHGrab.plist','wb'), fmt=plistlib.FMT_BINARY)
print('plist generated:', len(bundles), 'bundles')
"

# 4. 手动 staging + 打包
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
echo "=== cryptid ==="
otool -l "$DYLIB2" 2>/dev/null | grep cryptid | head -2
rm -rf "$TMPV"
