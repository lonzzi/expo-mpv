import { NativeModule, requireNativeModule } from 'expo';

import type { ExpoMpvModuleEvents } from './ExpoMpv.types';

declare class ExpoMpvModule extends NativeModule<ExpoMpvModuleEvents> {
  decodeWoff2(inputUri: string, outputUri: string): Promise<void>;
  fontFamilies(uri: string): Promise<string[]>;
}

// This call loads the native module object from the JSI.
export default requireNativeModule<ExpoMpvModule>('ExpoMpv');
