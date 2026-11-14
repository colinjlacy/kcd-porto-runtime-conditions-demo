import { eq } from "drizzle-orm";
import type { Database } from "./db.js";
import { errorMessage, type Logger } from "./log.js";
import type { Mailer } from "./mailer.js";
import { notifications } from "./schema.js";

export const MAX_ATTEMPTS = 5;
export const RETRY_DELAY_MS = 5_000;

export interface ShipmentEvent {
  readonly id: string;
  readonly orderId: string;
  readonly shippedAt: Date;
}

/** The parts of a JetStream message that handling depends on. */
export interface Delivery {
  readonly data: Uint8Array;
  readonly info: { readonly deliveryCount: number };
  ack(): void;
  nak(millis?: number): void;
  term(reason?: string): void;
}

export class InvalidEventError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "InvalidEventError";
  }
}

const ISO_TIMESTAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})$/;
const MAX_FIELD_LENGTH = 200;

function textField(value: Record<string, unknown>, name: string): string {
  const field = value[name];
  if (typeof field !== "string" || field.trim() === "" || field.length > MAX_FIELD_LENGTH) {
    throw new InvalidEventError(`${name} must be a non-empty string of at most ${MAX_FIELD_LENGTH} characters`);
  }
  // Control characters would let an order ID alter the email's headers.
  if (/\p{Cc}/u.test(field)) {
    throw new InvalidEventError(`${name} must not contain control characters`);
  }
  return field;
}

export function parseEvent(data: Uint8Array): ShipmentEvent {
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(data));
  } catch {
    throw new InvalidEventError("payload is not valid JSON");
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new InvalidEventError("payload must be a JSON object");
  }
  const fields = value as Record<string, unknown>;
  const shippedAt = textField(fields, "shippedAt");
  const shippedTime = new Date(shippedAt);
  if (!ISO_TIMESTAMP.test(shippedAt) || Number.isNaN(shippedTime.getTime())) {
    throw new InvalidEventError("shippedAt must be an ISO 8601 timestamp with a time zone");
  }
  return { id: textField(fields, "id"), orderId: textField(fields, "orderId"), shippedAt: shippedTime };
}

/** Records the shipment, then emails it once. Safe to repeat for the same event. */
export async function recordAndNotify(
  { db, mailer }: { readonly db: Database; readonly mailer: Mailer },
  event: ShipmentEvent,
): Promise<void> {
  await db
    .insert(notifications)
    .values({ id: event.id, orderId: event.orderId, shippedAt: event.shippedAt })
    .onConflictDoNothing();

  const [record] = await db
    .select({ emailSent: notifications.emailSent })
    .from(notifications)
    .where(eq(notifications.id, event.id));
  if (record?.emailSent) {
    return;
  }

  await mailer.send({
    subject: `Order ${event.orderId} shipped`,
    text: `Order ${event.orderId} has shipped.\n\nShipped at: ${event.shippedAt.toISOString()}\nEvent ID: ${event.id}\n`,
  });
  await db.update(notifications).set({ emailSent: true }).where(eq(notifications.id, event.id));
}

export async function handleDelivery(
  deps: { readonly db: Database; readonly mailer: Mailer; readonly logger: Logger },
  delivery: Delivery,
): Promise<void> {
  const { logger } = deps;
  let event: ShipmentEvent;
  try {
    event = parseEvent(delivery.data);
  } catch (error) {
    const reason = errorMessage(error);
    logger.error("Discarding invalid event", { reason });
    delivery.term(reason);
    return;
  }

  try {
    await recordAndNotify(deps, event);
    delivery.ack();
    logger.info("Shipment notification complete", { eventId: event.id, orderId: event.orderId });
  } catch (error) {
    const attempt = delivery.info.deliveryCount;
    const fields = { eventId: event.id, attempt, reason: errorMessage(error) };
    if (attempt >= MAX_ATTEMPTS) {
      logger.error("Giving up on event after the final attempt", fields);
      delivery.term("retries exhausted");
    } else {
      logger.warn("Shipment notification failed; retrying", { ...fields, retryInMs: RETRY_DELAY_MS });
      delivery.nak(RETRY_DELAY_MS);
    }
  }
}
