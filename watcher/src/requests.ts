import { createHash } from "node:crypto";
import { type Condition, type Integration, readRequirements } from "./conditions.js";

export const GROUP = "platform.runtimeconditions.io";
export const VERSION = "v1alpha1";
export const API_VERSION = `${GROUP}/${VERSION}`;
export const MANAGED_BY = "rcprofile-watcher";
export const IMAGE_ANNOTATION = "demo.runtimeconditions.io/image";
export const SOURCE_UID_LABEL = "demo.runtimeconditions.io/source-uid";

export type Environment = "dev" | "production";
export const ENVIRONMENTS: readonly Environment[] = ["dev", "production"];

const INTEGRATION_KINDS: Record<Environment, Record<Integration, string>> = {
  dev: { postgres: "DevPostgres", smtp: "DevSmtp", nats: "DevNats" },
  production: { postgres: "ProdPostgres", smtp: "ProdSmtp", nats: "ProdNats" },
};
const APPLICATION_KIND = "Application";

export const REQUEST_KINDS: readonly string[] = [
  APPLICATION_KIND,
  ...ENVIRONMENTS.flatMap((environment) => Object.values(INTEGRATION_KINDS[environment])),
];

export interface Profile {
  readonly metadata: {
    readonly name: string;
    readonly namespace: string;
    readonly uid: string;
    readonly annotations?: Record<string, string>;
  };
  readonly workload?: { readonly uri?: string };
  readonly conditions?: readonly Condition[];
}

export interface Settings {
  readonly requestNamespace: string;
  readonly smtpFrom: string;
  readonly smtpTo: string;
}

export interface RequestObject {
  readonly apiVersion: string;
  readonly kind: string;
  readonly metadata: {
    readonly name: string;
    readonly namespace: string;
    readonly labels: Record<string, string>;
    readonly annotations: Record<string, string>;
  };
  readonly spec: Record<string, unknown>;
}

export interface Plan {
  readonly requests: readonly RequestObject[];
  readonly problems: readonly string[];
}

const DIGEST_PATTERN = /^sha256:[0-9a-f]{64}$/;

/** Stable, collision-free identifier for one profile instance; a recreated profile gets a new one. */
export function sourceHash(uid: string): string {
  return createHash("sha256").update(uid).digest("hex").slice(0, 12);
}

/** The container registry path that GitHub-hosted workloads publish to. */
function imageRepository(uri: string | undefined): string | undefined {
  if (uri === undefined || !URL.canParse(uri)) {
    return undefined;
  }
  const url = new URL(uri);
  const path = url.pathname.replace(/^\/|\.git$|\/$/g, "").toLowerCase();
  return url.hostname === "github.com" && path.split("/").length === 2 ? `ghcr.io/${path}` : undefined;
}

function imageReference(profile: Profile, problems: string[]): string | undefined {
  const digest = profile.metadata.annotations?.[IMAGE_ANNOTATION];
  if (digest === undefined) {
    return undefined;
  }
  const repository = imageRepository(profile.workload?.uri);
  if (!DIGEST_PATTERN.test(digest) || repository === undefined) {
    problems.push(`cannot derive an image from workload ${profile.workload?.uri ?? "uri"} and ${IMAGE_ANNOTATION}`);
    return undefined;
  }
  return `${repository}@${digest}`;
}

/** Everything the platform should be running for one profile: a request per integration and environment. */
export function planProfile(profile: Profile, settings: Settings): Plan {
  const requirements = readRequirements(profile.conditions ?? []);
  const problems = [...requirements.problems];
  const image = imageReference(profile, problems);
  const hash = sourceHash(profile.metadata.uid);
  const source = { namespace: profile.metadata.namespace, name: profile.metadata.name, uid: profile.metadata.uid };

  const integrations: [Integration, Record<string, unknown>][] = [];
  if (requirements.postgres) {
    integrations.push(["postgres", {}]);
  }
  if (requirements.smtp) {
    integrations.push(["smtp", { from: settings.smtpFrom, to: settings.smtpTo }]);
  }
  if (requirements.nats !== undefined) {
    integrations.push(["nats", { ...requirements.nats }]);
  }

  const request = (environment: Environment, kind: string, name: string, spec: Record<string, unknown>): RequestObject => ({
    apiVersion: API_VERSION,
    kind,
    metadata: {
      name: `${environment}-${name}-${hash}`,
      namespace: settings.requestNamespace,
      labels: {
        "app.kubernetes.io/managed-by": MANAGED_BY,
        [SOURCE_UID_LABEL]: profile.metadata.uid,
        "demo.runtimeconditions.io/environment": environment,
      },
      annotations: {
        "demo.runtimeconditions.io/source-namespace": profile.metadata.namespace,
        "demo.runtimeconditions.io/source-name": profile.metadata.name,
      },
    },
    spec: { source, ...spec },
  });

  const requests: RequestObject[] = [];
  for (const environment of ENVIRONMENTS) {
    for (const [integration, spec] of integrations) {
      requests.push(request(environment, INTEGRATION_KINDS[environment][integration], integration, spec));
    }
    // An incomplete profile gets its valid dependencies but no application.
    if (problems.length === 0) {
      requests.push(
        request(environment, APPLICATION_KIND, "application", {
          environment,
          dependencies: integrations.map(([integration]) => integration),
          ...(image === undefined ? {} : { image }),
        }),
      );
    }
  }
  return { requests, problems };
}
