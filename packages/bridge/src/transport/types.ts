export interface ListenEndpoint {
  readonly host: string;
  readonly port: number;
  readonly role: 'primary' | 'companion-loopback';
}

export interface ClientConnection {
  readonly id: number;
  readonly remoteAddress: string;
  isOpen(): boolean;
  sendText(payload: string): boolean;
  close(code?: number, reason?: string): void;
  onMessage(handler: (text: string) => void): void;
  onClose(handler: (code: number, reason: string) => void): void;
  onError(handler: (err: Error) => void): void;
}

export interface BridgeTransport {
  start(): Promise<{ host: string; port: number; listenAddresses: ListenEndpoint[] }>;
  stop(): Promise<void>;
  onConnection(handler: (conn: ClientConnection) => void): void;
}
