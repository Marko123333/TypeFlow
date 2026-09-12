#!/bin/bash
set -e

PRODUCT_NAME="TypeFlow"
# Compatibility contract with 0.1.11: the updater only accepts this exact app
# basename and Bundle ID. CFBundleDisplayName still presents it as TypeFlow.
COMPAT_APP_NAME="LocalSwitcher.app"
VISIBLE_APP_NAME="TypeFlow.app"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"   # все относительные пути — от macos/ (аудит: раньше зависели от CWD)
# --beta: собрать ПРЕД-РЕЛИЗ из version-beta.json, НЕ трогая стабильный фид (version.json)
# и cask. Иначе — обычный стабильный релиз из version.json (живой фид обновлений).
# --self-signed: канал без Apple Developer Program. Использует постоянный локальный
# сертификат, пропускает нотарификацию и всё равно подписывает update-манифест.
BETA=0
SELF_SIGNED=0
SELF_SIGNED_CERT_SHA1="BA582D2E25C17FAD3524B3C3CAED3748816D2E8A"
SELF_SIGNED_CERT_SHA256="19c8caec20337d7749f5760844b6011364f463c0890268753eae8e6334318f30"
VERSION_FILE="../version.json"
for arg in "$@"; do
    case "$arg" in
        --beta)
            BETA=1
            VERSION_FILE="../version-beta.json"
            ;;
        --self-signed)
            SELF_SIGNED=1
            ;;
        *)
            echo "ERROR: unknown argument: $arg" >&2
            echo "Usage: ./create_dmg.sh [--beta] [--self-signed]" >&2
            exit 64
            ;;
    esac
done
if [ "$BETA" = "1" ]; then
    echo "=== BETA build (source: $VERSION_FILE — stable version.json/cask untouched) ==="
fi
if [ "$SELF_SIGNED" = "1" ]; then
    export SKIP_NOTARIZE=1
    export RS_SIGN_ID="${RS_SIGN_ID:-LocalSwitcher Local Development}"
    echo "=== SELF-SIGNED build (Gatekeeper notarization unavailable) ==="
fi
# build_app.sh читает тот же источник версии через RS_VERSION_JSON.
export RS_VERSION_JSON="$SCRIPT_DIR/$VERSION_FILE"
VERSION=$(/usr/bin/python3 -c "import json;print(json.load(open('$VERSION_FILE'))['version'])")
BUILD=$(/usr/bin/python3 -c "import json;print(json.load(open('$VERSION_FILE')).get('build','1'))")
DMG_NAME="${PRODUCT_NAME}-macOS-arm64.dmg"
# The public DMG contains only TypeFlow.app. The versioned compatibility DMG is
# used by the signed updater and contains the legacy basename required by 0.1.11.
COMPAT_DMG_NAME="LocalSwitcher-${VERSION}.dmg"
# Нотаризация: предпочитаем API-ключ App Store Connect — файл на диске, НЕ зависит
# от Keychain (keychain-профиль уже дважды пропадал: 2026-07-01 и 2026-07-10).
# Конфиг ключа: ~/.config/localswitcher/notary.conf (задаёт NOTARY_KEY_FILE,
# NOTARY_KEY_ID, NOTARY_ISSUER_ID; chmod 600). Фолбэк — keychain-профиль.
# Переопределение: NOTARIZE_PROFILE=<name>, NOTARY_CONF=<path>. Пропуск: SKIP_NOTARIZE=1.
NOTARIZE_PROFILE="${NOTARIZE_PROFILE:-localswitcher-notary}"
NOTARY_CONF="${NOTARY_CONF:-$HOME/.config/localswitcher/notary.conf}"
if [ -f "$NOTARY_CONF" ]; then
    # shellcheck source=/dev/null
    . "$NOTARY_CONF"
fi
if [ -n "${NOTARY_KEY_FILE:-}" ] && [ -f "$NOTARY_KEY_FILE" ] \
   && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER_ID:-}" ]; then
    NOTARY_ARGS=(--key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
    NOTARY_VIA="ASC API key $NOTARY_KEY_ID"
else
    NOTARY_ARGS=(--keychain-profile "$NOTARIZE_PROFILE")
    NOTARY_VIA="keychain profile $NOTARIZE_PROFILE"
fi
DMG_TEMP="${PRODUCT_NAME}-temp.dmg"
VOL_NAME="${PRODUCT_NAME}"
BACKGROUND="dmg_background.png"

# Сборочный app-бандл держим вне Documents/File Provider: иначе FinderInfo может
# появиться между codesign и следующей проверкой и сделать релиз невоспроизводимым.
BUILD_OUTPUT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/localswitcher-release-app.XXXXXX")
COMPAT_STAGE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/typeflow-update-stage.XXXXXX")
CERT_TMP_DIR=""
MOUNT_DIR=""
cleanup_release_temp() {
    if [ -n "$MOUNT_DIR" ] && [ -d "$MOUNT_DIR" ]; then
        hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$BUILD_OUTPUT_DIR"
    rm -rf "$COMPAT_STAGE_DIR"
    if [ -n "$CERT_TMP_DIR" ]; then
        rm -rf "$CERT_TMP_DIR"
    fi
    rm -f "$DMG_TEMP"
}
trap cleanup_release_temp EXIT
export RS_OUTPUT_DIR="$BUILD_OUTPUT_DIR"
export RS_BUNDLE_NAME="$COMPAT_APP_NAME"
APP_PATH="$BUILD_OUTPUT_DIR/$COMPAT_APP_NAME"

echo "=== Creating styled DMG ==="

# The source artwork and generated icon files must never drift apart.
echo "→ Generating current application icon..."
"$SCRIPT_DIR/generate_icon.swift"
/usr/bin/iconutil -c icns "$SCRIPT_DIR/TypeFlow.iconset" -o "$SCRIPT_DIR/TypeFlow.icns"

# The background is source-generated on every build. Shipping a stale checked-in
# PNG previously left the old RuSwitcher title and overlapping instructions in DMG.
echo "→ Generating current DMG background..."
"$SCRIPT_DIR/generate_dmg_background.swift" "$SCRIPT_DIR/$BACKGROUND"
BACKGROUND_WIDTH=$(sips -g pixelWidth "$SCRIPT_DIR/$BACKGROUND" | awk '/pixelWidth/ {print $2}')
BACKGROUND_HEIGHT=$(sips -g pixelHeight "$SCRIPT_DIR/$BACKGROUND" | awk '/pixelHeight/ {print $2}')
if [ "$BACKGROUND_WIDTH" != "900" ] || [ "$BACKGROUND_HEIGHT" != "480" ]; then
    echo "ERROR: DMG background must be 900x480, got ${BACKGROUND_WIDTH}x${BACKGROUND_HEIGHT}." >&2
    exit 1
fi

# 00. Fail fast: нотаризационный профиль проверяем ДО многоминутной сборки.
#     Профиль уже ДВАЖДЫ пропадал из Keychain (2026-07: удалён на живой системе
#     между релизами, без ребута/обновлений — подозрение на чистильщики/VPN-софт),
#     и падение в середине пайплайна путает. Ловим сразу, с рецептом починки.
if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    if ! xcrun notarytool history "${NOTARY_ARGS[@]}" >/dev/null 2>&1; then
        echo "ОШИБКА: нотаризационные креды недоступны (пробовали: $NOTARY_VIA)."
        echo "Вариант 1 (надёжный): API-ключ App Store Connect в $NOTARY_CONF"
        echo "  (NOTARY_KEY_FILE=…AuthKey_XXX.p8, NOTARY_KEY_ID=…, NOTARY_ISSUER_ID=…)."
        echo "Вариант 2: keychain-профиль (пароль — app-specific password, интерактивно):"
        echo "  xcrun notarytool store-credentials $NOTARIZE_PROFILE \\"
        echo "      --apple-id you@example.com --team-id YOUR_TEAM_ID"
        exit 69
    fi
    echo "→ Notary credentials OK ($NOTARY_VIA)"
fi

# 0. ВСЕГДА пересобираем приложение из исходников. Без этого шага DMG берёт имя
#    из version.json, а payload — из случайно лежащего рядом LocalSwitcher.app.
#    Именно так в релиз 2.1.0 попал бандл 2.0.3: имя было 2.1.0, а внутри 2.0.3.
echo "→ Rebuilding app from source (build_app.sh)..."
"$SCRIPT_DIR/build_app.sh"

APP_SIZE_KB=$(du -sk "$APP_PATH" | awk '{print $1}')
if [ "$APP_SIZE_KB" -le 0 ] || [ "$APP_SIZE_KB" -gt 204800 ]; then
    echo "ERROR: unexpected app size: ${APP_SIZE_KB} KiB (allowed: 1..204800)." >&2
    exit 1
fi
DMG_SIZE="$((APP_SIZE_KB / 1024 + 32))m"
echo "→ DMG capacity: $DMG_SIZE for ${APP_SIZE_KB} KiB app"

# 0a. Жёсткая проверка: версия в собранном бандле обязана совпадать с version.json,
#     иначе отказываемся паковать DMG.
BUNDLE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
BUNDLE_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")
if [ "$BUNDLE_VERSION" != "$VERSION" ] || [ "$BUNDLE_BUILD" != "$BUILD" ]; then
    echo "ERROR: bundle is $BUNDLE_VERSION (build $BUNDLE_BUILD) but version.json is $VERSION (build $BUILD)."
    echo "       Refusing to ship a version-mismatched DMG."
    exit 1
fi
echo "→ Verified bundle $BUNDLE_VERSION (build $BUNDLE_BUILD) matches version.json"

if [ "$SELF_SIGNED" = "1" ]; then
    echo "→ Verifying pinned LocalSwitcher signing certificate..."
    codesign --verify --deep --strict \
        -R="identifier \"com.marko.localswitcher.app\" and certificate leaf = H\"${SELF_SIGNED_CERT_SHA1}\"" \
        "$APP_PATH"
    CERT_TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/localswitcher-release-cert.XXXXXX")
    CERT_PREFIX="$CERT_TMP_DIR/cert"
    codesign -d --extract-certificates="$CERT_PREFIX" "$APP_PATH"
    ACTUAL_CERT_SHA256=$(shasum -a 256 "${CERT_PREFIX}0" | awk '{print $1}')
    rm -rf "$CERT_TMP_DIR"
    CERT_TMP_DIR=""
    if [ "$ACTUAL_CERT_SHA256" != "$SELF_SIGNED_CERT_SHA256" ]; then
        echo "ERROR: app was signed by an unexpected certificate (SHA-256 mismatch)." >&2
        exit 1
    fi
    echo "→ Exact certificate DER matches the pinned SHA-256"
fi

# 0b. Нотаризуем и стейплим САМО приложение ДО упаковки — чтобы тикет был внутри .app.
#     Без этого вытащенный из DMG бандл не имеет своего тикета и при первом запуске
#     зависит от ОНЛАЙН-проверки Gatekeeper (после переноса/в офлайне → «не могу запустить»).
#     Со стейплом на бандле приложение запускается чисто офлайн, без xattr.
if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    echo "→ Notarizing the app bundle..."
    ditto -c -k --keepParent "$APP_PATH" "${PRODUCT_NAME}-app.zip"
    xcrun notarytool submit "${PRODUCT_NAME}-app.zip" "${NOTARY_ARGS[@]}" --wait
    rm -f "${PRODUCT_NAME}-app.zip"
    echo "→ Stapling the app bundle..."
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
fi

# Clean up
rm -f "$DMG_NAME" "$COMPAT_DMG_NAME" "$DMG_TEMP"

# 0c. Снимаем «застрявшие» тома с тем же именем. Если /Volumes/LocalSwitcher уже занят,
#     наш temp-образ примонтируется как «LocalSwitcher 1», а AppleScript-оформление
#     (`tell disk "LocalSwitcher"`) уйдёт на чужой/несуществующий диск → .DS_Store с фоном
#     и позициями НЕ запишется в наш образ, и DMG откроется голым. Чистим заранее.
for v in "/Volumes/${VOL_NAME}"*; do
    if [ -d "$v" ]; then
        echo "→ Detaching stale volume: $v"
        hdiutil detach "$v" -force 2>/dev/null || true
    fi
done

# 1. Create temporary writable DMG
echo "→ Creating temp DMG..."
hdiutil create -volname "$VOL_NAME" -fs HFS+ \
    -size "$DMG_SIZE" -layout NONE "$DMG_TEMP"

# 2. Mount it
echo "→ Mounting..."
MOUNT_DIR=$(hdiutil attach -readwrite -noverify "$DMG_TEMP" | grep "/Volumes/" | sed 's/.*\(\/Volumes\/.*\)/\1/')
echo "   Mounted at: $MOUNT_DIR"
# Защита: если имя всё же разъехалось (том «LocalSwitcher 1») — оформление уйдёт мимо. Прерываемся.
if [ "$MOUNT_DIR" != "/Volumes/${VOL_NAME}" ]; then
    echo "ERROR: temp DMG mounted at '$MOUNT_DIR', expected '/Volumes/${VOL_NAME}'."
    echo "       Stale volume collision — refusing to build an unstyled DMG."
    hdiutil detach "$MOUNT_DIR" -force 2>/dev/null || true
    exit 1
fi

# 3. The public installer exposes only TypeFlow.app.
echo "→ Copying app..."
cp -R "$APP_PATH" "$MOUNT_DIR/$VISIBLE_APP_NAME"
codesign --verify --deep --strict "$MOUNT_DIR/$VISIBLE_APP_NAME"
ln -sf /Applications "$MOUNT_DIR/Applications"

# 4. Create .background directory and copy background image
mkdir -p "$MOUNT_DIR/.background"
cp "$BACKGROUND" "$MOUNT_DIR/.background/background.png"

# 5. Apply Finder settings via AppleScript
echo "→ Configuring Finder view..."
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        -- The extra 30 pt is the Finder title bar; content remains the full 900x480.
        set bounds of container window to {100, 100, 1000, 610}

        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 96
        set text size of theViewOptions to 13
        set background picture of theViewOptions to file ".background:background.png"

        set position of item "$VISIBLE_APP_NAME" of container window to {260, 235}
        set position of item "Applications" of container window to {640, 235}

        close
        open

        update without registering applications
        delay 2
    end tell
end tell
APPLESCRIPT

# 6. Set volume icon
if [ -f "${PRODUCT_NAME}.icns" ]; then
    cp "${PRODUCT_NAME}.icns" "$MOUNT_DIR/.VolumeIcon.icns"
    SetFile -c icnC "$MOUNT_DIR/.VolumeIcon.icns" 2>/dev/null || true
    SetFile -a C "$MOUNT_DIR" 2>/dev/null || true
fi

# 7. Finalize permissions
chmod -Rf go-w "$MOUNT_DIR" 2>/dev/null || true
sync

# 7a. Проверяем, что Finder реально записал оформление. .DS_Store хранит фон и позиции
#     иконок; если его нет — DMG откроется голым. Лучше упасть, чем отдать кривой образ.
if [ ! -f "$MOUNT_DIR/.DS_Store" ]; then
    echo "ERROR: .DS_Store not written to $MOUNT_DIR — DMG styling did NOT apply."
    echo "       Refusing to ship an unstyled DMG."
    hdiutil detach "$MOUNT_DIR" -force 2>/dev/null || true
    exit 1
fi
echo "→ Styling OK (.DS_Store present)"

# 8. Unmount
echo "→ Unmounting..."
hdiutil detach "$MOUNT_DIR" -quiet
MOUNT_DIR=""

# 9. Convert to compressed read-only DMG
echo "→ Compressing..."
hdiutil convert "$DMG_TEMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_NAME"
rm -f "$DMG_TEMP"

# 9a. Build a separate minimal updater payload. It is never linked from the
# install instructions; old and new clients fetch it after verifying the signed
# manifest. Keeping it separate avoids leaking legacy naming into Finder.
echo "→ Creating compatibility updater DMG..."
cp -R "$APP_PATH" "$COMPAT_STAGE_DIR/$COMPAT_APP_NAME"
codesign --verify --deep --strict "$COMPAT_STAGE_DIR/$COMPAT_APP_NAME"
hdiutil create -volname "${PRODUCT_NAME} Update" -fs HFS+ \
    -srcfolder "$COMPAT_STAGE_DIR" -format UDZO "$COMPAT_DMG_NAME"

# 9b. Подписываем САМИ .dmg Developer ID. Без этого образ нотаризуется и стейплится, но
#     `spctl -t install` даёт "no usable signature" — у скачанного образа нет подписи
#     контейнера, и на части Mac это приводит к недоверию к вынутому из него .app.
SIGN_ID="${RS_SIGN_ID:--}"
if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    echo "→ Code signing the DMGs (Developer ID + secure timestamp)..."
    for image in "$DMG_NAME" "$COMPAT_DMG_NAME"; do
        codesign --force --timestamp --sign "$SIGN_ID" "$image"
        codesign --verify --verbose=2 "$image"
    done
fi

# 10. Notarize with Apple (required for Gatekeeper to accept the DMG on end-user Macs).
# Signed-but-unnotarized DMGs trigger "Apple could not verify [app] is free of malware".
if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    echo "→ SKIP_NOTARIZE=1 — skipping notarization (DMG will NOT pass Gatekeeper on other Macs)"
else
    for image in "$DMG_NAME" "$COMPAT_DMG_NAME"; do
        echo "→ Submitting $image to Apple notary service ($NOTARY_VIA)..."
        xcrun notarytool submit "$image" "${NOTARY_ARGS[@]}" --wait
        xcrun stapler staple "$image"
        xcrun stapler validate "$image"
        spctl -a -vvv -t install "$image" 2>&1 || echo "WARNING: spctl install assessment did not pass for $image"
    done
fi

# 11. sha256 is the updater payload bound to old and new clients. public_sha256
#     separately publishes the digest of the human-facing permanent download.
DMG_SHA=$(shasum -a 256 "$DMG_NAME" | awk '{print $1}')
COMPAT_DMG_SHA=$(shasum -a 256 "$COMPAT_DMG_NAME" | awk '{print $1}')
if [ "$BETA" = "1" ]; then
    # Бета: пишем sha ТОЛЬКО в version-beta.json. Стабильный version.json и cask не трогаем
    # (Homebrew отслеживает стабильные релизы; беты идут только через встроенный апдейтер).
    echo "→ Writing sha256 into $VERSION_FILE (beta feed only; stable version.json/cask untouched)..."
    /usr/bin/python3 - "$COMPAT_DMG_SHA" "$DMG_SHA" "$VERSION_FILE" <<'PY'
import json, sys
sha, public_sha, path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    data = json.load(f)
data["sha256"] = sha
data["public_sha256"] = public_sha
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
else
    echo "→ Writing sha256 into version.json..."
    /usr/bin/python3 - "$COMPAT_DMG_SHA" "$DMG_SHA" <<'PY'
import json, sys
sha, public_sha = sys.argv[1], sys.argv[2]
with open("../version.json") as f:
    data = json.load(f)
data["sha256"] = sha
data["public_sha256"] = public_sha
with open("../version.json", "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
    CASK_FILE="$SCRIPT_DIR/localswitcher.rb"
    if [ -f "$CASK_FILE" ]; then
        echo "→ Updating optional Homebrew cask..."
        /usr/bin/sed -i '' -E "s/^([[:space:]]*sha256 \").*(\")/\1${DMG_SHA}\2/" "$CASK_FILE"
        /usr/bin/sed -i '' -E "s/^([[:space:]]*version \").*(\")/\1${VERSION}\2/" "$CASK_FILE"

        # sed при отсутствии совпадения выходит с кодом 0, поэтому проверяем результат.
        if ! grep -q "sha256 \"${DMG_SHA}\"" "$CASK_FILE" || ! grep -q "version \"${VERSION}\"" "$CASK_FILE"; then
            echo "ERROR: cask update via sed did not take (format drift in localswitcher.rb?). Aborting." >&2
            exit 1
        fi
    fi
fi

# Манифест публикуется только с detached RSA/SHA-256 подписью. Приватный ключ
# берётся из Keychain и никогда не хранится в репозитории.
echo "→ Signing update manifest..."
"$SCRIPT_DIR/../scripts/sign_update_manifest.swift" "$SCRIPT_DIR/$VERSION_FILE"

echo ""
echo "=== Done! ==="
echo "DMG: $(pwd)/$DMG_NAME ($(du -h "$DMG_NAME" | cut -f1))"
echo "Compatibility DMG: $(pwd)/$COMPAT_DMG_NAME"
echo "Public SHA256: $DMG_SHA"
echo "Updater SHA256: $COMPAT_DMG_SHA"
echo "→ Update manifest signed and bound to both release artifacts."
