import ExpoMpvModule from './ExpoMpvModule';

export { ExpoMpvModule as default };
export { default as ExpoMpvView } from './ExpoMpvView';
export * from './ExpoMpv.types';

/** Convert a local WOFF2 file to a local OpenType/TrueType file off the UI thread. */
export function decodeWoff2(inputUri: string, outputUri: string): Promise<void> {
  return ExpoMpvModule.decodeWoff2(inputUri, outputUri);
}

/** Read the family names stored in a local TTF, OTF, TTC, or WOFF font. */
export function fontFamilies(uri: string): Promise<string[]> {
  return ExpoMpvModule.fontFamilies(uri);
}
