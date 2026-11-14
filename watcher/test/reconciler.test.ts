import assert from "node:assert/strict";
import { test } from "node:test";
import type { Condition } from "../src/conditions.js";
import { type Cluster, type ExistingRequest, Reconciler } from "../src/reconciler.js";
import type { Profile, RequestObject, Settings } from "../src/requests.js";

const settings: Settings = { requestNamespace: "promise-workflows", smtpFrom: "admin@example.com", smtpTo: "ops@example.com" };
const postgres: Condition = { name: "database", kind: "datastore", interface: { type: "relational", engine: "postgres" } };
const smtp: Condition = { name: "mail", kind: "api", interface: { type: "smtp", operations: ["send"] } };
const silent = { info: () => undefined, error: () => undefined };

class FakeCluster implements Cluster {
  readonly requests = new Map<string, RequestObject>();
  readonly warnings: string[] = [];
  failing = new Set<string>();

  async apply(request: RequestObject): Promise<void> {
    if (this.failing.has(request.kind)) {
      throw new Error(`${request.kind} rejected`);
    }
    this.requests.set(`${request.kind}/${request.metadata.name}`, request);
  }
  async listRequests(): Promise<readonly ExistingRequest[]> {
    return [...this.requests.values()].map((request) => ({ kind: request.kind, name: request.metadata.name, sourceUid: request.metadata.labels["demo.runtimeconditions.io/source-uid"] ?? "" }));
  }
  async deleteRequest(request: ExistingRequest): Promise<void> {
    this.requests.delete(`${request.kind}/${request.name}`);
  }
  async warn(_profile: Profile, _reason: string, message: string): Promise<void> {
    this.warnings.push(message);
  }
}

function profile(uid: string, conditions: Condition[]): Profile {
  return { metadata: { name: "shipment-notifier", namespace: "demo", uid }, workload: { uri: "https://github.com/o/r" }, conditions };
}

test("removes requests for conditions a profile no longer declares", async () => {
  const cluster = new FakeCluster();
  const reconciler = new Reconciler(cluster, settings, silent);
  await reconciler.reconcile(profile("uid-1", [postgres, smtp]));
  assert.equal(cluster.requests.size, 6);
  await reconciler.reconcile(profile("uid-1", [postgres]));
  assert.deepEqual([...cluster.requests.keys()].map((key) => key.split("/")[0]).sort(), ["Application", "Application", "DevPostgres", "ProdPostgres"]);
});

test("leaves other profiles alone when one is reconciled", async () => {
  const cluster = new FakeCluster();
  const reconciler = new Reconciler(cluster, settings, silent);
  await reconciler.reconcile(profile("uid-1", [postgres]));
  await reconciler.reconcile(profile("uid-2", [postgres]));
  await reconciler.reconcile(profile("uid-1", [smtp]));
  const owned = (uid: string, kind: string): number =>
    [...cluster.requests.values()].filter((request) => request.kind === kind && request.metadata.labels["demo.runtimeconditions.io/source-uid"] === uid).length;
  assert.equal(owned("uid-1", "DevPostgres"), 0);
  assert.equal(owned("uid-1", "DevSmtp"), 1);
  assert.equal(owned("uid-2", "DevPostgres"), 1);
});

test("deletes the requests of profiles that no longer exist", async () => {
  const cluster = new FakeCluster();
  const reconciler = new Reconciler(cluster, settings, silent);
  await reconciler.reconcile(profile("uid-1", [postgres]));
  await reconciler.reconcile(profile("uid-2", [postgres]));
  await reconciler.pruneOrphans(new Set(["uid-2"]));
  assert.equal(cluster.requests.size, 4);
});

test("keeps applying other requests when one fails, and reports the failure once", async () => {
  const cluster = new FakeCluster();
  cluster.failing.add("DevPostgres");
  const reconciler = new Reconciler(cluster, settings, silent);
  await reconciler.reconcile(profile("uid-1", [postgres]));
  await reconciler.reconcile(profile("uid-1", [postgres]));
  assert.equal(cluster.requests.size, 3);
  assert.equal(cluster.warnings.length, 1);
  assert.match(cluster.warnings[0] ?? "", /DevPostgres/);
});
