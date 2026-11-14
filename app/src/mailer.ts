import nodemailer from "nodemailer";
import type { Config } from "./config.js";

export interface Mailer {
  send(message: { readonly subject: string; readonly text: string }): Promise<void>;
  close(): void;
}

const TIMEOUT_MS = 15_000;

export function createMailer({ smtp, notification }: Pick<Config, "smtp" | "notification">): Mailer {
  const transport = nodemailer.createTransport({
    host: smtp.host,
    port: smtp.port,
    // implicit: TLS from the first byte. starttls: the upgrade must succeed, never falls back to plaintext.
    secure: smtp.tlsMode === "implicit",
    requireTLS: smtp.tlsMode === "starttls",
    ignoreTLS: smtp.tlsMode === "disabled",
    auth: { user: smtp.username, pass: smtp.password },
    connectionTimeout: TIMEOUT_MS,
    greetingTimeout: TIMEOUT_MS,
    socketTimeout: TIMEOUT_MS,
  });

  return {
    async send({ subject, text }) {
      const result = await transport.sendMail({ from: notification.from, to: notification.to, subject, text });
      if (!result.accepted.some((accepted) => accepted === notification.to)) {
        throw new Error("SMTP server did not accept the recipient");
      }
    },
    close: () => transport.close(),
  };
}
