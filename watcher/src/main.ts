import { KubeConfig, KubernetesObjectApi, makeInformer } from "@kubernetes/client-node";
import { KubernetesCluster } from "./cluster.js";
import { type Logger, Reconciler } from "./reconciler.js";
import type { Profile, Settings } from "./requests.js";

const PROFILE_API_VERSION = "runtimeconditions.io/v1alpha1";
const PROFILE_KIND = "RuntimeConditionsProfile";
const PROFILE_PATH = "/apis/runtimeconditions.io/v1alpha1/runtimeconditionsprofiles";
const INFORMER_RESTART_MS = 5_000;

const log: Logger = {
  info: (message, fields) => console.log(JSON.stringify({ level: "info", message, ...fields })),
  error: (message, fields) => console.error(JSON.stringify({ level: "error", message, ...fields })),
};

function required(name: string): string {
  const value = process.env[name];
  if (value === undefined || value === "") {
    throw new Error(`${name} is required`);
  }
  return value;
}

function readSettings(): Settings {
  return {
    requestNamespace: required("REQUEST_NAMESPACE"),
    smtpFrom: required("SMTP_FROM_ADDRESS"),
    smtpTo: required("SMTP_TO_ADDRESS"),
  };
}

const settings = readSettings();
const resyncMs = Number(process.env.RESYNC_SECONDS ?? "300") * 1000;
if (!Number.isFinite(resyncMs) || resyncMs <= 0) {
  throw new Error("RESYNC_SECONDS must be a positive number");
}

const kubeConfig = new KubeConfig();
kubeConfig.loadFromDefault();
const api = KubernetesObjectApi.makeApiClient(kubeConfig);
const reconciler = new Reconciler(new KubernetesCluster(api, settings.requestNamespace), settings, log);

// Work runs one task at a time; a failed task is logged and the next one still runs.
let queue: Promise<void> = Promise.resolve();
function enqueue(description: string, task: () => Promise<void>): void {
  queue = queue.then(task).catch((error: unknown) => {
    log.error("task failed", { task: description, error: error instanceof Error ? error.message : String(error) });
  });
}

async function listProfiles(): Promise<Profile[]> {
  const list = await api.list<Profile & { metadata: { uid: string } }>(PROFILE_API_VERSION, PROFILE_KIND);
  return list.items;
}

function resync(): void {
  enqueue("resync", async () => {
    const profiles = await listProfiles();
    for (const profile of profiles) {
      await reconciler.reconcile(profile);
    }
    await reconciler.pruneOrphans(new Set(profiles.map((profile) => profile.metadata.uid)));
  });
}

const informer = makeInformer<Profile & { metadata: { uid: string } }>(kubeConfig, PROFILE_PATH, async () => {
  const items = await listProfiles();
  return { apiVersion: PROFILE_API_VERSION, kind: `${PROFILE_KIND}List`, metadata: {}, items };
});
const reconcileProfile = (profile: Profile): void => enqueue(`reconcile ${profile.metadata.namespace}/${profile.metadata.name}`, () => reconciler.reconcile(profile));
informer.on("add", reconcileProfile);
informer.on("update", reconcileProfile);
informer.on("delete", (profile) => enqueue(`delete ${profile.metadata.namespace}/${profile.metadata.name}`, () => reconciler.pruneOrphans(new Set(informer.list().map((item) => item.metadata.uid)))));
informer.on("error", (error: unknown) => {
  log.error("watch failed", { error: error instanceof Error ? error.message : String(error) });
  setTimeout(() => void informer.start(), INFORMER_RESTART_MS);
});

await informer.start();
const timer = setInterval(resync, resyncMs);
log.info("watching profiles", { requestNamespace: settings.requestNamespace });

for (const signal of ["SIGTERM", "SIGINT"] as const) {
  process.once(signal, () => {
    clearInterval(timer);
    void informer.stop().finally(() => queue.finally(() => process.exit(0)));
  });
}
