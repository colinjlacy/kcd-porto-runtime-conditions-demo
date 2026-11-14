import assert from "node:assert/strict";
import { test } from "node:test";
import type { Condition } from "../src/conditions.js";
import { IMAGE_ANNOTATION, type Profile, type Settings, planProfile } from "../src/requests.js";

const settings: Settings = { requestNamespace: "promise-workflows", smtpFrom: "admin@example.com", smtpTo: "ops@example.com" };
const digest = `sha256:${"a".repeat(64)}`;

const postgres: Condition = { name: "database", kind: "datastore", interface: { type: "relational", engine: "postgres" } };
const smtp: Condition = { name: "mail", kind: "api", interface: { type: "smtp", operations: ["send"] } };
const nats: Condition = {
  name: "events",
  kind: "nats.service",
  interface: {
    type: "service",
    operations: [
      { resource: "connection", action: "connect" },
      { resource: "consumer", action: "consume", stream: "SHIPMENTS", name: "notifier" },
      { resource: "subject", action: "subscribe", subject: "orders.shipped" },
    ],
  },
};

function profile(conditions: Condition[], annotations?: Record<string, string>): Profile {
  return {
    metadata: { name: "shipment-notifier", namespace: "demo", uid: "uid-1", ...(annotations === undefined ? {} : { annotations }) },
    workload: { uri: "https://github.com/Colinjlacy/KCD-Demo" },
    conditions,
  };
}

test("creates a request per integration and environment, plus an application", () => {
  const plan = planProfile(profile([postgres, smtp, nats], { [IMAGE_ANNOTATION]: digest }), settings);
  assert.deepEqual(plan.problems, []);
  assert.deepEqual(
    plan.requests.map((request) => request.kind),
    ["DevPostgres", "DevSmtp", "DevNats", "Application", "ProdPostgres", "ProdSmtp", "ProdNats", "Application"],
  );
  const application = plan.requests.find((request) => request.kind === "Application" && request.spec.environment === "production");
  assert.deepEqual(application?.spec.dependencies, ["postgres", "smtp", "nats"]);
  assert.equal(application?.spec.image, `ghcr.io/colinjlacy/kcd-demo@${digest}`);
});

test("passes the integration details through", () => {
  const plan = planProfile(profile([smtp, nats]), settings);
  const mail = plan.requests.find((request) => request.kind === "DevSmtp");
  assert.deepEqual(mail?.spec, { source: { namespace: "demo", name: "shipment-notifier", uid: "uid-1" }, from: "admin@example.com", to: "ops@example.com" });
  const broker = plan.requests.find((request) => request.kind === "ProdNats");
  assert.equal(broker?.spec.stream, "SHIPMENTS");
  assert.equal(broker?.spec.subject, "orders.shipped");
  assert.equal(broker?.spec.consumer, "notifier");
});

test("omits the image until the image digest is recorded", () => {
  const plan = planProfile(profile([postgres]), settings);
  const application = plan.requests.find((request) => request.kind === "Application");
  assert.equal("image" in (application?.spec ?? {}), false);
});

test("names requests after the profile instance, not its name", () => {
  const first = planProfile(profile([postgres]), settings);
  const recreated = planProfile({ ...profile([postgres]), metadata: { name: "shipment-notifier", namespace: "demo", uid: "uid-2" } }, settings);
  assert.notEqual(first.requests[0]?.metadata.name, recreated.requests[0]?.metadata.name);
  assert.match(first.requests[0]?.metadata.name ?? "", /^dev-postgres-[0-9a-f]{12}$/);
});

test("withholds the application when a condition is unsupported", () => {
  const plan = planProfile(profile([postgres, { name: "cache", kind: "datastore", interface: { type: "kv" } }]), settings);
  assert.equal(plan.problems.length, 1);
  assert.deepEqual(
    plan.requests.map((request) => request.kind),
    ["DevPostgres", "ProdPostgres"],
  );
});

test("ignores unsupported optional conditions", () => {
  const plan = planProfile(profile([postgres, { name: "cache", kind: "datastore", optional: true, interface: { type: "kv" } }]), settings);
  assert.deepEqual(plan.problems, []);
});

test("reports a nats condition without a subject and a duplicate integration", () => {
  const withoutSubject: Condition = { ...nats, interface: { type: "service", operations: [{ resource: "consumer", action: "consume", stream: "S", name: "c" }] } };
  assert.match(planProfile(profile([withoutSubject]), settings).problems.join(), /subject/);
  const duplicate = planProfile(profile([postgres, { ...postgres, name: "second" }]), settings);
  assert.match(duplicate.problems.join(), /second postgres/);
});

test("reports an image annotation that cannot be resolved", () => {
  const plan = planProfile(profile([postgres], { [IMAGE_ANNOTATION]: "latest" }), settings);
  assert.equal(plan.problems.length, 1);
  assert.equal(
    plan.requests.some((request) => request.kind === "Application"),
    false,
  );
});
