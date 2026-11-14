import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { ConfigError, loadConfig, loadNatsConfig } from "../src/config.js";

const valid: NodeJS.ProcessEnv = {
  DATABASE_URL: "postgres://app:db-secret@db.internal:5432/notifier",
  SMTP_HOST: "smtp.internal",
  SMTP_PORT: "587",
  SMTP_USERNAME: "mail-user",
  SMTP_PASSWORD: "mail-secret",
  SMTP_TLS_MODE: "starttls",
  NOTIFICATION_FROM: "shipping@example.com",
  NOTIFICATION_TO: "customer-service@example.com",
  NATS_URL: "nats://nats.internal:4222",
  NATS_USERNAME: "nats-user",
  NATS_PASSWORD: "nats-secret",
  NATS_TLS: "true",
  NATS_STREAM: "SHIPMENTS",
  NATS_SUBJECT: "orders.shipped",
  NATS_CONSUMER: "shipment-notifier",
};

function problemsFor(env: NodeJS.ProcessEnv): readonly string[] {
  try {
    loadConfig(env);
  } catch (error) {
    assert.ok(error instanceof ConfigError);
    return error.problems;
  }
  assert.fail("expected the configuration to be rejected");
}

describe("loadConfig", () => {
  it("reads every setting", () => {
    assert.deepEqual(loadConfig(valid), {
      databaseUrl: valid.DATABASE_URL,
      smtp: { host: "smtp.internal", port: 587, username: "mail-user", password: "mail-secret", tlsMode: "starttls" },
      notification: { from: "shipping@example.com", to: "customer-service@example.com" },
      nats: {
        url: "nats://nats.internal:4222",
        username: "nats-user",
        password: "nats-secret",
        tls: true,
        stream: "SHIPMENTS",
        subject: "orders.shipped",
        consumer: "shipment-notifier",
      },
    });
  });

  it("treats NATS credentials as optional and NATS TLS as off by default", () => {
    const { nats } = loadConfig({ ...valid, NATS_USERNAME: "", NATS_PASSWORD: undefined, NATS_TLS: undefined });
    assert.equal(nats.username, undefined);
    assert.equal(nats.password, undefined);
    assert.equal(nats.tls, false);
  });

  it("accepts each SMTP TLS mode and NATS_TLS in any letter case", () => {
    for (const mode of ["disabled", "starttls", "implicit"] as const) {
      assert.equal(loadConfig({ ...valid, SMTP_TLS_MODE: mode }).smtp.tlsMode, mode);
    }
    assert.equal(loadConfig({ ...valid, NATS_TLS: "TRUE" }).nats.tls, true);
  });

  it("reports every missing required setting together", () => {
    const problems = problemsFor({});
    for (const name of [
      "DATABASE_URL", "SMTP_HOST", "SMTP_PORT", "SMTP_USERNAME", "SMTP_PASSWORD", "SMTP_TLS_MODE",
      "NOTIFICATION_FROM", "NOTIFICATION_TO", "NATS_URL", "NATS_STREAM", "NATS_SUBJECT", "NATS_CONSUMER",
    ]) {
      assert.ok(problems.includes(`${name} is required`), `${name} should be reported`);
    }
  });

  it("treats blank values as missing", () => {
    assert.deepEqual(problemsFor({ ...valid, SMTP_HOST: "   " }), ["SMTP_HOST is required"]);
  });

  it("rejects malformed values", () => {
    const cases: Array<[Record<string, string>, string]> = [
      [{ SMTP_PORT: "0" }, "SMTP_PORT must be an integer from 1 to 65535"],
      [{ SMTP_PORT: "70000" }, "SMTP_PORT must be an integer from 1 to 65535"],
      [{ SMTP_PORT: "25.5" }, "SMTP_PORT must be an integer from 1 to 65535"],
      [{ SMTP_PORT: "smtp" }, "SMTP_PORT must be an integer from 1 to 65535"],
      [{ SMTP_TLS_MODE: "opportunistic" }, "SMTP_TLS_MODE must be one of: disabled, starttls, implicit"],
      [{ NATS_TLS: "yes" }, "NATS_TLS must be true or false"],
      [{ NATS_URL: "http://nats.internal:4222" }, "NATS_URL must be a nats:// or tls:// URL"],
      [{ NATS_URL: "nats.internal" }, "NATS_URL must be a nats:// or tls:// URL"],
      [{ NATS_PASSWORD: "" }, "NATS_USERNAME and NATS_PASSWORD must be set together"],
      [{ NOTIFICATION_TO: "a@example.com, b@example.com" }, "NOTIFICATION_TO must be a single email address"],
      [{ NOTIFICATION_FROM: "not-an-address" }, "NOTIFICATION_FROM must be a single email address"],
      [{ DATABASE_URL: "not a url" }, "DATABASE_URL must be a PostgreSQL connection URL"],
    ];
    for (const [override, expected] of cases) {
      assert.deepEqual(problemsFor({ ...valid, ...override }), [expected], JSON.stringify(override));
    }
  });

  it("never echoes setting values, which may be credentials", () => {
    const message = (() => {
      try {
        loadConfig({ ...valid, SMTP_PASSWORD: undefined, SMTP_PORT: "mail-secret", DATABASE_URL: "db-secret" });
      } catch (error) {
        return String(error instanceof Error ? error.message : error);
      }
      return "";
    })();
    assert.ok(message.includes("SMTP_PORT"));
    assert.ok(!message.includes("mail-secret"));
    assert.ok(!message.includes("db-secret"));
  });
});

describe("loadNatsConfig", () => {
  it("needs only the NATS settings", () => {
    const natsOnly = Object.fromEntries(Object.entries(valid).filter(([name]) => name.startsWith("NATS_")));
    assert.equal(loadNatsConfig(natsOnly).subject, "orders.shipped");
  });

  it("rejects an incomplete NATS configuration", () => {
    assert.throws(() => loadNatsConfig({}), ConfigError);
  });
});
