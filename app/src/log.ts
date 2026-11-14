export interface Logger {
  info(message: string, fields?: Record<string, unknown>): void;
  warn(message: string, fields?: Record<string, unknown>): void;
  error(message: string, fields?: Record<string, unknown>): void;
}

export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

// One JSON object per line so cluster log collectors can parse entries.
function write(stream: NodeJS.WriteStream, level: string, message: string, fields?: Record<string, unknown>): void {
  stream.write(`${JSON.stringify({ time: new Date().toISOString(), level, message, ...fields })}\n`);
}

export const logger: Logger = {
  info: (message, fields) => write(process.stdout, "info", message, fields),
  warn: (message, fields) => write(process.stderr, "warn", message, fields),
  error: (message, fields) => write(process.stderr, "error", message, fields),
};
