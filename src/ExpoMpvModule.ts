import { NativeModule, requireNativeModule } from 'expo';

import { ExpoMpvModuleEvents } from './ExpoMpv.types';

declare class ExpoMpvModule extends NativeModule<ExpoMpvModuleEvents> {
  PI: number;
  hello(): string;
  setValueAsync(value: string): Promise<void>;
}

// This call loads the native module object from the JSI.
export default requireNativeModule<ExpoMpvModule>('ExpoMpv');
