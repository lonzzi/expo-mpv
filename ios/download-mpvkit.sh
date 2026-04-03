#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XCFW_DIR="${SCRIPT_DIR}/Frameworks"
MPVKIT_VERSION="0.41.0"
LOCKFILE="${XCFW_DIR}/.version"

# Check if already downloaded at the right version
if [ -f "${LOCKFILE}" ] && [ "$(cat ${LOCKFILE})" = "${MPVKIT_VERSION}" ]; then
  echo "✅ MPVKit ${MPVKIT_VERSION} xcframeworks already present."
  exit 0
fi

echo "🔽 Downloading MPVKit ${MPVKIT_VERSION} xcframeworks..."
rm -rf "${XCFW_DIR}"
mkdir -p "${XCFW_DIR}"

MPVKIT_URL="https://github.com/mpvkit/MPVKit/releases/download/${MPVKIT_VERSION}"

download_xcframework() {
  local name=$1
  local url=$2
  echo "  📦 ${name}..."
  curl -sL "${url}" -o "${XCFW_DIR}/${name}.zip"
  unzip -q -o "${XCFW_DIR}/${name}.zip" -d "${XCFW_DIR}/"
  rm -f "${XCFW_DIR}/${name}.zip"
}

# Core MPVKit - libmpv
download_xcframework "Libmpv" "${MPVKIT_URL}/Libmpv.xcframework.zip"

# FFmpeg frameworks
for lib in Libavcodec Libavdevice Libavformat Libavfilter Libavutil Libswresample Libswscale; do
  download_xcframework "${lib}" "${MPVKIT_URL}/${lib}.xcframework.zip"
done

# OpenSSL
OPENSSL_VERSION="3.3.5"
for lib in Libcrypto Libssl; do
  download_xcframework "${lib}" "https://github.com/mpvkit/openssl-build/releases/download/${OPENSSL_VERSION}/${lib}.xcframework.zip"
done

# GnuTLS
GNUTLS_VERSION="3.8.11"
for lib in gmp nettle hogweed gnutls; do
  download_xcframework "${lib}" "https://github.com/mpvkit/gnutls-build/releases/download/${GNUTLS_VERSION}/${lib}.xcframework.zip"
done

# Libass and dependencies
LIBASS_VERSION="0.17.4"
for lib in Libunibreak Libfreetype Libfribidi Libharfbuzz Libass; do
  download_xcframework "${lib}" "https://github.com/mpvkit/libass-build/releases/download/${LIBASS_VERSION}/${lib}.xcframework.zip"
done

# MoltenVK (Vulkan on Metal)
download_xcframework "MoltenVK" "https://github.com/mpvkit/moltenvk-build/releases/download/1.4.1/MoltenVK.xcframework.zip"

# Shaderc
download_xcframework "Libshaderc_combined" "https://github.com/mpvkit/libshaderc-build/releases/download/2025.5.0/Libshaderc_combined.xcframework.zip"

# lcms2
download_xcframework "lcms2" "https://github.com/mpvkit/lcms2-build/releases/download/2.17.0/lcms2.xcframework.zip"

# Libplacebo
download_xcframework "Libplacebo" "https://github.com/mpvkit/libplacebo-build/releases/download/7.351.0-2512/Libplacebo.xcframework.zip"

# Libdav1d
download_xcframework "Libdav1d" "https://github.com/mpvkit/libdav1d-build/releases/download/1.5.2-xcode/Libdav1d.xcframework.zip"

# Libuchardet
download_xcframework "Libuchardet" "https://github.com/mpvkit/libuchardet-build/releases/download/0.0.8-xcode/Libuchardet.xcframework.zip"

# Libbluray
download_xcframework "Libbluray" "https://github.com/mpvkit/libbluray-build/releases/download/1.4.0/Libbluray.xcframework.zip"

# Libdovi
download_xcframework "Libdovi" "https://github.com/mpvkit/libdovi-build/releases/download/3.3.2/Libdovi.xcframework.zip"

# Libuavs3d (uAVS3 decoder)
download_xcframework "Libuavs3d" "https://github.com/mpvkit/libuavs3d-build/releases/download/1.2.1-xcode/Libuavs3d.xcframework.zip"

echo "${MPVKIT_VERSION}" > "${LOCKFILE}"
echo ""
echo "✅ All MPVKit ${MPVKIT_VERSION} xcframeworks downloaded to ${XCFW_DIR}"
