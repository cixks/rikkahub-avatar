#!/usr/bin/env bash
# Gitee Go 云端构建脚本：安装工具链 -> 生成占位配置 -> 编译 debug/release APK
set -euo pipefail

echo "========== RikkaHub avatar build =========="

export DEBIAN_FRONTEND=noninteractive

download() {
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$out" "$url"
  else
    wget -q -O "$out" "$url"
  fi
}

echo "=== 0. 基础工具 ==="
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -qq || true
  apt-get install -y -qq curl unzip python3 xz-utils || true
elif command -v yum >/dev/null 2>&1; then
  yum install -y curl unzip python3 xz || true
fi
command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || {
  echo "没有 curl/wget，无法下载工具链"; exit 1;
}

echo "=== 1. JDK 21 ==="
if [ -d /usr/lib/jvm/java-21-openjdk-amd64 ]; then
  export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
else
  echo "下载 Temurin JDK 21..."
  download "https://api.adoptium.net/v3/binary/latest/21/ga/linux/x64/jdk/hotspot/normal/eclipse" /tmp/jdk21.tar.gz
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
  download "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" /tmp/cmdtools.zip
  rm -rf /tmp/cmdtools
  unzip -q /tmp/cmdtools.zip -d /tmp/cmdtools
  rm -rf "$ANDROID_HOME/cmdline-tools/latest"
  mv /tmp/cmdtools/cmdline-tools "$ANDROID_HOME/cmdline-tools/latest"
fi
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
yes | sdkmanager --licenses >/dev/null 2>&1 || true

echo "可用 platform 列表（截取）:"
sdkmanager --list 2>/dev/null | grep "platforms;android-3" | head -40 || true

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
  echo "!! 没有找到 API 37 平台，尝试 API 36"
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
  download "https://nodejs.org/dist/${NODE_VER}/node-${NODE_VER}-linux-x64.tar.xz" /tmp/node.tar.xz
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
