import { type Profile, type RequestObject, type Settings, planProfile } from "./requests.js";

export interface ExistingRequest {
  readonly apiVersion: string;
  readonly kind: string;
  readonly name: string;
  readonly sourceUid: string;
}

/** The cluster operations the reconciler needs; the Kubernetes implementation lives in cluster.ts. */
export interface Cluster {
  apply(request: RequestObject): Promise<void>;
  listRequests(): Promise<readonly ExistingRequest[]>;
  deleteRequest(request: ExistingRequest): Promise<void>;
  warn(profile: Profile, reason: string, message: string): Promise<void>;
}

export interface Logger {
  info(message: string, fields?: Record<string, unknown>): void;
  error(message: string, fields?: Record<string, unknown>): void;
}

export class Reconciler {
  /** Problems already reported per profile UID, so unchanged problems are not re-emitted. */
  private readonly reported = new Map<string, string>();

  constructor(
    private readonly cluster: Cluster,
    private readonly settings: Settings,
    private readonly log: Logger,
  ) {}

  /**
   * Brings one profile's requests in line with its conditions: applies each desired request
   * (an update keeps the existing resource) and deletes this profile's requests that are no longer
   * wanted. A failing request does not stop the others.
   */
  async reconcile(profile: Profile): Promise<void> {
    const uid = profile.metadata.uid;
    const plan = planProfile(profile, this.settings);
    const failures: string[] = [];

    for (const request of plan.requests) {
      try {
        await this.cluster.apply(request);
      } catch (error) {
        failures.push(`${request.kind}/${request.metadata.name}: ${describe(error)}`);
      }
    }

    const wanted = new Set(plan.requests.map((request) => `${request.apiVersion}/${request.kind}/${request.metadata.name}`));
    try {
      for (const existing of await this.cluster.listRequests()) {
        if (existing.sourceUid === uid && !wanted.has(`${existing.apiVersion}/${existing.kind}/${existing.name}`)) {
          await this.cluster.deleteRequest(existing);
        }
      }
    } catch (error) {
      failures.push(`pruning: ${describe(error)}`);
    }

    await this.report(profile, [...plan.problems, ...failures]);
    this.log.info("reconciled profile", {
      namespace: profile.metadata.namespace,
      name: profile.metadata.name,
      uid,
      requests: plan.requests.length,
      problems: plan.problems.length + failures.length,
    });
  }

  /** Deletes every request that belongs to profiles whose UID is not in `alive`. */
  async pruneOrphans(alive: ReadonlySet<string>): Promise<void> {
    for (const existing of await this.cluster.listRequests()) {
      if (!alive.has(existing.sourceUid)) {
        await this.cluster.deleteRequest(existing);
        this.log.info("deleted orphaned request", { kind: existing.kind, name: existing.name, uid: existing.sourceUid });
      }
    }
    for (const uid of this.reported.keys()) {
      if (!alive.has(uid)) {
        this.reported.delete(uid);
      }
    }
  }

  private async report(profile: Profile, problems: readonly string[]): Promise<void> {
    const uid = profile.metadata.uid;
    const summary = problems.join("; ");
    if (summary === "") {
      this.reported.delete(uid);
      return;
    }
    if (this.reported.get(uid) === summary) {
      return;
    }
    this.reported.set(uid, summary);
    this.log.error("profile has problems", { namespace: profile.metadata.namespace, name: profile.metadata.name, summary });
    try {
      await this.cluster.warn(profile, "ReconcileProblem", summary);
    } catch (error) {
      this.log.error("could not record event", { error: describe(error) });
    }
  }
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
