#!/usr/bin/env bash
# Gitee Go 云端构建脚本：安装工具链 -> 生成占位配置 -> 编译 debug/release APK
set -euo pipefail

echo "========== RikkaHub avatar build =========="

export DEBIAN_FRONTEND=noninteractive

echo "=== 0. 基础工具 ==="
(command -v curl >/dev/null || apt-get update -qq && apt-get install -y -qq curl) || true
(command -v unzip >/dev/null || apt-get install -y -qq unzip) || true
(command -v python3 >/dev/null || apt-get install -y -qq python3) || true

echo "=== 1. JDK 21 ==="
if [ -d /usr/lib/jvm/java-21-openjdk-amd64 ]; then
  export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
else
  echo "下载 Temurin JDK 21..."
  curl -fsSL -o /tmp/jdk21.tar.gz \
    "https://api.adoptium.net/v3/binary/latest/21/ga/linux/x64/jdk/hotspot/normal/eclipse"
  mkdir -p /opt/jdk21
  tar -xzf /tmp/jdk21.tar.gz -C /opt/jdk21 --strip-components=1
  export JAVA_HOME=/opt/jdk21
fi
export PATH="$JAVA_HOME/bin:$PATH"
java -version

echo "=== 2. Android SDK ==="
export ANDROID_HOME=/opt/android-sdk
export ANDROID_SDK_ROOT="$ANDROID_HOME"
mkdir -p "$ANDROID_HOME/cmdline-tools"
if [ ! -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]; then
  echo "下载 Android cmdline-tools..."
  curl -fsSL -o /tmp/cmdtools.zip \
    "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
  rm -rf /tmp/cmdtools
  unzip -q /tmp/cmdtools.zip -d /tmp/cmdtools
  rm -rf "$ANDROID_HOME/cmdline-tools/latest"
  mv /tmp/cmdtools/cmdline-tools "$ANDROID_HOME/cmdline-tools/latest"
fi
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
yes | sdkmanager --licenses >/dev/null 2>&1 || true

echo "可用 platform 列表（截取）:"
sdkmanager --list 2>/dev/null | grep "platforms;android-3" | head -40 || true

# compileSdk = 37.2，优先装带 minor API 的包，找不到再退回 37
INSTALLED_PLATFORM=""
for pkg in "platforms;android-37-ext2" "platforms;android-37.2" "platforms;android-37"; do
  echo "尝试安装 $pkg ..."
  if sdkmanager "$pkg" >/dev/null 2>&1; then
    echo "已安装 $pkg"
    INSTALLED_PLATFORM="$pkg"
    break
  fi
done
if [ -z "$INSTALLED_PLATFORM" ]; then
  echo "!! 没有找到 API 37 平台，尝试 API 36（可能编译失败）"
  sdkmanager "platforms;android-36" || true
fi
sdkmanager "platform-tools" || true
for bt in "build-tools;37.0.0" "build-tools;36.0.0"; do
  if sdkmanager "$bt" >/dev/null 2>&1; then echo "已安装 $bt"; break; fi
done

echo "=== 3. Node 22 + pnpm 11 ==="
if ! command -v node >/dev/null || [ "$(node -v | cut -d. -f1 | tr -d v)" -lt 20 ]; then
  NODE_VER=$(python3 -c "
import json, urllib.request
d=json.load(urllib.request.urlopen('https://nodejs.org/dist/index.json', timeout=30))
print(next(x['version'] for x in d if x['version'].startswith('v22.')))
" 2>/dev/null || echo "v22.20.0")
  echo "安装 Node $NODE_VER"
  curl -fsSL -o /tmp/node.tar.xz \
    "https://nodejs.org/dist/${NODE_VER}/node-${NODE_VER}-linux-x64.tar.xz"
  mkdir -p /opt/node
  tar -xJf /tmp/node.tar.xz -C /opt/node --strip-components=1
  export PATH="/opt/node/bin:$PATH"
fi
node -v
npm config set registry https://registry.npmmirror.com || true
npm install -g pnpm@11 || true
pnpm -v

echo "=== 4. 生成构建所需配置 ==="
echo "sdk.dir=$ANDROID_HOME" > local.properties

# 仓库里没有 google-services.json（官方 CI 靠 secret 注入），生成一个占位文件让插件通过校验
cat > app/google-services.json <<'EOF'
{
  "project_info": {
    "project_number": "1234567890",
    "project_id": "rikkahub-local-build",
    "storage_bucket": "rikkahub-local-build.appspot.com"
  },
  "client": [
    {
      "client_info": {
        "mobilesdk_app_id": "1:1234567890:android:0000000000000000000000",
        "android_client_info": { "package_name": "me.rerere.rikkahub" }
      },
      "oauth_client": [],
      "api_key": [ { "current_key": "AIzaSyDummyKeyForLocalBuild000000000000" } ],
      "services": { "appinvite_service": { "other_platform_oauth_client": [] } }
    }
  ],
  "configuration_version": "1"
}
EOF

# release 签名用的 keystore（仅本地构建产物，不上传）
if [ ! -f app/app.key ]; then
  keytool -genkeypair -v -keystore app/app.key \
    -storepass rikkahub123 -keypass rikkahub123 -alias rikka \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=RikkaHubLocal, OU=Local, O=Local, L=Local, ST=Local, C=CN" \
    >/dev/null 2>&1
fi
cat >> local.properties <<'EOF'
storeFile=app/app.key
storePassword=rikkahub123
keyAlias=rikka
keyPassword=rikkahub123
EOF

# 这台云机器内存有限，降低 Gradle 堆；关闭 Crashlytics mapping 上传避免联网失败
sed -i 's/org.gradle.jvmargs=-Xmx8g/org.gradle.jvmargs=-Xmx4g/' gradle.properties
echo 'firebaseCrashlytics.mappingFileUploadEnabled=false' >> gradle.properties

echo "=== 5. 构建 web-ui ==="
(cd web-ui && pnpm install --frozen-lockfile && pnpm run build)

echo "=== 6. Gradle 编译 APK ==="
chmod +x ./gradlew
./gradlew assembleGithubDebug assembleGithubRelease --no-daemon --stacktrace

echo "=== 7. 产物 ==="
find app/build/outputs/apk -name "*.apk" -print
echo "========== BUILD SUCCESS =========="
