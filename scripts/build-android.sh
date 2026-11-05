#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${JAVA_HOME:-}" ]; then
    for FLOW_JDK in "$PWD"/.tools/zulu*/Contents/Home; do
        if [ -x "$FLOW_JDK/bin/java" ]; then export JAVA_HOME="$FLOW_JDK"; break; fi
    done
fi
if [ -x android/gradlew ]; then
    FLOW_GRADLE="$PWD/android/gradlew"
elif [ -x .tools/gradle-8.11.1/bin/gradle ]; then
    FLOW_GRADLE="$PWD/.tools/gradle-8.11.1/bin/gradle"
else
    echo "请使用 Android Studio 打开 android/，或安装 JDK 17 和 Gradle 8.11.1。" >&2
    exit 1
fi
"$FLOW_GRADLE" -p "$PWD/android" :app:assembleDebug :app:testDebugUnitTest
mkdir -p dist
cp android/app/build/outputs/apk/debug/app-debug.apk dist/Flow-Android-debug.apk
echo "已构建：$PWD/dist/Flow-Android-debug.apk"
