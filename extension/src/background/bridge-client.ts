import {
  CLOSE_UNAUTHORIZED,
  CLOSE_VERSION_MISMATCH,
  MAX_CHUNK_BYTES,
  PORTS,
  PROTOCOL_VERSION,
  type AppToExtension,
  type ExtensionToApp,
} from "../../../contracts/ts/protocol";
import type { BridgeState, ExtensionBridgeStatus } from "../shared/messages";
import { encodeMessage, parseAppMessage } from "../shared/protocol-codec";

export interface WebSocketLike {
  readonly readyState: number;
  readonly bufferedAmount: number;
  binaryType: string;
  onopen: (() => void) | null;
  onmessage: ((ev: { data: unknown }) => void) | null;
  onclose: ((ev: { code: number }) => void) | null;
  onerror: (() => void) | null;
  send(data: string | Uint8Array): void;
  close(code?: number): void;
}
export type SocketFactory = (url: string) => WebSocketLike;

export const BACKOFF_MS = [500, 1000, 2000, 5000] as const;
/** How long the client waits for helloAck before moving on. */
export const HELLO_ACK_TIMEOUT_MS = 5000;
const SOCKET_OPEN = 1;
const BUFFER_LIMIT = 8 * MAX_CHUNK_BYTES;
const BUFFER_POLL_MS = 50;

export function backoffDelay(failedRounds: number): number {
  return BACKOFF_MS[Math.min(failedRounds, BACKOFF_MS.length) - 1];
}
export function detectBrowserName(brands: { brand: string }[] | undefined): string {
  return brands?.find((b) => !/Chromium|Not.?A.?Brand/i.test(b.brand))?.brand ?? "Chromium";
}

export interface BridgeClientDeps {
  createSocket: SocketFactory;
  getToken(): Promise<string | null>;
  extensionVersion: string;
  browserName: string;
  ports?: readonly number[];
  /** Receives config and request; helloAck and ping are handled internally. */
  onAppMessage(msg: AppToExtension): void;
  onConnected(port: number, appVersion: string): void;
  onDisconnected(): void;
  onStatus(s: ExtensionBridgeStatus): void;
}

type State = "idle" | "connecting" | "connected" | "rejected";

export class BridgeClient {
  private state: State = "idle";
  private socket: WebSocketLike | null = null;
  private failedRounds = 0;
  private retryTimer: ReturnType<typeof setTimeout> | null = null;
  private ackTimer: ReturnType<typeof setTimeout> | null = null;
  /** Bumped by restart(), so a getToken() still in flight can't open a socket afterwards. */
  private generation = 0;

  constructor(private readonly deps: BridgeClientDeps) {}

  get connected(): boolean {
    return this.state === "connected";
  }

  /** Idempotent; does nothing while connecting, connected or rejected. */
  async start(): Promise<void> {
    if (this.state !== "idle") return;
    this.state = "connecting";
    await this.beginRound();
  }

  /** Closes, clears the rejected state and the backoff, then starts. */
  async restart(): Promise<void> {
    const wasConnected = this.connected;
    this.generation++;
    this.clearTimers();
    this.dropSocket();
    this.state = "idle";
    this.failedRounds = 0;
    if (wasConnected) this.deps.onDisconnected();
    await this.start();
  }

  /** Returns false (and drops the message) unless connected. */
  send(msg: ExtensionToApp): boolean {
    if (!this.connected || this.socket?.readyState !== SOCKET_OPEN) return false;
    this.socket.send(encodeMessage(msg));
    return true;
  }

  async sendBinary(frame: Uint8Array): Promise<void> {
    const socket = this.socket;
    if (!this.connected || !socket) throw new Error("bridge is not connected");
    while (socket.bufferedAmount > BUFFER_LIMIT) {
      await new Promise((r) => setTimeout(r, BUFFER_POLL_MS));
      if (this.socket !== socket || !this.connected) throw new Error("bridge disconnected during transfer");
    }
    socket.send(frame);
  }

  private async beginRound(): Promise<void> {
    const generation = this.generation;
    const token = await this.deps.getToken();
    if (generation !== this.generation) return;
    if (!token) {
      this.state = "idle";
      this.emit("noToken");
      return;
    }
    // After a failed round the status stays "disconnected" rather than flickering on every retry.
    if (this.failedRounds === 0) this.emit("connecting");
    this.tryPort(token, 0);
  }

  private tryPort(token: string, index: number): void {
    const ports = this.deps.ports ?? PORTS;
    if (index >= ports.length) {
      this.failedRounds++;
      this.emit("disconnected");
      this.scheduleRetry();
      return;
    }
    const port = ports[index];
    const next = () => {
      this.clearTimers();
      this.dropSocket();
      this.tryPort(token, index + 1);
    };
    let socket: WebSocketLike;
    try {
      socket = this.deps.createSocket(`ws://127.0.0.1:${port}`);
    } catch {
      next();
      return;
    }
    this.socket = socket;
    socket.binaryType = "arraybuffer";
    this.ackTimer = setTimeout(next, HELLO_ACK_TIMEOUT_MS);
    socket.onopen = () => {
      socket.send(encodeMessage({
        v: PROTOCOL_VERSION,
        type: "hello",
        token,
        extensionVersion: this.deps.extensionVersion,
        browserName: this.deps.browserName,
      }));
    };
    socket.onmessage = (ev) => this.onFrame(ev.data, port);
    socket.onclose = (ev) => {
      if (this.state === "connected") this.onConnectionLost(ev.code);
      else if (!this.reject(ev.code)) next();
    };
  }

  private onFrame(data: unknown, port: number): void {
    if (typeof data !== "string") return;
    let msg: AppToExtension;
    try {
      msg = parseAppMessage(data);
    } catch {
      return;
    }
    if (msg.type === "ping") return;
    if (msg.type === "helloAck") {
      if (this.state === "connected") return;
      this.clearTimers();
      this.failedRounds = 0;
      this.state = "connected";
      this.emit("connected", port, msg.appVersion);
      this.deps.onConnected(port, msg.appVersion);
      return;
    }
    if (this.connected) this.deps.onAppMessage(msg);
  }

  private onConnectionLost(code: number): void {
    this.dropSocket();
    if (this.reject(code)) {
      this.deps.onDisconnected();
      return;
    }
    this.state = "connecting";
    this.failedRounds = 1;
    this.emit("disconnected");
    this.deps.onDisconnected();
    this.scheduleRetry();
  }

  /** Handles the two terminal close codes; true if `code` was one of them. */
  private reject(code: number): boolean {
    if (code !== CLOSE_UNAUTHORIZED && code !== CLOSE_VERSION_MISMATCH) return false;
    this.clearTimers();
    this.dropSocket();
    this.state = "rejected";
    this.emit(code === CLOSE_UNAUTHORIZED ? "tokenRejected" : "versionMismatch");
    return true;
  }

  private scheduleRetry(): void {
    this.retryTimer = setTimeout(() => {
      this.retryTimer = null;
      void this.beginRound();
    }, backoffDelay(this.failedRounds));
  }

  private dropSocket(): void {
    const socket = this.socket;
    this.socket = null;
    if (!socket) return;
    socket.onopen = socket.onmessage = socket.onclose = socket.onerror = null;
    try {
      socket.close();
    } catch {
      // Already closed.
    }
  }

  private clearTimers(): void {
    if (this.ackTimer !== null) clearTimeout(this.ackTimer);
    if (this.retryTimer !== null) clearTimeout(this.retryTimer);
    this.ackTimer = this.retryTimer = null;
  }

  private emit(state: BridgeState, port: number | null = null, appVersion: string | null = null): void {
    this.deps.onStatus({ state, port, appVersion, updatedAtMs: Date.now() });
  }
}
