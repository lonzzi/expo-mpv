import { registerWebModule, NativeModule } from 'expo';

import { ExpoMpvModuleEvents } from './ExpoMpv.types';

class ExpoMpvModule extends NativeModule<ExpoMpvModuleEvents> {
  PI = Math.PI;
  async setValueAsync(value: string): Promise<void> {
    this.emit('onChange', { value });
  }
  hello() {
    return 'Hello world! 👋';
  }
}

export default registerWebModule(ExpoMpvModule, 'ExpoMpvModule');
