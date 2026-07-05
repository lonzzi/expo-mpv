"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const config_plugins_1 = require("expo/config-plugins");
const child_process_1 = require("child_process");
const path_1 = __importDefault(require("path"));
const fs_1 = __importDefault(require("fs"));
const https_1 = __importDefault(require("https"));
const MPVKIT_VERSION = '0.41.0';
function getFrameworkSources() {
    const mpvkit = `https://github.com/mpvkit/MPVKit/releases/download/${MPVKIT_VERSION}`;
    const openssl = 'https://github.com/mpvkit/openssl-build/releases/download/3.3.5';
    const gnutls = 'https://github.com/mpvkit/gnutls-build/releases/download/3.8.11';
    const libass = 'https://github.com/mpvkit/libass-build/releases/download/0.17.4';
    return [
        // Core
        { name: 'Libmpv', url: `${mpvkit}/Libmpv.xcframework.zip` },
        // FFmpeg
        ...['Libavcodec', 'Libavdevice', 'Libavformat', 'Libavfilter', 'Libavutil', 'Libswresample', 'Libswscale'].map((name) => ({ name, url: `${mpvkit}/${name}.xcframework.zip` })),
        // OpenSSL
        { name: 'Libcrypto', url: `${openssl}/Libcrypto.xcframework.zip` },
        { name: 'Libssl', url: `${openssl}/Libssl.xcframework.zip` },
        // GnuTLS
        ...['gmp', 'nettle', 'hogweed', 'gnutls'].map((name) => ({
            name,
            url: `${gnutls}/${name}.xcframework.zip`,
        })),
        // Libass + deps
        ...['Libunibreak', 'Libfreetype', 'Libfribidi', 'Libharfbuzz', 'Libass'].map((name) => ({
            name,
            url: `${libass}/${name}.xcframework.zip`,
        })),
        // Others
        { name: 'MoltenVK', url: 'https://github.com/mpvkit/moltenvk-build/releases/download/1.4.1/MoltenVK.xcframework.zip' },
        { name: 'Libshaderc_combined', url: 'https://github.com/mpvkit/libshaderc-build/releases/download/2025.5.0/Libshaderc_combined.xcframework.zip' },
        { name: 'lcms2', url: 'https://github.com/mpvkit/lcms2-build/releases/download/2.17.0/lcms2.xcframework.zip' },
        { name: 'Libplacebo', url: 'https://github.com/mpvkit/libplacebo-build/releases/download/7.351.0-2512/Libplacebo.xcframework.zip' },
        { name: 'Libdav1d', url: 'https://github.com/mpvkit/libdav1d-build/releases/download/1.5.2-xcode/Libdav1d.xcframework.zip' },
        { name: 'Libuchardet', url: 'https://github.com/mpvkit/libuchardet-build/releases/download/0.0.8-xcode/Libuchardet.xcframework.zip' },
        { name: 'Libbluray', url: 'https://github.com/mpvkit/libbluray-build/releases/download/1.4.0/Libbluray.xcframework.zip' },
        { name: 'Libdovi', url: 'https://github.com/mpvkit/libdovi-build/releases/download/3.3.2/Libdovi.xcframework.zip' },
        { name: 'Libuavs3d', url: 'https://github.com/mpvkit/libuavs3d-build/releases/download/1.2.1-xcode/Libuavs3d.xcframework.zip' },
    ];
}
function download(url, dest) {
    return new Promise((resolve, reject) => {
        const file = fs_1.default.createWriteStream(dest);
        const request = (url) => {
            https_1.default.get(url, (res) => {
                if (res.statusCode === 301 || res.statusCode === 302) {
                    request(res.headers.location);
                    return;
                }
                if (res.statusCode !== 200) {
                    reject(new Error(`Failed to download ${url}: ${res.statusCode}`));
                    return;
                }
                res.pipe(file);
                file.on('finish', () => { file.close(); resolve(); });
            }).on('error', reject);
        };
        request(url);
    });
}
async function downloadFramework(source, frameworksDir) {
    const zipPath = path_1.default.join(frameworksDir, `${source.name}.zip`);
    await download(source.url, zipPath);
    (0, child_process_1.execSync)(`unzip -q -o "${zipPath}" -d "${frameworksDir}"`, { stdio: 'pipe' });
    fs_1.default.unlinkSync(zipPath);
}
async function downloadMPVKit(frameworksDir) {
    const lockfile = path_1.default.join(frameworksDir, '.version');
    if (fs_1.default.existsSync(lockfile) && fs_1.default.readFileSync(lockfile, 'utf-8').trim() === MPVKIT_VERSION) {
        console.log(`[expo-mpv] MPVKit ${MPVKIT_VERSION} already downloaded.`);
        return;
    }
    console.log(`[expo-mpv] Downloading MPVKit ${MPVKIT_VERSION} XCFrameworks...`);
    fs_1.default.rmSync(frameworksDir, { recursive: true, force: true });
    fs_1.default.mkdirSync(frameworksDir, { recursive: true });
    const sources = getFrameworkSources();
    for (const source of sources) {
        console.log(`  ${source.name}...`);
        await downloadFramework(source, frameworksDir);
    }
    fs_1.default.writeFileSync(lockfile, MPVKIT_VERSION);
    console.log(`[expo-mpv] All MPVKit ${MPVKIT_VERSION} XCFrameworks downloaded.`);
}
const withExpoMpv = (config) => {
    // iOS: download MPVKit xcframeworks during prebuild
    config = (0, config_plugins_1.withDangerousMod)(config, [
        'ios',
        async (config) => {
            const packageDir = path_1.default.dirname(require.resolve('expo-mpv/package.json'));
            const frameworksDir = path_1.default.join(packageDir, 'ios', 'Frameworks');
            await downloadMPVKit(frameworksDir);
            return config;
        },
    ]);
    // Android: native libraries are downloaded automatically by Gradle build task
    // (see android/build.gradle → downloadMpvNativeLibs task)
    // No separate script or plugin step needed!
    return config;
};
exports.default = withExpoMpv;
