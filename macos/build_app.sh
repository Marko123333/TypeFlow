#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRODUCT_NAME="TypeFlow"
# Local builds use the current product name. The release packager overrides this
# only while creating the private compatibility payload required by 0.1.11.
BUNDLE_NAME="${RS_BUNDLE_NAME:-$PRODUCT_NAME.app}"
# Documents/iCloud can race with codesign by attaching FinderInfo to a freshly
# created bundle. Local installs can set RS_OUTPUT_DIR to a temporary directory
# outside File Provider storage; CI and existing callers keep the repo default.
APP_OUTPUT_DIR="${RS_OUTPUT_DIR:-$PROJECT_DIR}"
mkdir -p "$APP_OUTPUT_DIR"
APP_BUNDLE="$APP_OUTPUT_DIR/$BUNDLE_NAME"
# version.json живёт в КОРНЕ репозитория (живой фид обновлений) — не переносить!
# RS_VERSION_JSON переопределяет источник версии (для бета-сборок → version-beta.json).
VERSION_JSON="${RS_VERSION_JSON:-$PROJECT_DIR/../version.json}"

# version.json — единый источник правды. Значения в Info.plist в репо
# игнорируются: скрипт штампует CFBundleShortVersionString и CFBundleVersion
# в копию Info.plist внутри собранного бандла.
SHORT_VERSION=$(/usr/bin/python3 -c "import json,sys;print(json.load(open('$VERSION_JSON'))['version'])")
BUILD_VERSION=$(/usr/bin/python3 -c "import json,sys;print(json.load(open('$VERSION_JSON')).get('build','1'))")
DEV_TAG=$(/usr/bin/python3 -c "import json,sys;print(json.load(open('$VERSION_JSON')).get('dev',''))")

if [ -z "$SHORT_VERSION" ]; then
    echo "ERROR: could not read version from $VERSION_JSON"
    exit 1
fi

echo "=== Building $PRODUCT_NAME v$SHORT_VERSION (build $BUILD_VERSION) ==="

# 1. На локальной M1-машине по умолчанию собираем arm64. Universal SwiftPM
# требует полный Xcode; включается явно через RS_UNIVERSAL=1.
cd "$PROJECT_DIR"
if [ "${RS_UNIVERSAL:-0}" = "1" ]; then
    echo "→ swift build -c release --arch arm64 --arch x86_64 (universal)..."
    swift build -c release --arch arm64 --arch x86_64
    BUILD_DIR="$PROJECT_DIR/.build/apple/Products/Release"
    EXPECTED_ARCHS=("arm64" "x86_64")
else
    BUILD_ARCH="${RS_ARCH:-$(uname -m)}"
    echo "→ swift build -c release --arch $BUILD_ARCH..."
    swift build -c release --arch "$BUILD_ARCH"
    BUILD_DIR="$PROJECT_DIR/.build/$BUILD_ARCH-apple-macosx/release"
    EXPECTED_ARCHS=("$BUILD_ARCH")
fi

# 2. Создаём .app bundle
echo "→ Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Resources/ru.lproj"
mkdir -p "$APP_BUNDLE/Contents/Resources/en.lproj"

# 3. Копируем бинарник
cp "$BUILD_DIR/$PRODUCT_NAME" "$APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME"

# 3a. SwiftPM кладёт ресурсы SwitcherCore в отдельный bundle. Без него
# словари е/ё будут недоступны в упакованном приложении.
RESOURCE_BUNDLE="$BUILD_DIR/${PRODUCT_NAME}_SwitcherCore.bundle"
if [ ! -d "$RESOURCE_BUNDLE" ]; then
    echo "ERROR: resource bundle not found: $RESOURCE_BUNDLE"
    exit 1
fi
cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
PACKAGED_RESOURCE_BUNDLE="$APP_BUNDLE/Contents/Resources/$(basename "$RESOURCE_BUNDLE")"
for required_resource in \
    ru_words.fnv64 \
    en_words.fnv64 \
    ru_abbreviations.txt \
    yo_safe_forms.txt \
    yo_unsafe_forms.txt; do
    if [ ! -s "$PACKAGED_RESOURCE_BUNDLE/$required_resource" ]; then
        echo "ERROR: packaged resource is missing or empty: $required_resource"
        exit 1
    fi
done
echo "→ Packaged SwitcherCore resources OK"

# 3b. Самопроверка архитектуры.
ARCHS=$(lipo -archs "$APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME")
for expected in "${EXPECTED_ARCHS[@]}"; do
    if [[ "$ARCHS" != *"$expected"* ]]; then
        echo "ERROR: expected architecture $expected, got: $ARCHS"
        exit 1
    fi
done
echo "→ Architecture OK: $ARCHS"

# 4. Копируем Info.plist и штампуем версию из version.json
cp "$PROJECT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$PROJECT_DIR/InfoPlist.strings" "$APP_BUNDLE/Contents/Resources/ru.lproj/InfoPlist.strings"
cp "$PROJECT_DIR/InfoPlist.strings" "$APP_BUNDLE/Contents/Resources/en.lproj/InfoPlist.strings"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VERSION" "$APP_BUNDLE/Contents/Info.plist"
# Dev-метка (буква) для непубликуемых сборок — пусто для релиза. Показывается в About/меню.
/usr/libexec/PlistBuddy -c "Set :RSDevTag $DEV_TAG" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :RSDevTag string $DEV_TAG" "$APP_BUNDLE/Contents/Info.plist"
echo "→ Stamped Info.plist: CFBundleShortVersionString=$SHORT_VERSION$DEV_TAG CFBundleVersion=$BUILD_VERSION"

# 5. Копируем иконку
cp "$PROJECT_DIR/TypeFlow.icns" "$APP_BUNDLE/Contents/Resources/TypeFlow.icns"

# 6. Создаём PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# 7. Finder/File Provider добавляет xattrs даже свежему bundle в Documents.
# Они запрещены codesign, поэтому очищаем только что созданный .app.
xattr -cr "$APP_BUNDLE"

# 8. Локально подписываем ad-hoc. Для релиза RS_SIGN_ID должен содержать
#    собственный Developer ID автора сборки.
SIGN_ID="${RS_SIGN_ID:--}"
echo "→ Code signing..."
codesign --force --deep --sign "$SIGN_ID" \
    --options runtime \
    --entitlements "$PROJECT_DIR/TypeFlow.entitlements" \
    "$APP_BUNDLE"
# Documents может повторно добавить FinderInfo сразу после подписи. Удаление
# xattrs не меняет seal, но делает bundle приемлемым для strict-проверки.
xattr -cr "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo ""
echo "=== Done! ==="
echo "App bundle: $APP_BUNDLE"
echo "Signed with: $SIGN_ID"
echo ""
echo "To install:"
echo "  cp -R $APP_BUNDLE /Applications/"
echo "  open /Applications/$BUNDLE_NAME"
