#!/usr/bin/env bash
# Gitee Go Android 构建插件用脚本：复用插件装的 JDK/SDK/NDK，只补缺的包并编译 debug APK
set -euo pipefail

echo "========== RikkaHub avatar build =========="
echo "CPU: $(nproc 2>/dev/null || echo ?), MEM:"
free -m 2>/dev/null || true

export DEBIAN_FRONTEND=noninteractive

download() {
  local out="$1"; shift
  local url
  for url in "$@"; do
    echo "下载尝试: $url"
    if curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$out" "$url"; then
      echo "下载成功: $url"
      return 0
    fi
    if command -v wget >/dev/null 2>&1; then
      if wget -q --tries=3 --timeout=20 -O "$out" "$url"; then
        echo "下载成功(wget): $url"
        return 0
      fi
    fi
  done
  echo "所有下载地址都失败: $*"
  return 1
}

echo "=== 0. 基础工具 ==="
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -qq || true
  apt-get install -y -qq curl unzip python3 xz-utils ca-certificates || true
elif command -v yum >/dev/null 2>&1; then
  yum install -y curl unzip python3 xz ca-certificates || true
fi

echo "=== 1. JDK 21 ==="
if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
  echo "使用插件提供的 JDK: $JAVA_HOME"
else
  mkdir -p /usr/share/man/man1 || true
  apt-get install -y -qq openjdk-21-jdk-headless ca-certificates ca-certificates-java || true
  dpkg --configure -a || true
  update-ca-certificates -f || true
  if [ -d /usr/lib/jvm/java-21-openjdk-amd64 ]; then
    export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
  else
    download /tmp/jdk21.tar.gz \
      "https://mirrors.tuna.tsinghua.edu.cn/Adoptium/21/jdk/x64/linux/OpenJDK21U-jdk_x64_linux_hotspot_21.0.13_9.tar.gz" \
      "https://api.adoptium.net/v3/binary/latest/21/ga/linux/x64/jdk/hotspot/normal/eclipse"
    mkdir -p /opt/jdk21
    tar -xzf /tmp/jdk21.tar.gz -C /opt/jdk21 --strip-components=1
    export JAVA_HOME=/opt/jdk21
  fi
fi
export PATH="$JAVA_HOME/bin:$PATH"
java -version

echo "=== 2. Android SDK ==="
export ANDROID_HOME="${ANDROID_HOME:-/opt/android-sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
echo "ANDROID_HOME=$ANDROID_HOME"
SDKMANAGER="$(command -v sdkmanager || true)"
if [ -z "$SDKMANAGER" ] && [ -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]; then
  SDKMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
fi
if [ -z "$SDKMANAGER" ]; then
  mkdir -p "$ANDROID_HOME/cmdline-tools"
  download /tmp/cmdtools.zip \
    "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" \
    "https://mirrors.aliyun.com/android/repository/commandlinetools-linux-11076708_latest.zip"
  rm -rf /tmp/cmdtools
  unzip -q /tmp/cmdtools.zip -d /tmp/cmdtools
  rm -rf "$ANDROID_HOME/cmdline-tools/latest"
  mv /tmp/cmdtools/cmdline-tools "$ANDROID_HOME/cmdline-tools/latest"
  SDKMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
fi
export PATH="$(dirname "$SDKMANAGER"):$PATH"
yes | sdkmanager --licenses >/dev/null 2>&1 || true

# 项目 compileSdk = 37.2，AGP 还会要 build-tools 36
sdkmanager "platforms;android-37.2" "platform-tools" "build-tools;36.0.0" || true
sdkmanager "build-tools;37.0.0" || true

echo "=== 3. Node 22 + pnpm 11 ==="
if ! command -v node >/dev/null || [ "$(node -v | cut -d. -f1 | tr -d v)" -lt 20 ]; then
  NODE_VER=$(python3 -c "
import json, urllib.request
d=json.load(urllib.request.urlopen('https://nodejs.org/dist/index.json', timeout=20))
print(next(x['version'] for x in d if x['version'].startswith('v22.')))
" 2>/dev/null || echo "v22.20.0")
  echo "安装 Node $NODE_VER"
  download /tmp/node.tar.xz \
    "https://nodejs.org/dist/${NODE_VER}/node-${NODE_VER}-linux-x64.tar.xz" \
    "https://registry.npmmirror.com/-/binary/node/${NODE_VER}/node-${NODE_VER}-linux-x64.tar.xz"
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

# 云端 4G 内存：压小堆、关并行、关配置缓存
sed -i 's/^org.gradle.jvmargs=.*/org.gradle.jvmargs=-Xmx2g -XX:MaxMetaspaceSize=512m -Dfile.encoding=UTF-8/' gradle.properties
sed -i 's/^org.gradle.parallel=.*/org.gradle.parallel=false/' gradle.properties
sed -i 's/^org.gradle.configuration-cache=.*/org.gradle.configuration-cache=false/' gradle.properties
cat >> gradle.properties <<'EOF'
kotlin.daemon.jvmargs=-Xmx768m -XX:MaxMetaspaceSize=256m
org.gradle.workers.max=1
firebaseCrashlytics.mappingFileUploadEnabled=false
EOF

echo "=== 5. 构建 web-ui ==="
(cd web-ui && pnpm install --frozen-lockfile && pnpm run build)

echo "=== 6. Gradle 编译 APK ==="
mkdir -p "$HOME/.gradle"
cat > "$HOME/.gradle/init.gradle.kts" <<'EOF'
gradle.beforeSettings {
    pluginManagement {
        repositories {
            maven("https://maven.aliyun.com/repository/gradle-plugin")
            maven("https://maven.aliyun.com/repository/google")
            maven("https://maven.aliyun.com/repository/public")
        }
    }
    dependencyResolutionManagement {
        repositories {
            maven("https://maven.aliyun.com/repository/google")
            maven("https://maven.aliyun.com/repository/public")
        }
    }
}
EOF

GDIST=/opt/gradle-dist.zip
if [ ! -s "$GDIST" ] && download "$GDIST" \
  "https://mirrors.cloud.tencent.com/gradle/gradle-9.6.0-bin.zip" \
  "https://repo.huaweicloud.com/gradle/gradle-9.6.0-bin.zip"; then
  if ! unzip -tq "$GDIST" >/dev/null 2>&1; then rm -f "$GDIST"; fi
fi
if [ -s "$GDIST" ]; then
  sed -i "s#^distributionUrl=.*#distributionUrl=file\\\\://$GDIST#" gradle/wrapper/gradle-wrapper.properties
  echo "使用本地 Gradle 发行包"
fi

chmod +x ./gradlew
./gradlew assembleGithubDebug \
  --no-daemon --stacktrace --console=plain --info --max-workers=1 \
  -Dorg.gradle.internal.http.connectionTimeout=60000 \
  -Dorg.gradle.internal.http.socketTimeout=180000

echo "=== 7. 产物 ==="
find app/build/outputs/apk -name "*.apk" -print
echo "========== BUILD SUCCESS =========="
