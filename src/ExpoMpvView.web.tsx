import * as React from 'react';

import { ExpoMpvViewProps } from './ExpoMpv.types';

export default function ExpoMpvView(props: ExpoMpvViewProps) {
  return (
    <div>
      <iframe
        style={{ flex: 1 }}
        src={props.url}
        onLoad={() => props.onLoad({ nativeEvent: { url: props.url } })}
      />
    </div>
  );
}
