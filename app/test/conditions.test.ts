import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";
import { ConfigError, loadConfig } from "../src/config.js";

const appRoot = fileURLToPath(new URL("..", import.meta.url));

function generateProfile(): string {
  return execFileSync(
    "npx",
    ["runtimeconditions-typescript-profiler", "profile", "generate", "--project", ".", "--name", "shipment-notifier", "--workload-uri", "https://example.com/shipment-notifier"],
    { cwd: appRoot, encoding: "utf8" },
  );
}

/** The environment variable names the application actually reads. */
function variablesRead(): Set<string> {
  const names = new Set<string>();
  const recorder = new Proxy({}, {
    get(_target, name) {
      if (typeof name === "string") {
        names.add(name);
      }
      return undefined;
    },
  }) as NodeJS.ProcessEnv;
  assert.throws(() => loadConfig(recorder), ConfigError);
  return names;
}

describe("declared conditions", () => {
  const profile = generateProfile();

  it("declare PostgreSQL, SMTP, and NATS with the approved extensions", () => {
    assert.match(profile, /extensions:\n(  - .+\n)+/);
    for (const extension of [
      "https://runtimeconditions.io/extensions/rc/common-integrations:v1alpha2",
      "https://runtimeconditions.io/extensions/rc/env-configuration:v1alpha2",
      "https://runtimeconditions.io/extensions/nats/service:0.2.0",
    ]) {
      assert.ok(profile.includes(`  - ${extension}\n`), extension);
    }
    assert.match(profile, /kind: datastore\n\s+interface:\n\s+type: relational\n\s+engine: postgres/);
    assert.match(profile, /kind: api\n\s+interface:\n\s+type: smtp\n\s+operations:\n\s+- send/);
    assert.match(profile, /kind: nats\.service/);
    assert.match(profile, /action: consume\n\s+stream: SHIPMENTS\n\s+name: shipment-notifier/);
  });

  it("name exactly the environment variables the application reads", () => {
    const declared = new Set([...profile.matchAll(/- name: ([A-Z][A-Z0-9_]*)\n\s+property:/g)].map((match) => match[1]));
    assert.deepEqual([...declared].sort(), [...variablesRead()].sort());
  });

  it("mark every credential sensitive", () => {
    for (const name of ["DATABASE_URL", "SMTP_PASSWORD", "NATS_PASSWORD"]) {
      assert.match(profile, new RegExp(`name: ${name}\\n\\s+property: \\w+\\n\\s+required: true\\n\\s+sensitive: true`), name);
    }
  });
});
