// Reexport the native module. On web, it will be resolved to ExpoMpvModule.web.ts
// and on native platforms to ExpoMpvModule.ts
export { default } from './ExpoMpvModule';
export { default as ExpoMpvView } from './ExpoMpvView';
export * from  './ExpoMpv.types';
