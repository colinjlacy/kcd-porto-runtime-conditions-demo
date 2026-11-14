import { boolean, pgTable, text, timestamp } from "drizzle-orm/pg-core";

export const notifications = pgTable("notifications", {
  id: text("id").primaryKey(),
  orderId: text("order_id").notNull(),
  shippedAt: timestamp("shipped_at", { withTimezone: true }).notNull(),
  emailSent: boolean("email_sent").notNull().default(false),
});
