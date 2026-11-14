CREATE TABLE "notifications" (
	"id" text PRIMARY KEY NOT NULL,
	"order_id" text NOT NULL,
	"shipped_at" timestamp with time zone NOT NULL,
	"email_sent" boolean DEFAULT false NOT NULL
);
