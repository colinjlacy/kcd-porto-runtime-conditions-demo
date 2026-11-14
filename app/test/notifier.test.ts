import assert from "node:assert/strict";
import { describe, it } from "node:test";
import type { Database } from "../src/db.js";
import type { Mailer } from "../src/mailer.js";
import { type Delivery, handleDelivery, InvalidEventError, MAX_ATTEMPTS, parseEvent, RETRY_DELAY_MS } from "../src/notifier.js";
import { eventPayload, recordingLogger } from "./support.js";

const bytes = (text: string): Uint8Array => new TextEncoder().encode(text);

describe("parseEvent", () => {
  it("reads id, orderId, and shippedAt", () => {
    const event = parseEvent(bytes(JSON.stringify({ id: "e-1", orderId: "ORD-1", shippedAt: "2026-11-14T12:30:00+02:00", extra: true })));
    assert.equal(event.id, "e-1");
    assert.equal(event.orderId, "ORD-1");
    assert.equal(event.shippedAt.toISOString(), "2026-11-14T10:30:00.000Z");
  });

  it("rejects payloads that are not an event", () => {
    const valid = { id: "e-1", orderId: "ORD-1", shippedAt: "2026-11-14T12:30:00Z" };
    const invalid: Array<[string, string]> = [
      ["not json", "{"],
      ["a JSON array", "[]"],
      ["JSON null", "null"],
      ["a bare string", '"shipped"'],
      ["invalid UTF-8", "\u0000"],
      ["a missing id", JSON.stringify({ ...valid, id: undefined })],
      ["an empty id", JSON.stringify({ ...valid, id: "" })],
      ["a numeric id", JSON.stringify({ ...valid, id: 7 })],
      ["a blank orderId", JSON.stringify({ ...valid, orderId: "  " })],
      ["an orderId that could inject headers", JSON.stringify({ ...valid, orderId: "ORD-1\r\nBcc: attacker@example.com" })],
      ["an oversized orderId", JSON.stringify({ ...valid, orderId: "x".repeat(201) })],
      ["a missing shippedAt", JSON.stringify({ ...valid, shippedAt: undefined })],
      ["a non-date shippedAt", JSON.stringify({ ...valid, shippedAt: "yesterday" })],
      ["a date without a time zone", JSON.stringify({ ...valid, shippedAt: "2026-11-14T12:30:00" })],
      ["an impossible date", JSON.stringify({ ...valid, shippedAt: "2026-13-45T12:30:00Z" })],
    ];
    for (const [description, payload] of invalid) {
      assert.throws(() => parseEvent(bytes(payload)), InvalidEventError, description);
    }
  });

  it("rejects bytes that are not UTF-8", () => {
    assert.throws(() => parseEvent(new Uint8Array([0xff, 0xfe, 0xfd])), InvalidEventError);
  });
});

interface Outcome {
  acked: number;
  naks: Array<number | undefined>;
  terms: Array<string | undefined>;
}

function delivery(data: string, deliveryCount: number): { delivery: Delivery; outcome: Outcome } {
  const outcome: Outcome = { acked: 0, naks: [], terms: [] };
  return {
    outcome,
    delivery: {
      data: bytes(data),
      info: { deliveryCount },
      ack: () => void (outcome.acked += 1),
      nak: (millis) => void outcome.naks.push(millis),
      term: (reason) => void outcome.terms.push(reason),
    },
  };
}

// A database that cannot be reached: the first call made through it fails.
const unreachableDatabase = new Proxy({}, {
  get() {
    throw new Error("connection refused");
  },
}) as Database;
const neverCalledMailer: Mailer = { send: () => assert.fail("no email should be sent"), close: () => undefined };

describe("handleDelivery", () => {
  it("terminates an invalid event without touching the database or mailer", async () => {
    const logger = recordingLogger();
    const { delivery: message, outcome } = delivery("not json", 1);
    await handleDelivery({ db: unreachableDatabase, mailer: neverCalledMailer, logger }, message);
    assert.equal(outcome.acked, 0);
    assert.deepEqual(outcome.naks, []);
    assert.equal(outcome.terms.length, 1);
    assert.equal(logger.entries[0]?.level, "error");
  });

  it(`redelivers after ${RETRY_DELAY_MS} ms while attempts remain`, async () => {
    for (let attempt = 1; attempt < MAX_ATTEMPTS; attempt += 1) {
      const logger = recordingLogger();
      const { delivery: message, outcome } = delivery(eventPayload(), attempt);
      await handleDelivery({ db: unreachableDatabase, mailer: neverCalledMailer, logger }, message);
      assert.deepEqual(outcome, { acked: 0, naks: [RETRY_DELAY_MS], terms: [] }, `attempt ${attempt}`);
    }
  });

  it("gives up and terminates on the final attempt", async () => {
    const logger = recordingLogger();
    const { delivery: message, outcome } = delivery(eventPayload(), MAX_ATTEMPTS);
    await handleDelivery({ db: unreachableDatabase, mailer: neverCalledMailer, logger }, message);
    assert.equal(outcome.acked, 0);
    assert.deepEqual(outcome.naks, []);
    assert.deepEqual(outcome.terms, ["retries exhausted"]);
    assert.equal(logger.entries.at(-1)?.level, "error");
  });

  it("logs why handling failed", async () => {
    const logger = recordingLogger();
    const { delivery: message } = delivery(eventPayload(), 1);
    await handleDelivery({ db: unreachableDatabase, mailer: neverCalledMailer, logger }, message);
    assert.equal(logger.entries[0]?.fields?.reason, "connection refused");
  });
});
