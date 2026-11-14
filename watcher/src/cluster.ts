import { KubernetesObjectApi, PatchStrategy, type KubernetesObject } from "@kubernetes/client-node";
import type { Cluster, ExistingRequest } from "./reconciler.js";
import { MANAGED_BY, type Profile, REQUEST_TYPES, type RequestObject, SOURCE_UID_LABEL } from "./requests.js";

const FIELD_MANAGER = MANAGED_BY;

function isNotFound(error: unknown): boolean {
  const status = error as { code?: number; statusCode?: number };
  return status.code === 404 || status.statusCode === 404;
}

/** Kubernetes implementation of the reconciler's cluster operations. */
export class KubernetesCluster implements Cluster {
  constructor(
    private readonly api: KubernetesObjectApi,
    private readonly requestNamespace: string,
  ) {}

  async apply(request: RequestObject): Promise<void> {
    await this.api.patch(request as unknown as KubernetesObject, undefined, undefined, FIELD_MANAGER, true, PatchStrategy.ServerSideApply);
  }

  async listRequests(): Promise<readonly ExistingRequest[]> {
    const found: ExistingRequest[] = [];
    for (const { apiVersion, kind } of REQUEST_TYPES) {
      const list = await this.api.list(apiVersion, kind, this.requestNamespace, undefined, undefined, undefined, undefined, `app.kubernetes.io/managed-by=${MANAGED_BY}`);
      for (const item of list.items) {
        const sourceUid = item.metadata?.labels?.[SOURCE_UID_LABEL];
        if (item.metadata?.name !== undefined && sourceUid !== undefined) {
          found.push({ apiVersion, kind, name: item.metadata.name, sourceUid });
        }
      }
    }
    return found;
  }

  async deleteRequest(request: ExistingRequest): Promise<void> {
    try {
      await this.api.delete({ apiVersion: request.apiVersion, kind: request.kind, metadata: { name: request.name, namespace: this.requestNamespace } });
    } catch (error) {
      if (!isNotFound(error)) {
        throw error;
      }
    }
  }

  async warn(profile: Profile, reason: string, message: string): Promise<void> {
    await this.api.create({
      apiVersion: "v1",
      kind: "Event",
      metadata: { generateName: "rcprofile-watcher-", namespace: profile.metadata.namespace },
      involvedObject: {
        apiVersion: "runtimeconditions.io/v1alpha1",
        kind: "RuntimeConditionsProfile",
        name: profile.metadata.name,
        namespace: profile.metadata.namespace,
        uid: profile.metadata.uid,
      },
      type: "Warning",
      reason,
      message: message.slice(0, 1024),
      source: { component: MANAGED_BY },
      firstTimestamp: new Date(),
      lastTimestamp: new Date(),
      count: 1,
    } as KubernetesObject);
  }
}
