import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { after, before, describe, it } from "node:test";
import { jetstream, jetstreamManager } from "@nats-io/jetstream";
import type { NatsConnection } from "@nats-io/transport-node";
import { connectDatabase, migrateDatabase } from "../src/db.js";
import { RETRY_DELAY_MS } from "../src/notifier.js";
import { startWorker, type Worker } from "../src/worker.js";
import {
  buildConfig, connectNats, eventPayload, provisionStream, queryDatabase, recordingLogger, requireEnv,
  resetDatabase, startSmtp, type TestSmtp, type TestStream, waitFor,
} from "./support.js";

interface NotificationRow {
  id: string;
  order_id: string;
  shipped_at: Date;
  email_sent: boolean;
}

let connection: NatsConnection;
let databaseUrl: string;

before(async () => {
  databaseUrl = requireEnv("TEST_DATABASE_URL");
  connection = await connectNats();
});

after(async () => {
  await connection.drain();
});

const notificationsFor = (id: string) =>
  queryDatabase<NotificationRow>(databaseUrl, "SELECT * FROM notifications WHERE id = $1", [id]);

const publish = (stream: TestStream, payload: string) => jetstream(connection).publish(stream.subject, payload);

async function consumerState(stream: TestStream) {
  const manager = await jetstreamManager(connection);
  return manager.consumers.info(stream.stream, stream.consumer);
}

/** A consumer that has nothing left to do: every delivered message was acknowledged or terminated. */
async function settled(stream: TestStream): Promise<boolean> {
  const state = await consumerState(stream);
  return state.num_pending === 0 && state.num_ack_pending === 0 && state.delivered.stream_seq > 0;
}

interface Scenario {
  readonly stream: TestStream;
  readonly smtp: TestSmtp;
  readonly worker: Worker;
  readonly logger: ReturnType<typeof recordingLogger>;
}

async function withWorker(scenario: (context: Scenario) => Promise<void>): Promise<void> {
  const stream = await provisionStream(connection);
  const smtp = await startSmtp("plain");
  const logger = recordingLogger();
  const worker = await startWorker(buildConfig({ smtpPort: smtp.port, smtpTlsMode: "disabled", stream }), logger);
  try {
    await scenario({ stream, smtp, worker, logger });
  } finally {
    await worker.stop();
    await smtp.stop();
  }
}

describe("shipment worker", () => {
  it("creates the missing tables on first start and keeps data across restarts", async () => {
    await resetDatabase(databaseUrl);
    const exists = async () =>
      (await queryDatabase<{ found: string | null }>(databaseUrl, "SELECT to_regclass('public.notifications') AS found"))[0]?.found;
    assert.equal(await exists(), null);

    await withWorker(async () => {
      assert.equal(await exists(), "notifications");
      await queryDatabase(databaseUrl, "INSERT INTO notifications (id, order_id, shipped_at) VALUES ('kept', 'ORD-KEPT', now())");
    });
    await withWorker(async () => {
      assert.equal((await notificationsFor("kept")).length, 1);
    });
  });

  it("records a shipped order and sends the email", async () => {
    await withWorker(async ({ stream, smtp }) => {
      const id = randomUUID();
      await publish(stream, eventPayload({ id, orderId: "ORD-1001", shippedAt: "2026-11-14T12:30:00Z" }));

      await waitFor("the notification email", () => smtp.messages[0]);
      const [record] = await waitFor("the recorded notification", async () => {
        const rows = await notificationsFor(id);
        return rows[0]?.email_sent ? rows : undefined;
      });
      assert.equal(record?.order_id, "ORD-1001");
      assert.equal(record?.shipped_at.toISOString(), "2026-11-14T12:30:00.000Z");
      assert.equal(record?.email_sent, true);

      assert.equal(smtp.messages.length, 1);
      assert.equal(smtp.messages[0]?.subject, "Order ORD-1001 shipped");
      assert.match(smtp.messages[0]?.text ?? "", /ORD-1001/);
      assert.match(smtp.messages[0]?.text ?? "", /2026-11-14T12:30:00\.000Z/);

      await waitFor("the message to be acknowledged", async () => ((await settled(stream)) ? true : undefined));
      assert.equal((await consumerState(stream)).num_redelivered, 0);
    });
  });

  it("processes several events, one email each", async () => {
    await withWorker(async ({ stream, smtp }) => {
      const orders = ["ORD-A", "ORD-B", "ORD-C"];
      for (const orderId of orders) {
        await publish(stream, eventPayload({ orderId }));
      }
      await waitFor("three emails", () => (smtp.messages.length === 3 ? true : undefined));
      assert.deepEqual(smtp.messages.map((mail) => mail.subject), orders.map((orderId) => `Order ${orderId} shipped`));
    });
  });

  it("does not send again when a completed event arrives a second time", async () => {
    await withWorker(async ({ stream, smtp }) => {
      const payload = eventPayload();
      const { id } = JSON.parse(payload) as { id: string };
      await publish(stream, payload);
      await waitFor("the first email", () => smtp.messages[0]);
      await waitFor("the first message to be acknowledged", async () => ((await settled(stream)) ? true : undefined));

      await publish(stream, payload);
      await waitFor("the duplicate to be acknowledged", async () => {
        const state = await consumerState(stream);
        return state.delivered.stream_seq === 2 && state.num_pending === 0 && state.num_ack_pending === 0 ? true : undefined;
      });

      assert.equal(smtp.messages.length, 1);
      assert.equal((await notificationsFor(id)).length, 1);
    });
  });

  it("discards invalid events without a record, an email, or a retry", async () => {
    await withWorker(async ({ stream, smtp, logger }) => {
      await publish(stream, "this is not json");
      await publish(stream, JSON.stringify({ id: randomUUID(), orderId: "ORD-NO-DATE" }));
      const valid = eventPayload({ orderId: "ORD-VALID" });
      await publish(stream, valid);

      await waitFor("the valid event's email", () => smtp.messages[0]);
      await waitFor("every message to be settled", async () => {
        const state = await consumerState(stream);
        return state.delivered.stream_seq === 3 && state.num_ack_pending === 0 ? true : undefined;
      });

      assert.equal(smtp.messages.length, 1);
      assert.equal(smtp.messages[0]?.subject, "Order ORD-VALID shipped");
      assert.equal(logger.entries.filter((entry) => entry.message === "Discarding invalid event").length, 2);
      assert.equal((await consumerState(stream)).num_redelivered, 0);
      assert.equal((await queryDatabase(databaseUrl, "SELECT 1 FROM notifications WHERE order_id = 'ORD-NO-DATE'")).length, 0);
    });
  });

  it(`keeps the record and retries after ${RETRY_DELAY_MS} ms when the email cannot be sent`, async () => {
    await withWorker(async ({ stream, smtp, logger }) => {
      smtp.failNext(1);
      const id = randomUUID();
      const startedAt = Date.now();
      await publish(stream, eventPayload({ id, orderId: "ORD-RETRY" }));

      await waitFor("the failed attempt", () => logger.entries.find((entry) => entry.message.includes("retrying")));
      const [pending] = await notificationsFor(id);
      assert.equal(pending?.email_sent, false);
      assert.equal(smtp.messages.length, 0);

      await waitFor("the retried email", () => smtp.messages[0], 15_000);
      assert.ok(Date.now() - startedAt >= RETRY_DELAY_MS - 500, "the retry should wait for the retry delay");
      const [sent] = await waitFor("the completed record", async () => {
        const rows = await notificationsFor(id);
        return rows[0]?.email_sent ? rows : undefined;
      });
      assert.equal(sent?.email_sent, true);
      assert.equal(smtp.messages.length, 1);
      assert.equal(smtp.messages[0]?.subject, "Order ORD-RETRY shipped");
    });
  });

  it("keeps working after the database drops its connection", async () => {
    await withWorker(async ({ stream, smtp, logger }) => {
      await publish(stream, eventPayload({ orderId: "ORD-BEFORE" }));
      await waitFor("the first email", () => smtp.messages[0]);

      await queryDatabase(
        databaseUrl,
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid()",
      );
      await waitFor("the connection loss to be noticed", () =>
        logger.entries.find((entry) => entry.message.startsWith("PostgreSQL connection lost")),
      );
      await publish(stream, eventPayload({ orderId: "ORD-AFTER" }));

      await waitFor("the email sent after reconnecting", () => (smtp.messages.length === 2 ? true : undefined), 30_000);
      assert.equal(smtp.messages[1]?.subject, "Order ORD-AFTER shipped");
    });
  });

  it("lets concurrent starts share one migration", async () => {
    await resetDatabase(databaseUrl);
    const logger = recordingLogger();
    const connections = await Promise.all(Array.from({ length: 4 }, () => connectDatabase(databaseUrl, logger)));
    try {
      await Promise.all(connections.map((database) => migrateDatabase(database)));
      const tables = await queryDatabase(databaseUrl, "SELECT 1 FROM information_schema.tables WHERE table_name = 'notifications'");
      assert.equal(tables.length, 1);
      const applied = await queryDatabase(databaseUrl, "SELECT 1 FROM drizzle.__drizzle_migrations");
      assert.equal(applied.length, 1);
    } finally {
      await Promise.all(connections.map(({ pool }) => pool.end()));
    }
  });

  it("refuses to start when the consumer does not exist", async () => {
    const stream = await provisionStream(connection);
    const smtp = await startSmtp("plain");
    try {
      await assert.rejects(
        startWorker(buildConfig({ smtpPort: smtp.port, smtpTlsMode: "disabled", stream: { ...stream, consumer: "missing" } }), recordingLogger()),
      );
    } finally {
      await smtp.stop();
    }
  });

  it("refuses to start when the database is unreachable", async () => {
    const stream = await provisionStream(connection);
    const smtp = await startSmtp("plain");
    try {
      const config = { ...buildConfig({ smtpPort: smtp.port, smtpTlsMode: "disabled", stream }), databaseUrl: "postgres://nobody:none@127.0.0.1:1/none" };
      await assert.rejects(startWorker(config, recordingLogger()));
    } finally {
      await smtp.stop();
    }
  });
});
