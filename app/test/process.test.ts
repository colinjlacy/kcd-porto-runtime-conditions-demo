import assert from "node:assert/strict";
import { type ChildProcess, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { after, before, describe, it } from "node:test";
import { fileURLToPath } from "node:url";
import { jetstreamManager } from "@nats-io/jetstream";
import type { NatsConnection } from "@nats-io/transport-node";
import {
  connectNats, provisionStream, queryDatabase, requireEnv, resetDatabase, SMTP_PASSWORD, SMTP_USER, startSmtp, type TestStream, waitFor,
} from "./support.js";

const appRoot = fileURLToPath(new URL("..", import.meta.url));

interface Run {
  readonly child: ChildProcess;
  readonly stdout: () => string;
  readonly stderr: () => string;
  readonly exited: Promise<number | null>;
}

/** Runs a TypeScript entry point in its own process with exactly the given environment. */
function run(script: string, env: Record<string, string>, args: string[] = []): Run {
  const child = spawn(process.execPath, ["--import", "tsx", script, ...args], {
    cwd: appRoot,
    env: { PATH: process.env.PATH ?? "", ...env },
  });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk: Buffer) => void (stdout += chunk.toString()));
  child.stderr.on("data", (chunk: Buffer) => void (stderr += chunk.toString()));
  const exited = once(child, "exit").then(([code]) => code as number | null);
  return { child, stdout: () => stdout, stderr: () => stderr, exited };
}

const natsEnv = (stream: TestStream): Record<string, string> => ({
  NATS_URL: requireEnv("TEST_NATS_URL"),
  NATS_STREAM: stream.stream,
  NATS_SUBJECT: stream.subject,
  NATS_CONSUMER: stream.consumer,
});

let connection: NatsConnection;
before(async () => {
  connection = await connectNats();
});
after(async () => {
  await connection.drain();
});

describe("publish script", () => {
  it("publishes the requested event once per run, without deduplicating repeats", async () => {
    const stream = await provisionStream(connection);
    const flags = ["--id", "evt-1", "--order-id", "ORD-77", "--shipped-at", "2026-11-14T12:30:00Z"];
    for (let attempt = 0; attempt < 2; attempt += 1) {
      const published = run("scripts/publish.ts", natsEnv(stream), flags);
      assert.equal(await published.exited, 0, published.stderr());
    }

    const manager = await jetstreamManager(connection);
    assert.equal((await manager.streams.info(stream.stream)).state.messages, 2);
    for (const seq of [1, 2]) {
      const message = await manager.streams.getMessage(stream.stream, { seq });
      assert.deepEqual(message?.json(), { id: "evt-1", orderId: "ORD-77", shippedAt: "2026-11-14T12:30:00Z" });
      assert.equal(message?.subject, stream.subject);
    }
  });

  it("generates a valid event when none is specified", async () => {
    const stream = await provisionStream(connection);
    const published = run("scripts/publish.ts", natsEnv(stream));
    assert.equal(await published.exited, 0, published.stderr());
    assert.equal((JSON.parse(published.stdout()) as { stream: string }).stream, stream.stream);

    const message = await (await jetstreamManager(connection)).streams.getMessage(stream.stream, { seq: 1 });
    const event = message?.json<{ id: string; orderId: string; shippedAt: string }>();
    assert.ok(event?.id && event.orderId.startsWith("ORD-") && !Number.isNaN(Date.parse(event.shippedAt)));
  });

  it("fails when the subject does not belong to the configured stream", async () => {
    const stream = await provisionStream(connection);
    const other = await provisionStream(connection);
    const published = run("scripts/publish.ts", { ...natsEnv(stream), NATS_SUBJECT: other.subject });
    assert.notEqual(await published.exited, 0);
    assert.equal((await (await jetstreamManager(connection)).streams.info(other.stream)).state.messages, 0);
  });

  it("names the missing settings when the broker is not configured", async () => {
    const failed = run("scripts/publish.ts", {});
    assert.equal(await failed.exited, 1);
    assert.match(failed.stderr(), /NATS_URL is required/);
  });
});

describe("worker process", () => {
  const databaseUrl = () => requireEnv("TEST_DATABASE_URL");

  function workerEnv(stream: TestStream, smtpPort: number): Record<string, string> {
    return {
      ...natsEnv(stream),
      DATABASE_URL: databaseUrl(),
      SMTP_HOST: "localhost",
      SMTP_PORT: String(smtpPort),
      SMTP_USERNAME: SMTP_USER,
      SMTP_PASSWORD,
      SMTP_TLS_MODE: "disabled",
      NOTIFICATION_FROM: "shipping@example.com",
      NOTIFICATION_TO: "customer-service@example.com",
    };
  }

  it("rejects an invalid configuration, naming each problem but no values", async () => {
    const failed = run("src/main.ts", { DATABASE_URL: "postgres://app:hunter2@db/x", SMTP_PORT: "hunter2" });
    assert.equal(await failed.exited, 1);
    assert.match(failed.stderr(), /SMTP_HOST is required/);
    assert.match(failed.stderr(), /SMTP_PORT must be an integer/);
    assert.match(failed.stderr(), /NATS_URL is required/);
    assert.doesNotMatch(failed.stderr(), /hunter2/);
  });

  it("exits with an error when the database is unreachable", async () => {
    const stream = await provisionStream(connection);
    const failed = run("src/main.ts", { ...workerEnv(stream, 1), DATABASE_URL: "postgres://nobody:none@127.0.0.1:1/none" });
    assert.equal(await failed.exited, 1);
    assert.match(failed.stderr(), /Worker failed/);
  });

  it("handles a published shipment end to end and stops cleanly on SIGTERM", async () => {
    await resetDatabase(databaseUrl());
    const stream = await provisionStream(connection);
    const smtp = await startSmtp("plain");
    const worker = run("src/main.ts", workerEnv(stream, smtp.port));
    try {
      await waitFor("the worker to start consuming", () => (worker.stdout().includes("Consuming shipment events") ? true : undefined));

      const id = randomUUID();
      const published = run("scripts/publish.ts", natsEnv(stream), ["--id", id, "--order-id", "ORD-E2E"]);
      assert.equal(await published.exited, 0, published.stderr());

      const mail = await waitFor("the notification email", () => smtp.messages[0]);
      assert.equal(mail.subject, "Order ORD-E2E shipped");
      const [record] = await waitFor("the completed record", async () => {
        const rows = await queryDatabase<{ order_id: string; email_sent: boolean }>(databaseUrl(), "SELECT * FROM notifications WHERE id = $1", [id]);
        return rows[0]?.email_sent ? rows : undefined;
      });
      assert.equal(record?.order_id, "ORD-E2E");

      worker.child.kill("SIGTERM");
      assert.equal(await worker.exited, 0, worker.stderr());
      assert.match(worker.stdout(), /"message":"Stopped"/);
    } finally {
      worker.child.kill("SIGKILL");
      await smtp.stop();
    }
  });
});
