import { createHash } from "node:crypto";
import { type Condition, readRequirements } from "./conditions.js";
import { type Images, workloadParts } from "./workload.js";

export const MANAGED_BY = "rcprofile-watcher";
export const IMAGE_ANNOTATION = "demo.runtimeconditions.io/image";
export const SOURCE_UID_LABEL = "demo.runtimeconditions.io/source-uid";

const PLATFORM_GROUP = "platform.runtimeconditions.io";
const VERSION = "v1alpha1";

export type Environment = "dev" | "production";
export const ENVIRONMENTS: readonly Environment[] = ["dev", "production"];

export interface RequestType {
  readonly apiVersion: string;
  readonly kind: string;
}

// Integration requests live in a per-environment API group; workloads are shared by all environments.
const environmentApiVersion = (environment: Environment): string => `${environment}.${PLATFORM_GROUP}/${VERSION}`;
const WORKLOAD: RequestType = { apiVersion: `${PLATFORM_GROUP}/${VERSION}`, kind: "Workload" };
const POSTGRES = "PostgresDatabase";
const NATS = "NatsStream";
const EMAIL = "EmailSender";

export const REQUEST_TYPES: readonly RequestType[] = [
  WORKLOAD,
  ...ENVIRONMENTS.flatMap((environment) =>
    [POSTGRES, NATS, EMAIL].map((kind) => ({ apiVersion: environmentApiVersion(environment), kind })),
  ),
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
  readonly images: Images;
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

/** Everything the platform should be running for one profile: integration requests and a workload per environment. */
export function planProfile(profile: Profile, settings: Settings): Plan {
  const requirements = readRequirements(profile.conditions ?? []);
  const problems = [...requirements.problems];
  const image = imageReference(profile, problems);
  const hash = sourceHash(profile.metadata.uid);

  const request = (
    environment: Environment,
    type: RequestType,
    name: string,
    spec: Record<string, unknown>,
  ): RequestObject => ({
    apiVersion: type.apiVersion,
    kind: type.kind,
    metadata: {
      name,
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
    spec,
  });

  const requests: RequestObject[] = [];
  const workloads: RequestObject[] = [];
  for (const [index, environment] of ENVIRONMENTS.entries()) {
    const environmentType = (kind: string): RequestType => ({ apiVersion: environmentApiVersion(environment), kind });
    const names = {
      postgres: `${environment}-postgres-${hash}`,
      email: `${environment}-email-${hash}`,
      nats: `${environment}-nats-${hash}`,
    };
    if (requirements.postgres !== undefined) {
      requests.push(request(environment, environmentType(POSTGRES), names.postgres, {}));
    }
    if (requirements.smtp !== undefined) {
      requests.push(request(environment, environmentType(EMAIL), names.email, { sender: settings.smtpFrom }));
    }
    if (requirements.nats !== undefined) {
      const { stream, subject, consumer } = requirements.nats;
      requests.push(
        request(environment, environmentType(NATS), names.nats, {
          stream,
          subjects: [subject],
          consumers: [{ name: consumer, filterSubject: subject }],
        }),
      );
    }

    const parts = workloadParts(requirements, names, settings.images, settings.smtpTo);
    if (index === 0) {
      // The environments differ only in the names, so their problems are the same.
      problems.push(...parts.problems);
    }
    if (image !== undefined) {
      workloads.push(
        request(environment, WORKLOAD, `${environment}-workload-${hash}`, {
          destinationLabels: { environment },
          image,
          env: parts.env,
          checks: parts.checks,
        }),
      );
    }
  }

  // An incomplete profile gets its valid integrations but no workload.
  if (problems.length === 0) {
    requests.push(...workloads);
  }
  return { requests, problems };
}
