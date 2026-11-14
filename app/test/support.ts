import { randomUUID } from "node:crypto";
import tls from "node:tls";
import { AckPolicy, jetstreamManager } from "@nats-io/jetstream";
import { connect, type NatsConnection } from "@nats-io/transport-node";
import { simpleParser, type ParsedMail } from "mailparser";
import pg from "pg";
import selfsigned from "selfsigned";
import { SMTPServer } from "smtp-server";
import type { Config } from "../src/config.js";
import type { Logger } from "../src/log.js";

export const SMTP_USER = "notifier";
export const SMTP_PASSWORD = "s3cret";

export function requireEnv(name: string): string {
  const value = process.env[name];
  if (value === undefined || value === "") {
    throw new Error(`${name} must be set to the address of a running test service`);
  }
  return value;
}

export async function waitFor<T>(description: string, probe: () => Promise<T | undefined> | T | undefined, timeoutMs = 20_000): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const result = await probe();
    if (result !== undefined) {
      return result;
    }
    if (Date.now() > deadline) {
      throw new Error(`Timed out waiting for ${description}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
}

export interface LogEntry {
  readonly level: string;
  readonly message: string;
  readonly fields: Record<string, unknown> | undefined;
}

export function recordingLogger(): Logger & { readonly entries: LogEntry[] } {
  const entries: LogEntry[] = [];
  const add = (level: string) => (message: string, fields?: Record<string, unknown>) => {
    entries.push({ level, message, fields });
  };
  return { entries, info: add("info"), warn: add("warn"), error: add("error") };
}

export type SmtpMode = "plain" | "starttls" | "implicit" | "no-starttls";

export interface TestSmtp {
  readonly port: number;
  readonly messages: ParsedMail[];
  /** Makes the next `count` message submissions fail with a temporary error. */
  failNext(count: number): void;
  stop(): Promise<void>;
}

let trustedCertificate: Promise<{ key: string; cert: string }> | undefined;

/** One self-signed certificate for localhost, trusted by this process only. */
function localhostCertificate(): Promise<{ key: string; cert: string }> {
  trustedCertificate ??= (async () => {
    const pems = await selfsigned.generate([{ name: "commonName", value: "localhost" }], {
      extensions: [{ name: "subjectAltName", altNames: [{ type: 2, value: "localhost" }] }],
    });
    tls.setDefaultCACertificates([...tls.getCACertificates("default"), pems.cert]);
    return { key: pems.private, cert: pems.cert };
  })();
  return trustedCertificate;
}

export async function startSmtp(mode: SmtpMode, credentials = { user: SMTP_USER, pass: SMTP_PASSWORD }): Promise<TestSmtp> {
  const messages: ParsedMail[] = [];
  let failures = 0;
  const secured = mode === "starttls" || mode === "implicit";
  const server = new SMTPServer({
    ...(secured && (await localhostCertificate())),
    secure: mode === "implicit",
    disabledCommands: mode === "plain" || mode === "no-starttls" ? ["STARTTLS"] : [],
    allowInsecureAuth: mode === "plain" || mode === "no-starttls",
    authOptional: false,
    onAuth(auth, _session, callback) {
      if (auth.username === credentials.user && auth.password === credentials.pass) {
        callback(null, { user: auth.username });
      } else {
        callback(new Error("Invalid username or password"));
      }
    },
    onData(stream, _session, callback) {
      if (failures > 0) {
        failures -= 1;
        stream.resume();
        stream.on("end", () => callback(Object.assign(new Error("Try again later"), { responseCode: 451 })));
        return;
      }
      simpleParser(stream).then(
        (mail) => {
          messages.push(mail);
          callback();
        },
        (error: Error) => callback(error),
      );
    },
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.server.address();
  if (address === null || typeof address === "string") {
    throw new Error("SMTP test server has no TCP address");
  }
  return {
    port: address.port,
    messages,
    failNext: (count) => {
      failures = count;
    },
    stop: () => new Promise<void>((resolve) => server.close(resolve)),
  };
}

/** Removes every table, including the migration history, as on a freshly provisioned database. */
export async function resetDatabase(connectionString: string): Promise<void> {
  const client = new pg.Client({ connectionString });
  await client.connect();
  try {
    await client.query("DROP SCHEMA IF EXISTS drizzle CASCADE; DROP TABLE IF EXISTS public.notifications");
  } finally {
    await client.end();
  }
}

export async function queryDatabase<Row extends pg.QueryResultRow>(connectionString: string, sql: string, params: unknown[] = []): Promise<Row[]> {
  const client = new pg.Client({ connectionString });
  await client.connect();
  try {
    return (await client.query<Row>(sql, params)).rows;
  } finally {
    await client.end();
  }
}

export interface TestStream {
  readonly stream: string;
  readonly subject: string;
  readonly consumer: string;
}

/** Plays the platform's role: creates a stream and a durable consumer for the application to bind to. */
export async function provisionStream(connection: NatsConnection): Promise<TestStream> {
  const id = randomUUID().slice(0, 8);
  const created = { stream: `SHIPMENTS_${id}`, subject: `orders.shipped.${id}`, consumer: `shipment-notifier-${id}` };
  const manager = await jetstreamManager(connection);
  await manager.streams.add({ name: created.stream, subjects: [created.subject] });
  await manager.consumers.add(created.stream, { durable_name: created.consumer, ack_policy: AckPolicy.Explicit });
  return created;
}

export async function connectNats(): Promise<NatsConnection> {
  return connect({ servers: requireEnv("TEST_NATS_URL") });
}

export function buildConfig(overrides: { smtpPort: number; smtpTlsMode: Config["smtp"]["tlsMode"]; stream: TestStream }): Config {
  return {
    databaseUrl: requireEnv("TEST_DATABASE_URL"),
    smtp: { host: "localhost", port: overrides.smtpPort, username: SMTP_USER, password: SMTP_PASSWORD, tlsMode: overrides.smtpTlsMode },
    notification: { from: "shipping@example.com", to: "customer-service@example.com" },
    nats: {
      url: requireEnv("TEST_NATS_URL"),
      username: undefined,
      password: undefined,
      tls: false,
      ...overrides.stream,
    },
  };
}

export function eventPayload(fields: Record<string, unknown> = {}): string {
  return JSON.stringify({
    id: randomUUID(),
    orderId: `ORD-${randomUUID().slice(0, 8)}`,
    shippedAt: "2026-11-14T12:30:00Z",
    ...fields,
  });
}
