import { NativeModule, requireNativeModule } from 'expo';

import { ExpoMpvModuleEvents } from './ExpoMpv.types';

declare class ExpoMpvModule extends NativeModule<ExpoMpvModuleEvents> {}

// This call loads the native module object from the JSI.
export default requireNativeModule<ExpoMpvModule>('ExpoMpv');
