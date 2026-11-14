export type Integration = "postgres" | "smtp" | "nats";

/** One environment variable a condition's configuration asks for. */
export interface EnvDeclaration {
  readonly name: string;
  readonly property: string;
  readonly required: boolean;
}

export interface Condition {
  readonly name?: string;
  readonly kind?: string;
  readonly optional?: boolean;
  readonly interface?: {
    readonly type?: string;
    readonly engine?: string;
    readonly operations?: readonly unknown[];
  };
  readonly configuration?: {
    readonly env?: readonly { readonly name?: string; readonly property?: string; readonly required?: boolean }[];
  };
}

export interface Requirement {
  readonly env: readonly EnvDeclaration[];
}

export interface NatsRequirement extends Requirement {
  readonly stream: string;
  readonly subject: string;
  readonly consumer: string;
}

export interface Requirements {
  readonly postgres: Requirement | undefined;
  readonly smtp: Requirement | undefined;
  readonly nats: NatsRequirement | undefined;
  /** Conditions that are invalid or unsupported and not optional. */
  readonly problems: readonly string[];
}

function label(condition: Condition, index: number): string {
  return `condition ${condition.name ?? index}`;
}

function operationList(condition: Condition): readonly Record<string, unknown>[] {
  const operations = condition.interface?.operations ?? [];
  return operations.filter((operation): operation is Record<string, unknown> => typeof operation === "object" && operation !== null);
}

function readEnv(condition: Condition): EnvDeclaration[] {
  const declarations: EnvDeclaration[] = [];
  for (const item of condition.configuration?.env ?? []) {
    if (typeof item.name === "string" && typeof item.property === "string") {
      // An item is required unless the profile says otherwise.
      declarations.push({ name: item.name, property: item.property, required: item.required !== false });
    }
  }
  return declarations;
}

function readNats(condition: Condition, name: string, problems: string[]): NatsRequirement | undefined {
  const operations = operationList(condition);
  const consumer = operations.find((operation) => operation.resource === "consumer" && operation.action === "consume");
  const subscription = operations.find((operation) => operation.resource === "subject" && operation.action === "subscribe");
  const stream = consumer?.stream;
  const consumerName = consumer?.name;
  const subject = subscription?.subject;
  if (typeof stream !== "string" || typeof consumerName !== "string") {
    problems.push(`${name}: nats.service needs a consumer consume operation with a stream and a name`);
    return undefined;
  }
  if (typeof subject !== "string") {
    problems.push(`${name}: nats.service needs a subject subscribe operation naming the subject`);
    return undefined;
  }
  return { stream, subject, consumer: consumerName, env: readEnv(condition) };
}

/**
 * Maps a profile's conditions to the integrations the platform can provision. Each integration
 * may be declared once per profile because its resources are named after the profile.
 */
export function readRequirements(conditions: readonly Condition[]): Requirements {
  const problems: string[] = [];
  const found = new Set<Integration>();
  let postgres: Requirement | undefined;
  let smtp: Requirement | undefined;
  let nats: NatsRequirement | undefined;

  conditions.forEach((condition, index) => {
    const name = label(condition, index);
    const type = condition.interface?.type;
    let integration: Integration | undefined;
    if (condition.kind === "datastore" && type === "relational" && condition.interface?.engine === "postgres") {
      integration = "postgres";
    } else if (condition.kind === "api" && type === "smtp" && condition.interface?.operations?.includes("send")) {
      integration = "smtp";
    } else if (condition.kind === "nats.service" && type === "service") {
      integration = "nats";
    }

    if (integration === undefined) {
      if (condition.optional !== true) {
        problems.push(`${name}: unsupported ${condition.kind ?? "unknown"} / ${type ?? "unknown"} condition`);
      }
      return;
    }
    if (found.has(integration)) {
      problems.push(`${name}: a second ${integration} condition is not supported`);
      return;
    }
    if (integration === "nats") {
      nats = readNats(condition, name, problems);
      if (nats === undefined) {
        return;
      }
    } else if (integration === "postgres") {
      postgres = { env: readEnv(condition) };
    } else {
      smtp = { env: readEnv(condition) };
    }
    found.add(integration);
  });

  return { postgres, smtp, nats, problems };
}
