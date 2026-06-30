#ifndef NUDISCO_BRIDGING_HEADER_H
#define NUDISCO_BRIDGING_HEADER_H

// stasel/WebRTC ships the custom-audio API (RTCAudioDevice + the
// RTCPeerConnectionFactory `audioDevice:` initializer) for iOS, but its **macOS**
// slice omits RTCAudioDevice.h from the framework headers/umbrella — even though
// the macOS *binary* implements it (the `audioDevice:` initializer is present in
// the macOS RTCPeerConnectionFactory.h). So on macOS, Swift can't see the
// protocol and you get "Cannot find type 'RTCAudioDevice' in scope".
//
// Fix: vendor the ABI-matched header from the SAME package's iOS slice
// (Vendor/RTCAudioDevice.h, BSD-licensed upstream WebRTC) and expose it here. It
// has no iOS-only dependencies (AudioUnit + Foundation + <WebRTC/RTCMacros.h>),
// so it compiles cleanly for macOS and completes the protocol the macOS
// RTCPeerConnectionFactory.h forward-declares. See mac/README.md (Spike 0).
#import "RTCAudioDevice.h"

#endif /* NUDISCO_BRIDGING_HEADER_H */
