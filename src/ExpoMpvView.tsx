import { requireNativeView } from 'expo';
import * as React from 'react';

import { ExpoMpvViewProps } from './ExpoMpv.types';

const NativeView: React.ComponentType<ExpoMpvViewProps> =
  requireNativeView('ExpoMpv');

export default function ExpoMpvView(props: ExpoMpvViewProps) {
  return <NativeView {...props} />;
}
