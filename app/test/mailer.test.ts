import assert from "node:assert/strict";
import { after, describe, it } from "node:test";
import type { Config } from "../src/config.js";
import { createMailer } from "../src/mailer.js";
import { SMTP_PASSWORD, SMTP_USER, startSmtp, type SmtpMode, type TestSmtp } from "./support.js";

const notification = { from: "shipping@example.com", to: "customer-service@example.com" };
const message = { subject: "Order ORD-1 shipped", text: "Order ORD-1 has shipped.\n" };

const servers: TestSmtp[] = [];
after(async () => {
  await Promise.all(servers.map((server) => server.stop()));
});

async function setup(mode: SmtpMode, tlsMode: Config["smtp"]["tlsMode"], password = SMTP_PASSWORD) {
  const server = await startSmtp(mode);
  servers.push(server);
  const mailer = createMailer({
    notification,
    smtp: { host: "localhost", port: server.port, username: SMTP_USER, password, tlsMode },
  });
  return { server, mailer };
}

describe("createMailer", () => {
  it("delivers a plain-text message with the configured sender and recipient", async () => {
    const { server, mailer } = await setup("plain", "disabled");
    await mailer.send(message);
    mailer.close();

    assert.equal(server.messages.length, 1);
    const [mail] = server.messages;
    assert.equal(mail?.subject, message.subject);
    assert.equal(mail?.text, message.text);
    assert.equal(mail?.html, false);
    assert.equal(mail?.from?.value[0]?.address, notification.from);
    assert.equal(mail?.to && !Array.isArray(mail.to) ? mail.to.value[0]?.address : undefined, notification.to);
  });

  it("authenticates, and fails when the server rejects the credentials", async () => {
    const { server, mailer } = await setup("plain", "disabled", "wrong-password");
    await assert.rejects(mailer.send(message), /Invalid username or password|Invalid login|authentication/i);
    mailer.close();
    assert.equal(server.messages.length, 0);
  });

  it("upgrades with STARTTLS when the mode is starttls", async () => {
    const { server, mailer } = await setup("starttls", "starttls");
    await mailer.send(message);
    mailer.close();
    assert.equal(server.messages.length, 1);
  });

  it("refuses to fall back to plaintext when STARTTLS is unavailable", async () => {
    const { server, mailer } = await setup("no-starttls", "starttls");
    await assert.rejects(mailer.send(message));
    mailer.close();
    assert.equal(server.messages.length, 0);
  });

  it("uses TLS from the first byte when the mode is implicit", async () => {
    const { server, mailer } = await setup("implicit", "implicit");
    await mailer.send(message);
    mailer.close();
    assert.equal(server.messages.length, 1);
  });

  it("fails when the server defers the message", async () => {
    const { server, mailer } = await setup("plain", "disabled");
    server.failNext(1);
    await assert.rejects(mailer.send(message), /Try again later/);
    await mailer.send(message);
    mailer.close();
    assert.equal(server.messages.length, 1);
  });

  it("does not send credentials over a connection that skips TLS when TLS is required", async () => {
    // The server only offers AUTH after TLS; a client that skipped TLS must not deliver anything.
    const { server, mailer } = await setup("starttls", "disabled");
    await assert.rejects(mailer.send(message));
    mailer.close();
    assert.equal(server.messages.length, 0);
  });
});
