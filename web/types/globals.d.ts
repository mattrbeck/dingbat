// Hand-written ambient declarations for the dingbat web front-end's
// cross-file contracts. The app is plain script tags in one global scope, so
// anything one file publishes for another (usually via `window.<name> = ...`)
// is declared here — that is what turns "renamed a window global" from a
// silent runtime failure into a CI type error.
//
// Rule: a new cross-file global (window.* assignment consumed by another
// file, a UMD export, an expando property on a DOM element) gets declared
// here. File-local symbols never go here.

/** Compact SDP codec published by sdputil.js (classic-script/UMD). */
interface SDPCodecT {
  encode(desc: { type?: string; sdp?: string } | RTCSessionDescription): string;
  decode(code: string): { type: string; sdp: string };
  answerFrom(code: string, setup: string): { type: string; sdp: string };
  fields(sdp: string): {
    ufrag: string | null;
    pwd: string | null;
    fingerprint: string | null;
    setup: string | null;
    candidates: string[];
  };
  VERSION: number;
}
declare var SDPCodec: SDPCodecT;

// sdputil.js's UMD footer probes `module.exports` for the Node test runner;
// in the browser (and for tsc) it is undefined.
declare var module: { exports: unknown } | undefined;

interface Window {
  // netplay.js <-> index.js rollback/link contracts
  enterRollbackMode?: (...args: any[]) => any;
  leaveRollbackMode?: (...args: any[]) => any;
  rbSendInput?: (frame: number, bits: number) => void;
  rbSendSpeed?: (on: boolean | number) => void;
  applyRemoteSpeed2x?: (on: boolean | number) => void;
  setNetConnectLabel?: (connected: boolean) => void;
  driveNet?: () => void;
  dumpLinkStates?: () => void;
  // audio hooks published from inside Module.onRuntimeInitialized
  updateGain?: () => void;
  updateAudioLowpass?: () => void;
  // clip-recording audio tap (published from the same closure; consumed by
  // the module-scope retroactive-capture code)
  acquireClipAudio?: () => MediaStream | null;
  releaseClipAudio?: () => void;
  // UMD export mirror (sdputil.js does `root.SDPCodec = ...`)
  SDPCodec?: SDPCodecT;
}

// Audio hooks are also reachable as bare identifiers (script-tag global
// scope); they only exist once Module.onRuntimeInitialized has run, so
// callers guard with `typeof updateGain === "function"`.
declare var updateGain: (() => void) | undefined;
declare var updateAudioLowpass: (() => void) | undefined;

// sdputil.js's Node fallback path (base64 without btoa/atob). Guarded by
// `typeof btoa/atob !== "undefined"`; never reached in the browser.
declare var Buffer: {
  from(data: string | Uint8Array, encoding?: string): Uint8Array & { toString(encoding: string): string };
};

// webkit-prefixed fullscreen API (iPadOS Safari still needs it).
interface Document {
  webkitFullscreenElement?: Element | null;
  webkitExitFullscreen?: () => void;
}
interface HTMLElement {
  webkitRequestFullscreen?: () => void;
}

interface Navigator {
  /** iOS Safari only: true when running as a home-screen (standalone) app. */
  standalone?: boolean;
  /** Audio Session API (Safari 17+): lets playback ignore the mute switch. */
  audioSession?: { type: string };
}

// Confirm-to-arm buttons (index.js confirmButton) expose a disarm() expando
// so sibling buttons / modal-close paths can reset an armed button.
interface HTMLButtonElement {
  disarm?: () => void;
}

/** Google Identity Services (accounts.google.com/gsi/client) — the minimal
 * surface index.js uses for the Drive OAuth token flow. */
declare var google: {
  accounts?: {
    oauth2?: {
      initTokenClient(config: {
        client_id: string;
        scope: string;
        callback: (resp: { access_token?: string; error?: string }) => void;
        error_callback?: (err: { type?: string; message?: string }) => void;
      }): { requestAccessToken(opts?: { prompt?: string }): void };
      revoke(token: string, done?: () => void): void;
    };
  };
};
