// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version.

//! Small interface surfaces which Chrome exposes but Lightpanda does not yet
//! implement. The interfaces are intentionally behavior-free until their
//! backing browser features exist; their shape still matters to feature
//! detection and Web IDL reflection.

const js = @import("../js/js.zig");

const CSSRule = @import("css/CSSRule.zig");
const EventTarget = @import("EventTarget.zig");
const Svg = @import("element/Svg.zig");

pub const early_global_names = [_][]const u8{
    "window",
    "self",
    "document",
    "name",
    "location",
    "customElements",
    "history",
    "navigation",
    "locationbar",
    "menubar",
    "personalbar",
    "scrollbars",
    "statusbar",
    "toolbar",
    "status",
    "closed",
    "frames",
    "length",
    "top",
    "opener",
    "parent",
    "frameElement",
    "navigator",
    "origin",
    "external",
    "screen",
    "innerWidth",
    "innerHeight",
    "scrollX",
    "pageXOffset",
    "scrollY",
    "pageYOffset",
    "visualViewport",
    "screenX",
    "screenY",
    "outerWidth",
    "outerHeight",
    "devicePixelRatio",
    "event",
    "clientInformation",
    "offscreenBuffering",
    "screenLeft",
    "screenTop",
    "styleMedia",
    "onsearch",
    "onappinstalled",
    "onbeforeinstallprompt",
    "onabort",
    "onbeforeinput",
    "onbeforematch",
    "onbeforetoggle",
    "onblur",
    "oncancel",
    "oncanplay",
    "oncanplaythrough",
    "onchange",
    "onclick",
    "onclose",
    "oncommand",
    "oncontentvisibilityautostatechange",
    "oncontextlost",
    "oncontextmenu",
    "oncontextrestored",
    "oncuechange",
    "ondblclick",
    "ondrag",
    "ondragend",
    "ondragenter",
    "ondragleave",
    "ondragover",
    "ondragstart",
    "ondrop",
    "ondurationchange",
    "onemptied",
    "onended",
    "onerror",
    "onfocus",
    "onformdata",
    "oninput",
    "oninvalid",
    "onkeydown",
    "onkeypress",
    "onkeyup",
    "onload",
    "onloadeddata",
    "onloadedmetadata",
    "onloadstart",
    "onmousedown",
    "onmouseenter",
    "onmouseleave",
    "onmousemove",
    "onmouseout",
    "onmouseover",
    "onmouseup",
    "onmousewheel",
    "onpause",
    "onplay",
    "onplaying",
    "onprogress",
    "onratechange",
    "onreset",
    "onresize",
    "onscroll",
    "onscrollend",
    "onsecuritypolicyviolation",
    "onseeked",
    "onseeking",
    "onselect",
    "onslotchange",
    "onstalled",
    "onsubmit",
    "onsuspend",
    "ontimeupdate",
    "ontoggle",
    "onvolumechange",
    "onwaiting",
    "onwebkitanimationend",
    "onwebkitanimationiteration",
    "onwebkitanimationstart",
    "onwebkittransitionend",
    "onwheel",
    "onauxclick",
    "ongotpointercapture",
    "onlostpointercapture",
    "onpointerdown",
    "onpointermove",
    "onpointerup",
    "onpointercancel",
    "onpointerover",
    "onpointerout",
    "onpointerenter",
    "onpointerleave",
    "onselectstart",
    "onselectionchange",
    "onanimationcancel",
    "onanimationend",
    "onanimationiteration",
    "onanimationstart",
    "ontransitionrun",
    "ontransitionstart",
    "ontransitionend",
    "ontransitioncancel",
    "onbeforexrselect",
    "onafterprint",
    "onbeforeprint",
    "onbeforeunload",
    "onhashchange",
    "onlanguagechange",
    "onmessage",
    "onmessageerror",
    "onoffline",
    "ononline",
    "onpagehide",
    "onpageshow",
    "onpopstate",
    "onrejectionhandled",
    "onstorage",
    "onunhandledrejection",
    "onunload",
    "isSecureContext",
    "crossOriginIsolated",
    "scheduler",
    "performance",
    "trustedTypes",
    "crypto",
    "indexedDB",
    "localStorage",
    "sessionStorage",
    "alert",
    "atob",
    "blur",
    "btoa",
    "cancelAnimationFrame",
    "cancelIdleCallback",
    "captureEvents",
    "clearInterval",
    "clearTimeout",
    "close",
    "confirm",
    "createImageBitmap",
    "fetch",
    "find",
    "focus",
    "getComputedStyle",
    "getSelection",
    "matchMedia",
    "moveBy",
    "moveTo",
    "open",
    "postMessage",
    "print",
    "prompt",
    "queueMicrotask",
    "releaseEvents",
    "reportError",
    "requestAnimationFrame",
    "requestIdleCallback",
    "resizeBy",
    "resizeTo",
    "scroll",
    "scrollBy",
    "scrollTo",
    "setInterval",
    "setTimeout",
    "stop",
    "structuredClone",
    "webkitCancelAnimationFrame",
    "webkitRequestAnimationFrame",
};

pub const late_global_names = [_][]const u8{
    "locationbar",
    "menubar",
    "personalbar",
    "scrollbars",
    "statusbar",
    "toolbar",
    "status",
    "external",
    "screenX",
    "screenY",
    "devicePixelRatio",
    "clientInformation",
    "offscreenBuffering",
    "screenLeft",
    "screenTop",
    "styleMedia",
    "onsearch",
    "onappinstalled",
    "onbeforeinstallprompt",
    "onabort",
    "onbeforeinput",
    "onbeforematch",
    "onbeforetoggle",
    "oncancel",
    "oncanplay",
    "oncanplaythrough",
    "onchange",
    "onclose",
    "oncommand",
    "oncontentvisibilityautostatechange",
    "oncontextlost",
    "oncontextmenu",
    "oncontextrestored",
    "oncuechange",
    "ondblclick",
    "ondrag",
    "ondragend",
    "ondragenter",
    "ondragleave",
    "ondragover",
    "ondragstart",
    "ondrop",
    "ondurationchange",
    "onemptied",
    "onended",
    "onformdata",
    "oninput",
    "oninvalid",
    "onkeydown",
    "onkeypress",
    "onkeyup",
    "onloadeddata",
    "onloadedmetadata",
    "onloadstart",
    "onmousedown",
    "onmouseenter",
    "onmouseleave",
    "onmousemove",
    "onmouseout",
    "onmouseover",
    "onmouseup",
    "onmousewheel",
    "onpause",
    "onplay",
    "onplaying",
    "onprogress",
    "onratechange",
    "onreset",
    "onscrollend",
    "onsecuritypolicyviolation",
    "onseeked",
    "onseeking",
    "onselect",
    "onslotchange",
    "onstalled",
    "onsubmit",
    "onsuspend",
    "ontimeupdate",
    "ontoggle",
    "onvolumechange",
    "onwaiting",
    "onwebkitanimationend",
    "onwebkitanimationiteration",
    "onwebkitanimationstart",
    "onwebkittransitionend",
    "onwheel",
    "onauxclick",
    "ongotpointercapture",
    "onlostpointercapture",
    "onpointerdown",
    "onpointermove",
    "onpointerup",
    "onpointercancel",
    "onpointerover",
    "onpointerout",
    "onpointerenter",
    "onpointerleave",
    "onselectstart",
    "onselectionchange",
    "onanimationcancel",
    "onanimationend",
    "onanimationiteration",
    "onanimationstart",
    "ontransitionrun",
    "ontransitionstart",
    "ontransitionend",
    "ontransitioncancel",
    "onbeforexrselect",
    "onafterprint",
    "onbeforeprint",
    "onbeforeunload",
    "onlanguagechange",
    "onmessageerror",
    "onoffline",
    "ononline",
    "onpagehide",
    "onstorage",
    "onunload",
    "crossOriginIsolated",
    "captureEvents",
    "find",
    "moveBy",
    "moveTo",
    "print",
    "releaseEvents",
    "resizeBy",
    "resizeTo",
    "stop",
    "webkitCancelAnimationFrame",
    "webkitRequestAnimationFrame",
    "Temporal",
    "crashReport",
    "ondevicemotion",
    "ondeviceorientation",
    "ondeviceorientationabsolute",
    "onpointerrawupdate",
    "caches",
    "documentPictureInPicture",
    "sharedStorage",
    "AbsoluteOrientationSensor",
    "Accelerometer",
    "AudioDecoder",
    "AudioEncoder",
    "AudioWorklet",
    "Cache",
    "CacheStorage",
    "Clipboard",
    "ClipboardChangeEvent",
    "ClipboardItem",
    "CookieStoreManager",
    "CreateMonitor",
    "Credential",
    "CredentialsContainer",
    "DeviceMotionEventAcceleration",
    "DeviceMotionEventRotationRate",
    "FederatedCredential",
    "GPU",
    "GPUAdapter",
    "GPUAdapterInfo",
    "GPUBindGroup",
    "GPUBindGroupLayout",
    "GPUBuffer",
    "GPUBufferUsage",
    "GPUCanvasContext",
    "GPUColorWrite",
    "GPUCommandBuffer",
    "GPUCommandEncoder",
    "GPUCompilationInfo",
    "GPUCompilationMessage",
    "GPUComputePassEncoder",
    "GPUComputePipeline",
    "GPUDevice",
    "GPUDeviceLostInfo",
    "GPUError",
    "GPUExternalTexture",
    "GPUInternalError",
    "GPUMapMode",
    "GPUOutOfMemoryError",
    "GPUPipelineError",
    "GPUPipelineLayout",
    "GPUQuerySet",
    "GPUQueue",
    "GPURenderBundle",
    "GPURenderBundleEncoder",
    "GPURenderPassEncoder",
    "GPURenderPipeline",
    "GPUSampler",
    "GPUShaderModule",
    "GPUShaderStage",
    "GPUSupportedFeatures",
    "GPUSupportedLimits",
    "GPUTexture",
    "GPUTextureUsage",
    "GPUTextureView",
    "GPUUncapturedErrorEvent",
    "GPUValidationError",
    "GravitySensor",
    "Gyroscope",
    "IdleDetector",
    "ImageCapture",
    "ImageDecoder",
    "ImageTrack",
    "ImageTrackList",
    "Keyboard",
    "KeyboardLayoutMap",
    "LinearAccelerationSensor",
    "MIDIAccess",
    "MIDIConnectionEvent",
    "MIDIInput",
    "MIDIInputMap",
    "MIDIMessageEvent",
    "MIDIOutput",
    "MIDIOutputMap",
    "MIDIPort",
    "MediaKeyMessageEvent",
    "MediaKeySession",
    "MediaKeyStatusMap",
    "MediaKeySystemAccess",
    "MediaKeys",
    "NavigationPreloadManager",
    "NavigatorManagedData",
    "OrientationSensor",
    "PasswordCredential",
    "ProtectedAudience",
    "RelativeOrientationSensor",
    "ScreenDetailed",
    "ScreenDetails",
    "Sensor",
    "SensorErrorEvent",
    "ServiceWorkerRegistration",
    "VideoDecoder",
    "VideoEncoder",
    "VirtualKeyboard",
    "WGSLLanguageFeatures",
    "WebTransport",
    "WebTransportBidirectionalStream",
    "WebTransportDatagramDuplexStream",
    "WebTransportError",
    "Worklet",
    "XRDOMOverlayState",
    "XRWebGLBinding",
    "AudioPlaybackStats",
    "AuthenticatorAssertionResponse",
    "AuthenticatorAttestationResponse",
    "AuthenticatorResponse",
    "PublicKeyCredential",
    "BarcodeDetector",
    "Bluetooth",
    "BluetoothCharacteristicProperties",
    "BluetoothDevice",
    "BluetoothRemoteGATTCharacteristic",
    "BluetoothRemoteGATTDescriptor",
    "BluetoothRemoteGATTServer",
    "BluetoothRemoteGATTService",
    "CaptureController",
    "CrashReportContext",
    "DevicePosture",
    "DigitalCredential",
    "DocumentPictureInPicture",
    "EyeDropper",
    "FetchLaterResult",
    "FileSystemDirectoryHandle",
    "FileSystemFileHandle",
    "FileSystemHandle",
    "FileSystemWritableFileStream",
    "FileSystemObserver",
    "FontData",
    "FragmentDirective",
    "HID",
    "HIDConnectionEvent",
    "HIDDevice",
    "HIDInputReportEvent",
    "IdentityCredential",
    "IdentityCredentialError",
    "IdentityProvider",
    "NavigatorLogin",
    "LanguageDetector",
    "LanguageModel",
    "Lock",
    "LockManager",
    "ServiceWorker",
    "ServiceWorkerContainer",
    "NotRestoredReasonDetails",
    "NotRestoredReasons",
    "OTPCredential",
    "PaymentAddress",
    "PaymentRequest",
    "PaymentRequestUpdateEvent",
    "PaymentResponse",
    "PaymentManager",
    "PaymentMethodChangeEvent",
    "Presentation",
    "PresentationAvailability",
    "PresentationConnection",
    "PresentationConnectionAvailableEvent",
    "PresentationConnectionCloseEvent",
    "PresentationConnectionList",
    "PresentationReceiver",
    "PresentationRequest",
    "PressureObserver",
    "PressureRecord",
    "Serial",
    "SerialPort",
    "SpeechRecognitionPhrase",
    "StorageBucket",
    "StorageBucketManager",
    "Summarizer",
    "Translator",
    "USB",
    "USBAlternateInterface",
    "USBConfiguration",
    "USBConnectionEvent",
    "USBDevice",
    "USBEndpoint",
    "USBInTransferResult",
    "USBInterface",
    "USBIsochronousInTransferPacket",
    "USBIsochronousInTransferResult",
    "USBIsochronousOutTransferPacket",
    "USBIsochronousOutTransferResult",
    "USBOutTransferResult",
    "WakeLock",
    "WakeLockSentinel",
    "XRAnchor",
    "XRAnchorSet",
    "XRBoundedReferenceSpace",
    "XRCPUDepthInformation",
    "XRCamera",
    "XRDepthInformation",
    "XRFrame",
    "XRHand",
    "XRHitTestResult",
    "XRHitTestSource",
    "XRInputSource",
    "XRInputSourceArray",
    "XRInputSourceEvent",
    "XRInputSourcesChangeEvent",
    "XRJointPose",
    "XRJointSpace",
    "XRLightEstimate",
    "XRLightProbe",
    "XRPose",
    "XRRay",
    "XRReferenceSpace",
    "XRReferenceSpaceEvent",
    "XRRenderState",
    "XRRigidTransform",
    "XRSession",
    "XRSessionEvent",
    "XRSpace",
    "XRSystem",
    "XRTransientInputHitTestResult",
    "XRTransientInputHitTestSource",
    "XRViewerPose",
    "XRViewport",
    "XRWebGLDepthInformation",
    "XRWebGLLayer",
    "XRProjectionLayer",
    "XRCubeLayer",
    "XREquirectLayer",
    "XRLayerEvent",
    "XRQuadLayer",
    "XRSubImage",
    "XRWebGLSubImage",
    "XRPlane",
    "XRPlaneSet",
    "XRVisibilityMaskChangeEvent",
    "fetchLater",
    "getScreenDetails",
    "queryLocalFonts",
    "showDirectoryPicker",
    "showOpenFilePicker",
    "showSaveFilePicker",
    "originAgentCluster",
    "viewport",
    "onpageswap",
    "onpagereveal",
    "credentialless",
    "fence",
    "launchQueue",
    "speechSynthesis",
    "onscrollsnapchange",
    "onscrollsnapchanging",
    "ongamepadconnected",
    "ongamepaddisconnected",
    "AnimationTrigger",
    "BackgroundFetchManager",
    "BackgroundFetchRecord",
    "BackgroundFetchRegistration",
    "BluetoothUUID",
    "CSSFontFeatureValuesRule",
    "CSSFunctionDeclarations",
    "CSSFunctionDescriptors",
    "CSSFunctionRule",
    "CSSPseudoElement",
    "ChapterInformation",
    "CropTarget",
    "DocumentPictureInPictureEvent",
    "Fence",
    "FencedFrameConfig",
    "HTMLFencedFrameElement",
    "HTMLGeolocationElement",
    "HTMLUserMediaElement",
    "IntegrityViolationReportBody",
    "InteractionContentfulPaint",
    "PerformanceSoftNavigation",
    "LaunchParams",
    "LaunchQueue",
    "MediaMetadata",
    "MediaSession",
    "Origin",
    "PageRevealEvent",
    "PageSwapEvent",
    "PerformanceTimingConfidence",
    "PeriodicSyncManager",
    "Profiler",
    "PushManager",
    "PushSubscription",
    "PushSubscriptionOptions",
    "RTCRtpScriptTransform",
    "RemotePlayback",
    "RestrictionTarget",
    "Sanitizer",
    "SharedStorage",
    "SharedStorageWorklet",
    "SharedStorageAppendMethod",
    "SharedStorageClearMethod",
    "SharedStorageDeleteMethod",
    "SharedStorageModifierMethod",
    "SharedStorageSetMethod",
    "SnapEvent",
    "SpeechGrammar",
    "SpeechGrammarList",
    "SpeechRecognition",
    "SpeechRecognitionErrorEvent",
    "SpeechRecognitionEvent",
    "SpeechSynthesis",
    "SpeechSynthesisErrorEvent",
    "SpeechSynthesisEvent",
    "SpeechSynthesisUtterance",
    "SpeechSynthesisVoice",
    "TimelineTrigger",
    "TimelineTriggerRange",
    "TimelineTriggerRangeList",
    "Viewport",
    "WebSocketError",
    "WebSocketStream",
    "webkitSpeechGrammar",
    "webkitSpeechGrammarList",
    "webkitSpeechRecognition",
    "webkitSpeechRecognitionError",
    "webkitSpeechRecognitionEvent",
    "webkitRequestFileSystem",
    "webkitResolveLocalFileSystemURL",
};

pub const ordered_late_global_names = [_][]const u8{
    "chrome",
    "WebAssembly",
    "crashReport",
    "cookieStore",
    "ondevicemotion",
    "ondeviceorientation",
    "ondeviceorientationabsolute",
    "onpointerrawupdate",
    "caches",
    "documentPictureInPicture",
    "sharedStorage",
    "AbsoluteOrientationSensor",
    "Accelerometer",
    "AudioDecoder",
    "AudioEncoder",
    "AudioWorklet",
    "BatteryManager",
    "Cache",
    "CacheStorage",
    "Clipboard",
    "ClipboardChangeEvent",
    "ClipboardItem",
    "CookieChangeEvent",
    "CookieStore",
    "CookieStoreManager",
    "CreateMonitor",
    "Credential",
    "CredentialsContainer",
    "CryptoKey",
    "DeviceMotionEvent",
    "DeviceMotionEventAcceleration",
    "DeviceMotionEventRotationRate",
    "DeviceOrientationEvent",
    "FederatedCredential",
    "GPU",
    "GPUAdapter",
    "GPUAdapterInfo",
    "GPUBindGroup",
    "GPUBindGroupLayout",
    "GPUBuffer",
    "GPUBufferUsage",
    "GPUCanvasContext",
    "GPUColorWrite",
    "GPUCommandBuffer",
    "GPUCommandEncoder",
    "GPUCompilationInfo",
    "GPUCompilationMessage",
    "GPUComputePassEncoder",
    "GPUComputePipeline",
    "GPUDevice",
    "GPUDeviceLostInfo",
    "GPUError",
    "GPUExternalTexture",
    "GPUInternalError",
    "GPUMapMode",
    "GPUOutOfMemoryError",
    "GPUPipelineError",
    "GPUPipelineLayout",
    "GPUQuerySet",
    "GPUQueue",
    "GPURenderBundle",
    "GPURenderBundleEncoder",
    "GPURenderPassEncoder",
    "GPURenderPipeline",
    "GPUSampler",
    "GPUShaderModule",
    "GPUShaderStage",
    "GPUSupportedFeatures",
    "GPUSupportedLimits",
    "GPUTexture",
    "GPUTextureUsage",
    "GPUTextureView",
    "GPUUncapturedErrorEvent",
    "GPUValidationError",
    "GravitySensor",
    "Gyroscope",
    "IdleDetector",
    "ImageCapture",
    "ImageDecoder",
    "ImageTrack",
    "ImageTrackList",
    "Keyboard",
    "KeyboardLayoutMap",
    "LinearAccelerationSensor",
    "MIDIAccess",
    "MIDIConnectionEvent",
    "MIDIInput",
    "MIDIInputMap",
    "MIDIMessageEvent",
    "MIDIOutput",
    "MIDIOutputMap",
    "MIDIPort",
    "MediaDeviceInfo",
    "MediaDevices",
    "MediaKeyMessageEvent",
    "MediaKeySession",
    "MediaKeyStatusMap",
    "MediaKeySystemAccess",
    "MediaKeys",
    "NavigationPreloadManager",
    "NavigatorManagedData",
    "OrientationSensor",
    "PasswordCredential",
    "ProtectedAudience",
    "RelativeOrientationSensor",
    "ScreenDetailed",
    "ScreenDetails",
    "Sensor",
    "SensorErrorEvent",
    "ServiceWorkerRegistration",
    "StorageManager",
    "SubtleCrypto",
    "VideoDecoder",
    "VideoEncoder",
    "VirtualKeyboard",
    "WGSLLanguageFeatures",
    "WebTransport",
    "WebTransportBidirectionalStream",
    "WebTransportDatagramDuplexStream",
    "WebTransportError",
    "Worklet",
    "XRDOMOverlayState",
    "XRLayer",
    "XRWebGLBinding",
    "AudioPlaybackStats",
    "AuthenticatorAssertionResponse",
    "AuthenticatorAttestationResponse",
    "AuthenticatorResponse",
    "PublicKeyCredential",
    "BarcodeDetector",
    "Bluetooth",
    "BluetoothCharacteristicProperties",
    "BluetoothDevice",
    "BluetoothRemoteGATTCharacteristic",
    "BluetoothRemoteGATTDescriptor",
    "BluetoothRemoteGATTServer",
    "BluetoothRemoteGATTService",
    "CaptureController",
    "CrashReportContext",
    "DevicePosture",
    "DigitalCredential",
    "DocumentPictureInPicture",
    "EyeDropper",
    "FetchLaterResult",
    "FileSystemDirectoryHandle",
    "FileSystemFileHandle",
    "FileSystemHandle",
    "FileSystemWritableFileStream",
    "FileSystemObserver",
    "FontData",
    "FragmentDirective",
    "HID",
    "HIDConnectionEvent",
    "HIDDevice",
    "HIDInputReportEvent",
    "IdentityCredential",
    "IdentityCredentialError",
    "IdentityProvider",
    "NavigatorLogin",
    "LanguageDetector",
    "LanguageModel",
    "Lock",
    "LockManager",
    "ServiceWorker",
    "ServiceWorkerContainer",
    "NotRestoredReasonDetails",
    "NotRestoredReasons",
    "OTPCredential",
    "PaymentAddress",
    "PaymentRequest",
    "PaymentRequestUpdateEvent",
    "PaymentResponse",
    "PaymentManager",
    "PaymentMethodChangeEvent",
    "Presentation",
    "PresentationAvailability",
    "PresentationConnection",
    "PresentationConnectionAvailableEvent",
    "PresentationConnectionCloseEvent",
    "PresentationConnectionList",
    "PresentationReceiver",
    "PresentationRequest",
    "PressureObserver",
    "PressureRecord",
    "Serial",
    "SerialPort",
    "SpeechRecognitionPhrase",
    "StorageBucket",
    "StorageBucketManager",
    "Summarizer",
    "Translator",
    "USB",
    "USBAlternateInterface",
    "USBConfiguration",
    "USBConnectionEvent",
    "USBDevice",
    "USBEndpoint",
    "USBInTransferResult",
    "USBInterface",
    "USBIsochronousInTransferPacket",
    "USBIsochronousInTransferResult",
    "USBIsochronousOutTransferPacket",
    "USBIsochronousOutTransferResult",
    "USBOutTransferResult",
    "WakeLock",
    "WakeLockSentinel",
    "XRAnchor",
    "XRAnchorSet",
    "XRBoundedReferenceSpace",
    "XRCPUDepthInformation",
    "XRCamera",
    "XRDepthInformation",
    "XRFrame",
    "XRHand",
    "XRHitTestResult",
    "XRHitTestSource",
    "XRInputSource",
    "XRInputSourceArray",
    "XRInputSourceEvent",
    "XRInputSourcesChangeEvent",
    "XRJointPose",
    "XRJointSpace",
    "XRLightEstimate",
    "XRLightProbe",
    "XRPose",
    "XRRay",
    "XRReferenceSpace",
    "XRReferenceSpaceEvent",
    "XRRenderState",
    "XRRigidTransform",
    "XRSession",
    "XRSessionEvent",
    "XRSpace",
    "XRSystem",
    "XRTransientInputHitTestResult",
    "XRTransientInputHitTestSource",
    "XRView",
    "XRViewerPose",
    "XRViewport",
    "XRWebGLDepthInformation",
    "XRWebGLLayer",
    "XRCompositionLayer",
    "XRProjectionLayer",
    "XRCubeLayer",
    "XRCylinderLayer",
    "XREquirectLayer",
    "XRLayerEvent",
    "XRQuadLayer",
    "XRSubImage",
    "XRWebGLSubImage",
    "XRPlane",
    "XRPlaneSet",
    "XRVisibilityMaskChangeEvent",
    "fetchLater",
    "getScreenDetails",
    "queryLocalFonts",
    "showDirectoryPicker",
    "showOpenFilePicker",
    "showSaveFilePicker",
    "originAgentCluster",
    "viewport",
    "onpageswap",
    "onpagereveal",
    "credentialless",
    "fence",
    "launchQueue",
    "speechSynthesis",
    "onscrollsnapchange",
    "onscrollsnapchanging",
    "ongamepadconnected",
    "ongamepaddisconnected",
    "AnimationTrigger",
    "BackgroundFetchManager",
    "BackgroundFetchRecord",
    "BackgroundFetchRegistration",
    "BluetoothUUID",
    "CSSFontFeatureValuesRule",
    "CSSFunctionDeclarations",
    "CSSFunctionDescriptors",
    "CSSFunctionRule",
    "CSSPseudoElement",
    "ChapterInformation",
    "CropTarget",
    "DocumentPictureInPictureEvent",
    "Fence",
    "FencedFrameConfig",
    "HTMLFencedFrameElement",
    "HTMLGeolocationElement",
    "HTMLUserMediaElement",
    "IntegrityViolationReportBody",
    "InteractionContentfulPaint",
    "PerformanceSoftNavigation",
    "LaunchParams",
    "LaunchQueue",
    "MediaMetadata",
    "MediaSession",
    "Notification",
    "Origin",
    "PageRevealEvent",
    "PageSwapEvent",
    "PerformanceTimingConfidence",
    "PeriodicSyncManager",
    "Profiler",
    "PushManager",
    "PushSubscription",
    "PushSubscriptionOptions",
    "QuotaExceededError",
    "RTCDataChannel",
    "RTCRtpScriptTransform",
    "RemotePlayback",
    "RestrictionTarget",
    "Sanitizer",
    "SharedStorage",
    "SharedStorageWorklet",
    "SharedStorageAppendMethod",
    "SharedStorageClearMethod",
    "SharedStorageDeleteMethod",
    "SharedStorageModifierMethod",
    "SharedStorageSetMethod",
    "SharedWorker",
    "SnapEvent",
    "SpeechGrammar",
    "SpeechGrammarList",
    "SpeechRecognition",
    "SpeechRecognitionErrorEvent",
    "SpeechRecognitionEvent",
    "SpeechSynthesis",
    "SpeechSynthesisErrorEvent",
    "SpeechSynthesisEvent",
    "SpeechSynthesisUtterance",
    "SpeechSynthesisVoice",
    "TimelineTrigger",
    "TimelineTriggerRange",
    "TimelineTriggerRangeList",
    "Viewport",
    "WebSocketError",
    "WebSocketStream",
    "XSLTProcessor",
    "webkitSpeechGrammar",
    "webkitSpeechGrammarList",
    "webkitSpeechRecognition",
    "webkitSpeechRecognitionError",
    "webkitSpeechRecognitionEvent",
    "webkitRequestFileSystem",
    "webkitResolveLocalFileSystemURL",
};

fn CompatibilityInterface(comptime interface_name: []const u8) type {
    return struct {
        const Self = @This();

        _pad: bool = false,

        pub const JsApi = struct {
            pub const bridge = js.Bridge(Self);
            pub const Meta = struct {
                pub const name = interface_name;
                pub const prototype_chain = bridge.prototypeChain();
                pub var class_id: bridge.ClassId = undefined;
                pub const empty_with_no_proto = true;
            };
        };
    };
}

pub fn registerTypes() []const type {
    return &.{
        SVGFEConvolveMatrixElement,
        SVGFEOffsetElement,
        VideoPlaybackQuality,
        ScriptProcessorNode,
        XSLTProcessor,
        XRLayer,
        XRCompositionLayer,
        XRCylinderLayer,
        XRView,
        CompatibilityInterface("webkitURL"),
        CompatibilityInterface("webkitMediaStream"),
        CompatibilityInterface("WebKitMutationObserver"),
        CompatibilityInterface("WebKitCSSMatrix"),
        CompatibilityInterface("WindowControlsOverlayGeometryChangeEvent"),
        CompatibilityInterface("WindowControlsOverlay"),
        CompatibilityInterface("WebGLVertexArrayObject"),
        CompatibilityInterface("WebGLUniformLocation"),
        CompatibilityInterface("WebGLTransformFeedback"),
        CompatibilityInterface("WebGLTexture"),
        CompatibilityInterface("WebGLSync"),
        CompatibilityInterface("WebGLShaderPrecisionFormat"),
        CompatibilityInterface("WebGLShader"),
        CompatibilityInterface("WebGLSampler"),
        CompatibilityInterface("WebGLRenderbuffer"),
        CompatibilityInterface("WebGLQuery"),
        CompatibilityInterface("WebGLProgram"),
        CompatibilityInterface("WebGLObject"),
        CompatibilityInterface("WebGLFramebuffer"),
        CompatibilityInterface("WebGLContextEvent"),
        CompatibilityInterface("WebGLBuffer"),
        CompatibilityInterface("WebGLActiveInfo"),
        CompatibilityInterface("WaveShaperNode"),
        CompatibilityInterface("VisibilityStateEntry"),
        CompatibilityInterface("VirtualKeyboardGeometryChangeEvent"),
        CompatibilityInterface("ViewTransitionTypeSet"),
        CompatibilityInterface("ViewTransition"),
        CompatibilityInterface("ViewTimeline"),
        CompatibilityInterface("VideoFrame"),
        CompatibilityInterface("VideoColorSpace"),
        CompatibilityInterface("UserActivation"),
        CompatibilityInterface("URLPattern"),
        CompatibilityInterface("TrustedTypePolicyFactory"),
        CompatibilityInterface("TrustedTypePolicy"),
        CompatibilityInterface("TrustedScriptURL"),
        CompatibilityInterface("TrustedScript"),
        CompatibilityInterface("TrustedHTML"),
        CompatibilityInterface("TransitionEvent"),
        CompatibilityInterface("TrackEvent"),
        CompatibilityInterface("TouchList"),
        CompatibilityInterface("Touch"),
        CompatibilityInterface("TimeRanges"),
        CompatibilityInterface("TextUpdateEvent"),
        CompatibilityInterface("TextTrackList"),
        CompatibilityInterface("TextTrackCueList"),
        CompatibilityInterface("TextTrack"),
        CompatibilityInterface("TextFormatUpdateEvent"),
        CompatibilityInterface("TextFormat"),
        CompatibilityInterface("TaskAttributionTiming"),
        CompatibilityInterface("SyncManager"),
        CompatibilityInterface("Subscriber"),
        CompatibilityInterface("StyleSheet"),
        CompatibilityInterface("StylePropertyMapReadOnly"),
        CompatibilityInterface("StylePropertyMap"),
        CompatibilityInterface("StereoPannerNode"),
        CompatibilityInterface("SourceBufferList"),
        CompatibilityInterface("SourceBuffer"),
        CompatibilityInterface("SecurityPolicyViolationEvent"),
        CompatibilityInterface("ScrollTimeline"),
        CompatibilityInterface("Scheduling"),
        CompatibilityInterface("SVGUnitTypes"),
        CompatibilityInterface("SVGStyleElement"),
        CompatibilityInterface("SVGSetElement"),
        CompatibilityInterface("SVGScriptElement"),
        CompatibilityInterface("SVGRect"),
        CompatibilityInterface("SVGPoint"),
        CompatibilityInterface("SVGNumberList"),
        CompatibilityInterface("SVGMatrix"),
        CompatibilityInterface("SVGMPathElement"),
        CompatibilityInterface("SVGLengthList"),
        CompatibilityInterface("SVGFilterElement"),
        CompatibilityInterface("SVGFETurbulenceElement"),
        CompatibilityInterface("SVGFETileElement"),
        CompatibilityInterface("SVGFESpotLightElement"),
        CompatibilityInterface("SVGFESpecularLightingElement"),
        CompatibilityInterface("SVGFEPointLightElement"),
        CompatibilityInterface("SVGFEMorphologyElement"),
        CompatibilityInterface("SVGFEMergeNodeElement"),
        CompatibilityInterface("SVGFEMergeElement"),
        CompatibilityInterface("SVGFEImageElement"),
        CompatibilityInterface("SVGFEGaussianBlurElement"),
        CompatibilityInterface("SVGFEFuncRElement"),
        CompatibilityInterface("SVGFEFuncGElement"),
        CompatibilityInterface("SVGFEFuncBElement"),
        CompatibilityInterface("SVGFEFuncAElement"),
        CompatibilityInterface("SVGFEFloodElement"),
        CompatibilityInterface("SVGFEDropShadowElement"),
        CompatibilityInterface("SVGFEDistantLightElement"),
        CompatibilityInterface("SVGFEDisplacementMapElement"),
        CompatibilityInterface("SVGFEDiffuseLightingElement"),
        CompatibilityInterface("SVGFECompositeElement"),
        CompatibilityInterface("SVGFEComponentTransferElement"),
        CompatibilityInterface("SVGFEColorMatrixElement"),
        CompatibilityInterface("SVGFEBlendElement"),
        CompatibilityInterface("SVGComponentTransferFunctionElement"),
        CompatibilityInterface("SVGAnimationElement"),
        CompatibilityInterface("SVGAnimatedRect"),
        CompatibilityInterface("SVGAnimatedNumberList"),
        CompatibilityInterface("SVGAnimatedLengthList"),
        CompatibilityInterface("SVGAnimatedInteger"),
        CompatibilityInterface("SVGAnimatedBoolean"),
        CompatibilityInterface("SVGAnimatedAngle"),
        CompatibilityInterface("SVGAnimateTransformElement"),
        CompatibilityInterface("SVGAnimateMotionElement"),
        CompatibilityInterface("SVGAnimateElement"),
        CompatibilityInterface("ReportingObserver"),
        CompatibilityInterface("ReportBody"),
        CompatibilityInterface("ReadableStreamBYOBRequest"),
        CompatibilityInterface("ReadableStreamBYOBReader"),
        CompatibilityInterface("ReadableByteStreamController"),
        CompatibilityInterface("RTCTrackEvent"),
        CompatibilityInterface("RTCStatsReport"),
        CompatibilityInterface("RTCSessionDescription"),
        CompatibilityInterface("RTCSctpTransport"),
        RTCRtpTransceiver,
        CompatibilityInterface("RTCRtpSender"),
        CompatibilityInterface("RTCRtpReceiver"),
        CompatibilityInterface("RTCPeerConnectionIceEvent"),
        CompatibilityInterface("RTCPeerConnectionIceErrorEvent"),
        CompatibilityInterface("RTCIceTransport"),
        CompatibilityInterface("RTCIceCandidate"),
        CompatibilityInterface("RTCErrorEvent"),
        CompatibilityInterface("RTCError"),
        CompatibilityInterface("RTCEncodedVideoFrame"),
        CompatibilityInterface("RTCEncodedAudioFrame"),
        CompatibilityInterface("RTCDtlsTransport"),
        CompatibilityInterface("RTCDataChannelEvent"),
        CompatibilityInterface("RTCDTMFToneChangeEvent"),
        CompatibilityInterface("RTCDTMFSender"),
        CompatibilityInterface("RTCCertificate"),
        CompatibilityInterface("PictureInPictureWindow"),
        CompatibilityInterface("PictureInPictureEvent"),
        CompatibilityInterface("PeriodicWave"),
        CompatibilityInterface("PerformanceServerTiming"),
        CompatibilityInterface("PerformanceScriptTiming"),
        CompatibilityInterface("PerformanceResourceTiming"),
        CompatibilityInterface("PerformancePaintTiming"),
        CompatibilityInterface("PerformanceLongTaskTiming"),
        CompatibilityInterface("PerformanceLongAnimationFrameTiming"),
        CompatibilityInterface("PerformanceEventTiming"),
        CompatibilityInterface("PerformanceElementTiming"),
        CompatibilityInterface("Path2D"),
        CompatibilityInterface("PannerNode"),
        CompatibilityInterface("OverconstrainedError"),
        CompatibilityInterface("OfflineAudioCompletionEvent"),
        CompatibilityInterface("Observable"),
        CompatibilityInterface("NavigationTransition"),
        CompatibilityInterface("NavigationPrecommitController"),
        CompatibilityInterface("NavigationDestination"),
        CompatibilityInterface("NavigateEvent"),
        CompatibilityInterface("MediaStreamTrackVideoStats"),
        CompatibilityInterface("MediaStreamTrackProcessor"),
        CompatibilityInterface("MediaStreamTrackGenerator"),
        CompatibilityInterface("MediaStreamTrackEvent"),
        CompatibilityInterface("MediaStreamTrackAudioStats"),
        CompatibilityInterface("MediaStreamTrack"),
        CompatibilityInterface("MediaStreamEvent"),
        CompatibilityInterface("MediaStreamAudioSourceNode"),
        CompatibilityInterface("MediaStreamAudioDestinationNode"),
        CompatibilityInterface("MediaStream"),
        CompatibilityInterface("MediaSourceHandle"),
        CompatibilityInterface("MediaSource"),
        CompatibilityInterface("MediaRecorder"),
        CompatibilityInterface("MediaList"),
        CompatibilityInterface("MediaEncryptedEvent"),
        CompatibilityInterface("MediaElementAudioSourceNode"),
        CompatibilityInterface("MediaCapabilities"),
        CompatibilityInterface("MathMLElement"),
        CompatibilityInterface("LayoutShiftAttribution"),
        CompatibilityInterface("LayoutShift"),
        CompatibilityInterface("LargestContentfulPaint"),
        CompatibilityInterface("KeyframeEffect"),
        CompatibilityInterface("InterestEvent"),
        CompatibilityInterface("InputDeviceInfo"),
        CompatibilityInterface("Ink"),
        CompatibilityInterface("ImageBitmapRenderingContext"),
        CompatibilityInterface("IIRFilterNode"),
        CompatibilityInterface("IDBOpenDBRequest"),
        CompatibilityInterface("HighlightRegistry"),
        CompatibilityInterface("Highlight"),
        CompatibilityInterface("HTMLSelectedContentElement"),
        CompatibilityInterface("HTMLMenuElement"),
        CompatibilityInterface("HTMLFrameElement"),
        CompatibilityInterface("GeolocationPositionError"),
        CompatibilityInterface("GeolocationPosition"),
        CompatibilityInterface("GeolocationCoordinates"),
        CompatibilityInterface("Geolocation"),
        CompatibilityInterface("GamepadHapticActuator"),
        CompatibilityInterface("GamepadButton"),
        CompatibilityInterface("Gamepad"),
        CompatibilityInterface("FontFaceSetLoadEvent"),
        CompatibilityInterface("FeaturePolicy"),
        CompatibilityInterface("External"),
        CompatibilityInterface("EncodedVideoChunk"),
        CompatibilityInterface("EncodedAudioChunk"),
        CompatibilityInterface("ElementInternals"),
        CompatibilityInterface("EditContext"),
        CompatibilityInterface("DocumentTimeline"),
        CompatibilityInterface("DelegatedInkTrailPresenter"),
        CompatibilityInterface("DelayNode"),
        CompatibilityInterface("DecompressionStream"),
        CompatibilityInterface("DOMRectList"),
        CompatibilityInterface("DOMQuad"),
        CompatibilityInterface("DOMError"),
        CompatibilityInterface("CustomStateSet"),
        CompatibilityInterface("CountQueuingStrategy"),
        CompatibilityInterface("ConvolverNode"),
        CompatibilityInterface("ContentVisibilityAutoStateChangeEvent"),
        CompatibilityInterface("ConstantSourceNode"),
        CompatibilityInterface("CompressionStream"),
        CompatibilityInterface("CommandEvent"),
        CompatibilityInterface("CloseWatcher"),
        CompatibilityInterface("ClipboardEvent"),
        CompatibilityInterface("CharacterBoundsUpdateEvent"),
        CompatibilityInterface("ChannelSplitterNode"),
        CompatibilityInterface("ChannelMergerNode"),
        CompatibilityInterface("CaretPosition"),
        CompatibilityInterface("CanvasPattern"),
        CompatibilityInterface("CanvasCaptureMediaStreamTrack"),
        CompatibilityInterface("CSSViewTransitionRule"),
        CompatibilityInterface("CSSVariableReferenceValue"),
        CompatibilityInterface("CSSUnparsedValue"),
        CompatibilityInterface("CSSUnitValue"),
        CompatibilityInterface("CSSTranslate"),
        CompatibilityInterface("CSSTransition"),
        CompatibilityInterface("CSSTransformValue"),
        CompatibilityInterface("CSSTransformComponent"),
        CompatibilityInterface("CSSSupportsRule"),
        CompatibilityInterface("CSSStyleValue"),
        CompatibilityInterface("CSSStartingStyleRule"),
        CompatibilityInterface("CSSSkewY"),
        CompatibilityInterface("CSSSkewX"),
        CompatibilityInterface("CSSSkew"),
        CompatibilityInterface("CSSScopeRule"),
        CompatibilityInterface("CSSScale"),
        CompatibilityInterface("CSSRotate"),
        CompatibilityInterface("CSSPropertyRule"),
        CompatibilityInterface("CSSPositionValue"),
        CompatibilityInterface("CSSPositionTryRule"),
        CompatibilityInterface("CSSPositionTryDescriptors"),
        CompatibilityInterface("CSSPerspective"),
        CompatibilityInterface("CSSPageRule"),
        CompatibilityInterface("CSSNumericValue"),
        CompatibilityInterface("CSSNumericArray"),
        CompatibilityInterface("CSSNestedDeclarations"),
        CompatibilityInterface("CSSNamespaceRule"),
        CSSMediaRule,
        CompatibilityInterface("CSSMatrixComponent"),
        CompatibilityInterface("CSSMathValue"),
        CompatibilityInterface("CSSMathSum"),
        CompatibilityInterface("CSSMathProduct"),
        CompatibilityInterface("CSSMathNegate"),
        CompatibilityInterface("CSSMathMin"),
        CompatibilityInterface("CSSMathMax"),
        CompatibilityInterface("CSSMathInvert"),
        CompatibilityInterface("CSSMathClamp"),
        CompatibilityInterface("CSSMarginRule"),
        CompatibilityInterface("CSSLayerStatementRule"),
        CompatibilityInterface("CSSLayerBlockRule"),
        CompatibilityInterface("CSSKeywordValue"),
        CompatibilityInterface("CSSKeyframesRule"),
        CompatibilityInterface("CSSKeyframeRule"),
        CompatibilityInterface("CSSImportRule"),
        CompatibilityInterface("CSSImageValue"),
        CompatibilityInterface("CSSGroupingRule"),
        CompatibilityInterface("CSSFontPaletteValuesRule"),
        CompatibilityInterface("CSSFontFaceRule"),
        CompatibilityInterface("CSSCounterStyleRule"),
        CompatibilityInterface("CSSContainerRule"),
        CompatibilityInterface("CSSConditionRule"),
        CompatibilityInterface("CSSAnimation"),
        CompatibilityInterface("CSPViolationReportBody"),
        CompatibilityInterface("ByteLengthQueuingStrategy"),
        CompatibilityInterface("BrowserCaptureMediaStreamTrack"),
        CompatibilityInterface("BlobEvent"),
        CompatibilityInterface("BiquadFilterNode"),
        CompatibilityInterface("BeforeInstallPromptEvent"),
        CompatibilityInterface("BaseAudioContext"),
        CompatibilityInterface("BarProp"),
        CompatibilityInterface("AudioWorkletNode"),
        CompatibilityInterface("AudioSinkInfo"),
        CompatibilityInterface("AudioScheduledSourceNode"),
        CompatibilityInterface("AudioProcessingEvent"),
        CompatibilityInterface("AudioParamMap"),
        CompatibilityInterface("AudioNode"),
        CompatibilityInterface("AudioListener"),
        CompatibilityInterface("AudioData"),
        CompatibilityInterface("AudioBufferSourceNode"),
        CompatibilityInterface("AnimationTimeline"),
        CompatibilityInterface("AnimationPlaybackEvent"),
        CompatibilityInterface("AnimationEvent"),
        CompatibilityInterface("AnimationEffect"),
    };
}

pub const RTCRtpTransceiver = struct {
    fn getNull(_: *const RTCRtpTransceiver) ?js.Value {
        return null;
    }

    fn getStopped(_: *const RTCRtpTransceiver) bool {
        return false;
    }

    fn getDirection(_: *const RTCRtpTransceiver) []const u8 {
        return "inactive";
    }

    fn noop(_: *RTCRtpTransceiver) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(RTCRtpTransceiver);

        pub const Meta = struct {
            pub const name = "RTCRtpTransceiver";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const mid = bridge.accessor(RTCRtpTransceiver.getNull, null, .{});
        pub const sender = bridge.accessor(RTCRtpTransceiver.getNull, null, .{});
        pub const receiver = bridge.accessor(RTCRtpTransceiver.getNull, null, .{});
        pub const stopped = bridge.accessor(RTCRtpTransceiver.getStopped, null, .{});
        pub const direction = bridge.accessor(RTCRtpTransceiver.getDirection, null, .{});
        pub const currentDirection = bridge.accessor(RTCRtpTransceiver.getNull, null, .{});
        pub const getHeaderExtensionsToNegotiate = bridge.function(RTCRtpTransceiver.noop, .{});
        pub const getNegotiatedHeaderExtensions = bridge.function(RTCRtpTransceiver.noop, .{});
        pub const setCodecPreferences = bridge.function(RTCRtpTransceiver.noop, .{});
        pub const setHeaderExtensionsToNegotiate = bridge.function(RTCRtpTransceiver.noop, .{});
        pub const stop = bridge.function(RTCRtpTransceiver.noop, .{});
    };
};

pub const CSSMediaRule = struct {
    pub const Proto = CSSRule;
    _proto: *CSSRule,

    fn getMedia(_: *CSSMediaRule) ?[]const u8 {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSSMediaRule);
        pub const Meta = struct {
            pub const name = "CSSMediaRule";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const media = bridge.accessor(CSSMediaRule.getMedia, null, .{});
    };
};

pub const XRView = struct {
    _pad: bool = false,

    fn getNull(_: *XRView) ?[]const u8 {
        return null;
    }

    fn getScale(_: *XRView) f64 {
        return 1;
    }

    fn getFalse(_: *XRView) bool {
        return false;
    }

    fn getIndex(_: *XRView) u32 {
        return 0;
    }

    fn requestViewportScale(_: *XRView, _: f64) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRView);
        pub const Meta = struct {
            pub const name = "XRView";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const eye = bridge.accessor(XRView.getNull, null, .{});
        pub const recommendedViewportScale = bridge.accessor(XRView.getScale, null, .{});
        pub const isFirstPersonObserver = bridge.accessor(XRView.getFalse, null, .{});
        pub const camera = bridge.accessor(XRView.getNull, null, .{});
        pub const requestViewportScale = bridge.function(XRView.requestViewportScale, .{});
        pub const index = bridge.accessor(XRView.getIndex, null, .{});
        pub const projectionMatrix = bridge.accessor(XRView.getNull, null, .{});
        pub const transform = bridge.accessor(XRView.getNull, null, .{});
    };
};

pub const SVGFEConvolveMatrixElement = struct {
    pub const Proto = Svg;
    _proto: *Svg,

    fn getObject(_: *SVGFEConvolveMatrixElement) ?[]const u8 {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(SVGFEConvolveMatrixElement);
        pub const Meta = struct {
            pub const name = "SVGFEConvolveMatrixElement";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const in1 = bridge.accessor(SVGFEConvolveMatrixElement.getObject, null, .{});
        pub const orderX = bridge.accessor(SVGFEConvolveMatrixElement.getObject, null, .{});
        pub const orderY = bridge.accessor(SVGFEConvolveMatrixElement.getObject, null, .{});
        pub const kernelMatrix = bridge.accessor(SVGFEConvolveMatrixElement.getObject, null, .{});
        pub const divisor = bridge.accessor(SVGFEConvolveMatrixElement.getObject, null, .{});
        pub const bias = bridge.accessor(SVGFEConvolveMatrixElement.getObject, null, .{});
        pub const targetX = bridge.accessor(SVGFEConvolveMatrixElement.getObject, null, .{});
        pub const targetY = bridge.accessor(SVGFEConvolveMatrixElement.getObject, null, .{});
        pub const edgeMode = bridge.accessor(SVGFEConvolveMatrixElement.getObject, null, .{});
        pub const kernelUnitLengthX = bridge.accessor(SVGFEConvolveMatrixElement.getObject, null, .{});
        pub const kernelUnitLengthY = bridge.accessor(SVGFEConvolveMatrixElement.getObject, null, .{});
        pub const preserveAlpha = bridge.accessor(SVGFEConvolveMatrixElement.getObject, null, .{});
        pub const x = bridge.accessor(SVGFEConvolveMatrixElement.getObject, null, .{});
        pub const y = bridge.accessor(SVGFEConvolveMatrixElement.getObject, null, .{});
        pub const width = bridge.accessor(SVGFEConvolveMatrixElement.getObject, null, .{});
        pub const height = bridge.accessor(SVGFEConvolveMatrixElement.getObject, null, .{});
        pub const result = bridge.accessor(SVGFEConvolveMatrixElement.getObject, null, .{});
        pub const SVG_EDGEMODE_UNKNOWN = bridge.property(0, .{ .template = false, .readonly = true });
        pub const SVG_EDGEMODE_DUPLICATE = bridge.property(1, .{ .template = false, .readonly = true });
        pub const SVG_EDGEMODE_WRAP = bridge.property(2, .{ .template = false, .readonly = true });
        pub const SVG_EDGEMODE_NONE = bridge.property(3, .{ .template = false, .readonly = true });
    };
};

pub const XRLayer = struct {
    pub const Proto = EventTarget;
    _proto: *EventTarget,

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRLayer);
        pub const Meta = struct {
            pub const name = "XRLayer";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
    };
};

pub const XRCompositionLayer = struct {
    pub const Proto = XRLayer;
    _proto: *XRLayer,

    fn getNull(_: *XRCompositionLayer) ?[]const u8 {
        return null;
    }
    fn getFalse(_: *XRCompositionLayer) bool {
        return false;
    }
    fn setValue(_: *XRCompositionLayer, _: js.Value) void {}
    fn getZero(_: *XRCompositionLayer) u32 {
        return 0;
    }
    fn destroy(_: *XRCompositionLayer) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRCompositionLayer);
        pub const Meta = struct {
            pub const name = "XRCompositionLayer";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const layout = bridge.accessor(XRCompositionLayer.getNull, null, .{});
        pub const blendTextureSourceAlpha = bridge.accessor(XRCompositionLayer.getFalse, XRCompositionLayer.setValue, .{});
        pub const forceMonoPresentation = bridge.accessor(XRCompositionLayer.getFalse, XRCompositionLayer.setValue, .{});
        pub const opacity = bridge.accessor(XRCompositionLayer.getZero, XRCompositionLayer.setValue, .{});
        pub const mipLevels = bridge.accessor(XRCompositionLayer.getZero, null, .{});
        pub const needsRedraw = bridge.accessor(XRCompositionLayer.getFalse, null, .{});
        pub const destroy = bridge.function(XRCompositionLayer.destroy, .{ .noop = true });
    };
};

pub const XRCylinderLayer = struct {
    pub const Proto = XRCompositionLayer;
    _proto: *XRCompositionLayer,

    fn getNull(_: *XRCylinderLayer) ?[]const u8 {
        return null;
    }
    fn getZero(_: *XRCylinderLayer) f64 {
        return 0;
    }
    fn setValue(_: *XRCylinderLayer, _: js.Value) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XRCylinderLayer);
        pub const Meta = struct {
            pub const name = "XRCylinderLayer";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const space = bridge.accessor(XRCylinderLayer.getNull, null, .{});
        pub const transform = bridge.accessor(XRCylinderLayer.getNull, null, .{});
        pub const radius = bridge.accessor(XRCylinderLayer.getZero, null, .{});
        pub const centralAngle = bridge.accessor(XRCylinderLayer.getZero, null, .{});
        pub const aspectRatio = bridge.accessor(XRCylinderLayer.getZero, null, .{});
        pub const onredraw = bridge.accessor(XRCylinderLayer.getNull, XRCylinderLayer.setValue, .{});
    };
};

pub const SVGFEOffsetElement = struct {
    pub const Proto = Svg;
    _proto: *Svg,

    fn getObject(_: *SVGFEOffsetElement) ?[]const u8 {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(SVGFEOffsetElement);
        pub const Meta = struct {
            pub const name = "SVGFEOffsetElement";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const in1 = bridge.accessor(SVGFEOffsetElement.getObject, null, .{});
        pub const dx = bridge.accessor(SVGFEOffsetElement.getObject, null, .{});
        pub const dy = bridge.accessor(SVGFEOffsetElement.getObject, null, .{});
        pub const x = bridge.accessor(SVGFEOffsetElement.getObject, null, .{});
        pub const y = bridge.accessor(SVGFEOffsetElement.getObject, null, .{});
        pub const width = bridge.accessor(SVGFEOffsetElement.getObject, null, .{});
        pub const height = bridge.accessor(SVGFEOffsetElement.getObject, null, .{});
        pub const result = bridge.accessor(SVGFEOffsetElement.getObject, null, .{});
    };
};

pub const VideoPlaybackQuality = struct {
    _pad: bool = false,

    fn getNumber(_: *VideoPlaybackQuality) u32 {
        return 0;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(VideoPlaybackQuality);
        pub const Meta = struct {
            pub const name = "VideoPlaybackQuality";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const creationTime = bridge.accessor(VideoPlaybackQuality.getNumber, null, .{});
        pub const totalVideoFrames = bridge.accessor(VideoPlaybackQuality.getNumber, null, .{});
        pub const droppedVideoFrames = bridge.accessor(VideoPlaybackQuality.getNumber, null, .{});
        pub const corruptedVideoFrames = bridge.accessor(VideoPlaybackQuality.getNumber, null, .{});
    };
};

pub const ScriptProcessorNode = struct {
    _pad: bool = false,

    fn getNull(_: *ScriptProcessorNode) ?[]const u8 {
        return null;
    }
    fn setNull(_: *ScriptProcessorNode, _: js.Value) void {}
    fn getBufferSize(_: *ScriptProcessorNode) u32 {
        return 0;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ScriptProcessorNode);
        pub const Meta = struct {
            pub const name = "ScriptProcessorNode";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const onaudioprocess = bridge.accessor(ScriptProcessorNode.getNull, ScriptProcessorNode.setNull, .{});
        pub const bufferSize = bridge.accessor(ScriptProcessorNode.getBufferSize, null, .{});
    };
};

pub const XSLTProcessor = struct {
    _pad: bool = false,

    fn init() XSLTProcessor {
        return .{};
    }
    fn clearParameters(_: *XSLTProcessor) void {}
    fn getParameter(_: *XSLTProcessor, _: ?[]const u8, _: []const u8) ?[]const u8 {
        return null;
    }
    fn importStylesheet(_: *XSLTProcessor, _: js.Value) void {}
    fn removeParameter(_: *XSLTProcessor, _: ?[]const u8, _: []const u8) void {}
    fn reset(_: *XSLTProcessor) void {}
    fn setParameter(_: *XSLTProcessor, _: ?[]const u8, _: []const u8, _: js.Value) void {}
    fn transformToDocument(_: *XSLTProcessor, _: js.Value) ?[]const u8 {
        return null;
    }
    fn transformToFragment(_: *XSLTProcessor, _: js.Value, _: js.Value) ?[]const u8 {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(XSLTProcessor);
        pub const Meta = struct {
            pub const name = "XSLTProcessor";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const constructor = bridge.constructor(XSLTProcessor.init, .{});
        pub const clearParameters = bridge.function(XSLTProcessor.clearParameters, .{ .noop = true });
        pub const getParameter = bridge.function(XSLTProcessor.getParameter, .{});
        pub const importStylesheet = bridge.function(XSLTProcessor.importStylesheet, .{ .noop = true });
        pub const removeParameter = bridge.function(XSLTProcessor.removeParameter, .{ .noop = true });
        pub const reset = bridge.function(XSLTProcessor.reset, .{ .noop = true });
        pub const setParameter = bridge.function(XSLTProcessor.setParameter, .{ .noop = true });
        pub const transformToDocument = bridge.function(XSLTProcessor.transformToDocument, .{});
        pub const transformToFragment = bridge.function(XSLTProcessor.transformToFragment, .{});
    };
};
