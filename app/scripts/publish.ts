import { randomUUID } from "node:crypto";
import { parseArgs } from "node:util";
import { jetstream } from "@nats-io/jetstream";
import { connect } from "@nats-io/transport-node";
import { loadNatsConfig } from "../src/config.js";

// Publishes one shipped-order event to the broker selected by the NATS_* environment variables.
const { values } = parseArgs({
  options: {
    id: { type: "string", default: randomUUID() },
    "order-id": { type: "string", default: `ORD-${randomUUID().slice(0, 8)}` },
    "shipped-at": { type: "string", default: new Date().toISOString() },
  },
});

const nats = loadNatsConfig();
const connection = await connect({
  servers: nats.url,
  name: "shipment-publisher",
  tls: nats.tls ? {} : undefined,
  ...(nats.username !== undefined && { user: nats.username, pass: nats.password }),
});

try {
  const event = { id: values.id, orderId: values["order-id"], shippedAt: values["shipped-at"] };
  // No message ID is set: publishing an event ID again must reach the worker, which deduplicates.
  const ack = await jetstream(connection).publish(nats.subject, JSON.stringify(event), {
    expect: { streamName: nats.stream },
  });
  console.log(JSON.stringify({ published: event, stream: ack.stream, sequence: ack.seq }));
} finally {
  await connection.drain();
}
