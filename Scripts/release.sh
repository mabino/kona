#!/bin/bash

# Release script for Kona
# Builds, notarizes, and publishes a release to GitHub
#
# Prerequisites:
#   - Apple Developer ID Application certificate in keychain
#   - gh CLI authenticated
#   - App-specific password from appleid.apple.com (under Sign-In and Security)
#
# The script will:
#   - Auto-detect Developer ID certificate and derive Team ID
#   - Prompt for Apple ID and app-specific password if not provided
#
# Environment variables (optional, will prompt if missing):
#   DEVELOPER_ID     - Developer ID for code signing (default: auto-detect)
#   APPLE_ID         - Apple ID for notarization
#   TEAM_ID          - Apple Developer Team ID (default: derived from certificate)
#   APP_PASSWORD     - App-specific password for notarization
#   KEYCHAIN_PROFILE - Notarytool keychain profile name (skips prompts)
#
# Usage:
#   ./Scripts/release.sh <version>
#   ./Scripts/release.sh 1.0.0
#   ./Scripts/release.sh 1.2.0 --draft

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="Kona"
BUNDLE_ID="com.example.Kona"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Parse arguments
VERSION=""
DRAFT_FLAG=""
SKIP_NOTARIZE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --draft)
            DRAFT_FLAG="--draft"
            shift
            ;;
        --skip-notarize)
            SKIP_NOTARIZE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 <version> [options]"
            echo ""
            echo "Arguments:"
            echo "  version          Version number (e.g., 1.0.0)"
            echo ""
            echo "Options:"
            echo "  --draft          Create as draft release"
            echo "  --skip-notarize  Skip notarization (for testing)"
            echo "  -h, --help       Show this help message"
            echo ""
            echo "Environment variables:"
            echo "  DEVELOPER_ID     Developer ID for code signing"
            echo "  KEYCHAIN_PROFILE Notarytool keychain profile name"
            echo "  APPLE_ID         Apple ID (alternative to KEYCHAIN_PROFILE)"
            echo "  TEAM_ID          Apple Developer Team ID"
            echo "  APP_PASSWORD     App-specific password"
            exit 0
            ;;
        *)
            if [[ -z "$VERSION" ]]; then
                VERSION="$1"
            else
                log_error "Unknown argument: $1"
            fi
            shift
            ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    log_error "Version number required. Usage: $0 <version>"
fi

# Validate version format
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log_error "Invalid version format. Expected: X.Y.Z (e.g., 1.0.0)"
fi

log_info "Preparing release v${VERSION} of ${APP_NAME}..."

cd "$PROJECT_DIR"

# Check for uncommitted changes
if [[ -n $(git status --porcelain) ]]; then
    log_warning "You have uncommitted changes. Consider committing before release."
fi

# Check gh authentication
if ! gh auth status &>/dev/null; then
    log_error "gh CLI not authenticated. Run 'gh auth login' first."
fi

# Check if tag already exists
if git rev-parse "v${VERSION}" &>/dev/null; then
    log_warning "Tag v${VERSION} already exists."
    echo -n "Overwrite existing tag and release? [y/N]: "
    read -r OVERWRITE
    if [[ "$OVERWRITE" =~ ^[Yy]$ ]]; then
        log_info "Deleting existing tag v${VERSION}..."
        git tag -d "v${VERSION}"
        git push origin --delete "v${VERSION}" 2>/dev/null || true
        gh release delete "v${VERSION}" --yes 2>/dev/null || true
    else
        log_error "Release cancelled. Choose a different version."
    fi
fi

# ============================================================================
# Step 1: Build Release
# ============================================================================

log_info "Building release..."

swift build --configuration release

BUILD_DIR=".build/arm64-apple-macosx/release"
EXECUTABLE="$BUILD_DIR/$APP_NAME"

if [[ ! -f "$EXECUTABLE" ]]; then
    # Try x86_64 build dir
    BUILD_DIR=".build/x86_64-apple-macosx/release"
    EXECUTABLE="$BUILD_DIR/$APP_NAME"
fi

if [[ ! -f "$EXECUTABLE" ]]; then
    log_error "Build failed - executable not found"
fi

log_success "Build complete"

# ============================================================================
# Step 2: Create App Bundle
# ============================================================================

log_info "Creating app bundle..."

BUNDLE_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Copy executable
cp "$EXECUTABLE" "$MACOS_DIR/$APP_NAME"

# Copy icon if exists
if [[ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

# Create Info.plist with version
cat > "$CONTENTS_DIR/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

log_success "App bundle created at: $BUNDLE_DIR"

# ============================================================================
# Step 3: Code Signing
# ============================================================================

log_info "Code signing..."

# Find Developer ID certificate
if [[ -z "$DEVELOPER_ID" ]]; then
    DEVELOPER_ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/' || true)
fi

if [[ -z "$DEVELOPER_ID" ]]; then
    log_warning "No Developer ID certificate found. Signing with ad-hoc signature."
    codesign --force --deep --sign - "$BUNDLE_DIR"
else
    log_info "Signing with: $DEVELOPER_ID"
    codesign --force --deep --options runtime --sign "$DEVELOPER_ID" "$BUNDLE_DIR"
fi

# Verify signature
codesign --verify --verbose "$BUNDLE_DIR" || log_warning "Signature verification had warnings"

log_success "Code signing complete"

# ============================================================================
# Step 4: Notarization
# ============================================================================

if [[ "$SKIP_NOTARIZE" == true ]]; then
    log_warning "Skipping notarization (--skip-notarize flag set)"
else
    log_info "Preparing for notarization..."
    
    # Create ZIP for notarization
    ZIP_PATH="$BUILD_DIR/${APP_NAME}-${VERSION}.zip"
    ditto -c -k --keepParent "$BUNDLE_DIR" "$ZIP_PATH"
    
    # Derive Team ID from Developer ID certificate if not set
    if [[ -z "$TEAM_ID" && -n "$DEVELOPER_ID" ]]; then
        # Extract Team ID from certificate name (e.g., "Developer ID Application: Name (TEAM_ID)")
        TEAM_ID=$(echo "$DEVELOPER_ID" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')
        if [[ -n "$TEAM_ID" ]]; then
            log_info "Derived Team ID from certificate: $TEAM_ID"
        fi
    fi
    
    # Interactive prompts for missing credentials
    if [[ -z "$KEYCHAIN_PROFILE" && (-z "$APPLE_ID" || -z "$APP_PASSWORD") ]]; then
        echo ""
        log_info "Notarization credentials required."
        echo ""
        
        # Prompt for Apple ID if not set
        if [[ -z "$APPLE_ID" ]]; then
            echo -n "Enter your Apple ID (email): "
            read -r APPLE_ID
            if [[ -z "$APPLE_ID" ]]; then
                log_error "Apple ID is required for notarization."
            fi
        fi
        
        # Prompt for app-specific password if not set
        if [[ -z "$APP_PASSWORD" ]]; then
            echo -n "Enter app-specific password: "
            read -rs APP_PASSWORD
            echo ""
            if [[ -z "$APP_PASSWORD" ]]; then
                log_error "App-specific password is required for notarization."
            fi
        fi
        
        echo ""
    fi
    
    if [[ -n "$KEYCHAIN_PROFILE" ]]; then
        log_info "Notarizing with keychain profile: $KEYCHAIN_PROFILE"
        xcrun notarytool submit "$ZIP_PATH" \
            --keychain-profile "$KEYCHAIN_PROFILE" \
            --wait
    elif [[ -n "$APPLE_ID" && -n "$TEAM_ID" && -n "$APP_PASSWORD" ]]; then
        log_info "Notarizing with Apple ID: $APPLE_ID (Team: $TEAM_ID)..."
        xcrun notarytool submit "$ZIP_PATH" \
            --apple-id "$APPLE_ID" \
            --team-id "$TEAM_ID" \
            --password "$APP_PASSWORD" \
            --wait
    else
        log_error "Missing notarization credentials. Need APPLE_ID, TEAM_ID, and APP_PASSWORD."
    fi
    
    # Staple the notarization ticket
    log_info "Stapling notarization ticket..."
    xcrun stapler staple "$BUNDLE_DIR"
    log_success "Notarization complete"
fi

# ============================================================================
# Step 5: Create Release Archive
# ============================================================================

log_info "Creating release archive..."

RELEASE_DIR="$BUILD_DIR/release"
RELEASE_ZIP="${APP_NAME}-${VERSION}.zip"

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

# Create final ZIP
ditto -c -k --keepParent "$BUNDLE_DIR" "$RELEASE_DIR/$RELEASE_ZIP"

# Create SHA256 checksum
cd "$RELEASE_DIR"
shasum -a 256 "$RELEASE_ZIP" > "$RELEASE_ZIP.sha256"
cd "$PROJECT_DIR"

log_success "Release archive created: $RELEASE_DIR/$RELEASE_ZIP"

# ============================================================================
# Step 6: Create Git Tag
# ============================================================================

log_info "Creating git tag v${VERSION}..."

git tag -a "v${VERSION}" -m "Release v${VERSION}"

log_success "Tag v${VERSION} created"

# ============================================================================
# Step 7: Push Tag and Create GitHub Release
# ============================================================================

log_info "Pushing tag to remote..."

git push origin "v${VERSION}"

log_info "Creating GitHub release..."

RELEASE_NOTES="## ${APP_NAME} v${VERSION}

### Installation

1. Download \`${RELEASE_ZIP}\` below
2. Unzip and drag \`${APP_NAME}.app\` to your Applications folder
3. Right-click and select Open (first launch only, to bypass Gatekeeper)

### Checksums

\`\`\`
$(cat "$RELEASE_DIR/$RELEASE_ZIP.sha256")
\`\`\`
"

gh release create "v${VERSION}" \
    "$RELEASE_DIR/$RELEASE_ZIP" \
    "$RELEASE_DIR/$RELEASE_ZIP.sha256" \
    --title "v${VERSION}" \
    --notes "$RELEASE_NOTES" \
    $DRAFT_FLAG

log_success "GitHub release created!"

# ============================================================================
# Done
# ============================================================================

echo ""
log_success "🎉 Release v${VERSION} published successfully!"
echo ""
echo "Release URL: https://github.com/mabino/kona/releases/tag/v${VERSION}"
echo ""
