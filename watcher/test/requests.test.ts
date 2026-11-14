import assert from "node:assert/strict";
import { test } from "node:test";
import type { Condition } from "../src/conditions.js";
import { IMAGE_ANNOTATION, type Profile, type RequestObject, type Settings, planProfile } from "../src/requests.js";

const settings: Settings = {
  requestNamespace: "promise-workflows",
  smtpFrom: "admin@example.com",
  smtpTo: "ops@example.com",
  images: { postgresClient: "postgres-client", curl: "curl", natsBox: "nats-box" },
};
const digest = `sha256:${"a".repeat(64)}`;

const postgres: Condition = {
  name: "database",
  kind: "datastore",
  interface: { type: "relational", engine: "postgres" },
  configuration: { env: [{ name: "DATABASE_URL", property: "url", required: true }] },
};
const smtp: Condition = {
  name: "mail",
  kind: "api",
  interface: { type: "smtp", operations: ["send"] },
  configuration: {
    env: [
      { name: "SMTP_HOST", property: "hostname", required: true },
      { name: "NOTIFICATION_FROM", property: "fromAddress", required: true },
      { name: "NOTIFICATION_TO", property: "toAddress", required: true },
    ],
  },
};
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
  configuration: {
    env: [
      { name: "NATS_URL", property: "url", required: true },
      { name: "NATS_SUBJECT", property: "subject", required: true },
      { name: "NATS_CONSUMER", property: "consumer", required: true },
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

function find(requests: readonly RequestObject[], kind: string, environment: string): RequestObject | undefined {
  return requests.find((request) => request.kind === kind && request.metadata.labels["demo.runtimeconditions.io/environment"] === environment);
}

test("creates integration requests and a workload per environment", () => {
  const plan = planProfile(profile([postgres, smtp, nats], { [IMAGE_ANNOTATION]: digest }), settings);
  assert.deepEqual(plan.problems, []);
  assert.deepEqual(
    plan.requests.map((request) => `${request.apiVersion} ${request.kind}`),
    [
      "dev.platform.runtimeconditions.io/v1alpha1 PostgresDatabase",
      "dev.platform.runtimeconditions.io/v1alpha1 EmailSender",
      "dev.platform.runtimeconditions.io/v1alpha1 NatsStream",
      "production.platform.runtimeconditions.io/v1alpha1 PostgresDatabase",
      "production.platform.runtimeconditions.io/v1alpha1 EmailSender",
      "production.platform.runtimeconditions.io/v1alpha1 NatsStream",
      "platform.runtimeconditions.io/v1alpha1 Workload",
      "platform.runtimeconditions.io/v1alpha1 Workload",
    ],
  );
});

test("passes the integration details through", () => {
  const plan = planProfile(profile([smtp, nats]), settings);
  assert.deepEqual(find(plan.requests, "EmailSender", "dev")?.spec, { sender: "admin@example.com" });
  assert.deepEqual(find(plan.requests, "NatsStream", "production")?.spec, {
    stream: "SHIPMENTS",
    subjects: ["orders.shipped"],
    consumers: [{ name: "notifier", filterSubject: "orders.shipped" }],
  });
});

test("builds the workload from the profile's declared variables and the environment's bindings", () => {
  const plan = planProfile(profile([postgres, smtp, nats], { [IMAGE_ANNOTATION]: digest }), settings);
  const workload = find(plan.requests, "Workload", "production");
  const hash = (workload?.metadata.name ?? "").split("-").pop();
  assert.equal(workload?.metadata.name, `production-workload-${hash}`);
  assert.equal(workload?.spec.image, `ghcr.io/colinjlacy/kcd-demo@${digest}`);
  assert.deepEqual(workload?.spec.destinationLabels, { environment: "production" });
  assert.deepEqual(workload?.spec.env, [
    { name: "DATABASE_URL", valueFrom: { secretKeyRef: { name: `production-postgres-${hash}`, key: "uri" } } },
    { name: "SMTP_HOST", valueFrom: { secretKeyRef: { name: `production-email-${hash}`, key: "host" } } },
    { name: "NOTIFICATION_FROM", valueFrom: { secretKeyRef: { name: `production-email-${hash}`, key: "sender" } } },
    { name: "NOTIFICATION_TO", value: "ops@example.com" },
    { name: "NATS_URL", valueFrom: { secretKeyRef: { name: `production-nats-${hash}`, key: "url" } } },
    { name: "NATS_SUBJECT", value: "orders.shipped" },
    { name: "NATS_CONSUMER", value: "notifier" },
  ]);
  const checks = workload?.spec.checks as { name: string; image: string }[];
  assert.deepEqual(
    checks.map((check) => [check.name, check.image]),
    [
      ["wait-for-postgres", "postgres-client"],
      ["wait-for-smtp", "curl"],
      ["wait-for-nats", "nats-box"],
    ],
  );
});

test("withholds the workload until the image digest is recorded", () => {
  const plan = planProfile(profile([postgres]), settings);
  assert.equal(find(plan.requests, "Workload", "dev"), undefined);
  assert.notEqual(find(plan.requests, "PostgresDatabase", "dev"), undefined);
});

test("names requests after the profile instance, not its name", () => {
  const first = planProfile(profile([postgres]), settings);
  const recreated = planProfile({ ...profile([postgres]), metadata: { name: "shipment-notifier", namespace: "demo", uid: "uid-2" } }, settings);
  assert.notEqual(first.requests[0]?.metadata.name, recreated.requests[0]?.metadata.name);
  assert.match(first.requests[0]?.metadata.name ?? "", /^dev-postgres-[0-9a-f]{12}$/);
});

test("withholds the workload when a condition is unsupported", () => {
  const plan = planProfile(profile([postgres, { name: "cache", kind: "datastore", interface: { type: "kv" } }], { [IMAGE_ANNOTATION]: digest }), settings);
  assert.equal(plan.problems.length, 1);
  assert.deepEqual(
    plan.requests.map((request) => request.kind),
    ["PostgresDatabase", "PostgresDatabase"],
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

test("reports a required variable the platform cannot provide, and skips an optional one", () => {
  const unknown = (required: boolean): Condition => ({ ...postgres, configuration: { env: [{ name: "DATABASE_POOL", property: "poolSize", required }] } });
  const required = planProfile(profile([unknown(true)], { [IMAGE_ANNOTATION]: digest }), settings);
  assert.match(required.problems.join(), /poolSize/);
  assert.equal(find(required.requests, "Workload", "dev"), undefined);
  const optional = planProfile(profile([unknown(false)], { [IMAGE_ANNOTATION]: digest }), settings);
  assert.deepEqual(optional.problems, []);
  assert.deepEqual(find(optional.requests, "Workload", "dev")?.spec.env, []);
});

test("reports an image annotation that cannot be resolved", () => {
  const plan = planProfile(profile([postgres], { [IMAGE_ANNOTATION]: "latest" }), settings);
  assert.equal(plan.problems.length, 1);
  assert.equal(
    plan.requests.some((request) => request.kind === "Workload"),
    false,
  );
});
