const { defineConfig } = require('eslint/config');
const baseConfig = require('expo-module-scripts/eslint.config.base');

const commonjsGlobals = {
  __dirname: 'readonly',
  __filename: 'readonly',
  exports: 'readonly',
  module: 'readonly',
  process: 'readonly',
  require: 'readonly',
};

module.exports = defineConfig([
  baseConfig,
  {
    files: [
      '*.config.cjs',
      '*.config.js',
      'app.plugin.js',
      'example/*.config.js',
      'example/scripts/*.cjs',
    ],
    languageOptions: {
      globals: commonjsGlobals,
      sourceType: 'commonjs',
    },
  },
]);
