#!/bin/bash
set -e

cd WiiUDownloader

python3 grabTitles.py

cd ..

NDK=$ANDROID_HOME/ndk/29.0.14206865
API=21
PREBUILT=darwin-x86_64

cd native_lib

build() {
  ARCH=$1
  ABI=$2
  CC_BIN=$3
  GOARCH=$4
  GOARM=$5

  export CGO_ENABLED=1
  export GOOS=android
  export GOARCH=$GOARCH
  export GOARM=$GOARM
  export CC=$NDK/toolchains/llvm/prebuilt/$PREBUILT/bin/$CC_BIN

  mkdir -p ../android/app/src/main/jniLibs/$ABI

  go build -buildmode=c-shared \
    -ldflags="-s -w" \
    -o ../android/app/src/main/jniLibs/$ABI/libwiiudownloader.so
}

# ARM64
build arm64 arm64-v8a aarch64-linux-android${API}-clang arm64 ""

# ARMv7a
build arm armeabi-v7a armv7a-linux-androideabi${API}-clang arm 7

# x86
build x86 x86 i686-linux-android${API}-clang 386 ""

# x86_64
build x86_64 x86_64 x86_64-linux-android${API}-clang amd64 ""


cd ..
flutter build apk --release
