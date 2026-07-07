// Symlink the in-repo module into node_modules so Metro/JS bundling resolves
// `expo-mpv` (native autolinking uses nativeModulesDir=".."). Runs on postinstall.
const fs = require('fs');
const path = require('path');

const repoRoot = path.resolve(__dirname, '..', '..');
const link = path.resolve(__dirname, '..', 'node_modules', 'expo-mpv');

try {
  fs.rmSync(link, { recursive: true, force: true });
} catch {}
try {
  fs.mkdirSync(path.dirname(link), { recursive: true });
  fs.symlinkSync(path.relative(path.dirname(link), repoRoot), link, 'dir');
  console.log('[link-module] expo-mpv -> ' + path.relative(path.dirname(link), repoRoot));
} catch (e) {
  console.warn('[link-module] failed:', e.message);
}
