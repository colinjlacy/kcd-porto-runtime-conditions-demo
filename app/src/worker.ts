import { jetstream } from "@nats-io/jetstream";
import { connect } from "@nats-io/transport-node";
import type { Config } from "./config.js";
import { connectDatabase, migrateDatabase } from "./db.js";
import type { Logger } from "./log.js";
import { createMailer } from "./mailer.js";
import { handleDelivery } from "./notifier.js";

export interface Worker {
  /** Settles when consumption ends: resolves after stop(), rejects if the worker fails. */
  readonly done: Promise<void>;
  /** Finishes the message in progress, then releases every connection. */
  stop(): Promise<void>;
}

export async function startWorker(config: Config, logger: Logger): Promise<Worker> {
  const cleanups: Array<() => Promise<void> | void> = [];
  const releaseAll = async (): Promise<void> => {
    for (let cleanup = cleanups.pop(); cleanup !== undefined; cleanup = cleanups.pop()) {
      await cleanup();
    }
  };

  try {
    const database = await connectDatabase(config.databaseUrl, logger);
    cleanups.push(() => database.pool.end());
    await migrateDatabase(database);
    logger.info("Database migrations applied");

    const mailer = createMailer(config);
    cleanups.push(() => mailer.close());

    const connection = await connect({
      servers: config.nats.url,
      name: "shipment-notifier",
      tls: config.nats.tls ? {} : undefined,
      ...(config.nats.username !== undefined && { user: config.nats.username, pass: config.nats.password }),
      maxReconnectAttempts: -1,
    });
    cleanups.push(() => connection.drain());

    // The platform owns the stream and consumer; this only binds to them.
    const consumer = await jetstream(connection).consumers.get(config.nats.stream, config.nats.consumer);
    // One message at a time, so a message waiting in a local buffer cannot exceed its ack wait.
    const messages = await consumer.consume({ max_messages: 1, abort_on_missing_resource: true });
    logger.info("Consuming shipment events", { stream: config.nats.stream, consumer: config.nats.consumer });

    const deps = { db: database.db, mailer, logger };
    const loop = (async () => {
      for await (const message of messages) {
        await handleDelivery(deps, message);
      }
    })();

    let stopping = false;
    const done = loop.then(
      async () => {
        await releaseAll();
        if (!stopping) {
          throw new Error("Message consumption ended unexpectedly");
        }
      },
      async (error: unknown) => {
        await releaseAll();
        throw error;
      },
    );

    return {
      done,
      stop: async () => {
        stopping = true;
        await messages.close();
        await done;
      },
    };
  } catch (error) {
    await releaseAll();
    throw error;
  }
}
