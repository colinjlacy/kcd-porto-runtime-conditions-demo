import type { EnvDeclaration, Requirements } from "./conditions.js";

export interface EnvVar {
  readonly name: string;
  readonly value?: string;
  readonly valueFrom?: { readonly secretKeyRef: { readonly name: string; readonly key: string } };
}

export interface Check {
  readonly name: string;
  readonly image: string;
  readonly command: readonly string[];
  readonly env: readonly EnvVar[];
}

export interface Images {
  readonly postgresClient: string;
  readonly curl: string;
  readonly natsBox: string;
}

/** Request names; each request publishes a binding Secret of the same name. */
export interface BindingNames {
  readonly postgres: string;
  readonly email: string;
  readonly nats: string;
}

export interface WorkloadParts {
  readonly env: readonly EnvVar[];
  readonly checks: readonly Check[];
  readonly problems: readonly string[];
}

/** Binding Secret key that satisfies each RCProfile environment property. */
const POSTGRES_KEYS: Record<string, string> = { url: "uri" };
const EMAIL_KEYS: Record<string, string> = {
  hostname: "host",
  port: "port",
  username: "username",
  password: "password",
  tlsMode: "tlsMode",
  fromAddress: "sender",
};
const NATS_KEYS: Record<string, string> = { url: "url", username: "username", password: "password", tls: "tls", stream: "stream" };

const POSTGRES_CHECK = `url=$(printf '%s' "$DATABASE_URL" | sed 's/sslmode=no-verify/sslmode=require/')
until psql "$url" -v ON_ERROR_STOP=1 -tAc 'select 1' >/dev/null; do sleep 5; done`;

const EMAIL_CHECK = `scheme=smtp
flags=
case "$SMTP_TLS_MODE" in
  starttls) flags=--ssl-reqd ;;
  implicit) scheme=smtps ;;
esac
until curl --silent --show-error --max-time 20 $flags \\
  --user "$SMTP_USERNAME:$SMTP_PASSWORD" -X NOOP \\
  "$scheme://$SMTP_HOST:$SMTP_PORT"; do sleep 5; done`;

const NATS_CHECK = `until nats --server "$NATS_URL" --user "$NATS_USERNAME" --password "$NATS_PASSWORD" \\
  consumer info "$NATS_STREAM" "$NATS_CONSUMER" >/dev/null; do sleep 5; done`;

function secretEnv(name: string, secret: string, key: string): EnvVar {
  return { name, valueFrom: { secretKeyRef: { name: secret, key } } };
}

/**
 * Maps a condition's declared environment variables to binding Secret keys, or to literal values
 * for properties the binding does not carry. A required property with no source is a problem.
 */
function mapEnv(
  declarations: readonly EnvDeclaration[],
  secret: string,
  keys: Record<string, string>,
  literals: Record<string, string>,
  label: string,
  problems: string[],
): EnvVar[] {
  const env: EnvVar[] = [];
  for (const declaration of declarations) {
    const key = keys[declaration.property];
    const literal = literals[declaration.property];
    if (key !== undefined) {
      env.push(secretEnv(declaration.name, secret, key));
    } else if (literal !== undefined) {
      env.push({ name: declaration.name, value: literal });
    } else if (declaration.required) {
      problems.push(`${label}: the platform has no value for property ${declaration.property} (${declaration.name})`);
    }
  }
  return env;
}

/** The environment and readiness checks a workload needs for the integrations its profile declares. */
export function workloadParts(requirements: Requirements, names: BindingNames, images: Images, recipient: string): WorkloadParts {
  const env: EnvVar[] = [];
  const checks: Check[] = [];
  const problems: string[] = [];

  const { postgres, smtp, nats } = requirements;
  if (postgres !== undefined) {
    env.push(...mapEnv(postgres.env, names.postgres, POSTGRES_KEYS, {}, "postgres", problems));
    checks.push({
      name: "wait-for-postgres",
      image: images.postgresClient,
      command: ["sh", "-c", POSTGRES_CHECK],
      env: [secretEnv("DATABASE_URL", names.postgres, "uri")],
    });
  }

  if (smtp !== undefined) {
    env.push(...mapEnv(smtp.env, names.email, EMAIL_KEYS, { toAddress: recipient }, "smtp", problems));
    checks.push({
      name: "wait-for-smtp",
      image: images.curl,
      command: ["sh", "-c", EMAIL_CHECK],
      env: [
        secretEnv("SMTP_HOST", names.email, "host"),
        secretEnv("SMTP_PORT", names.email, "port"),
        secretEnv("SMTP_USERNAME", names.email, "username"),
        secretEnv("SMTP_PASSWORD", names.email, "password"),
        secretEnv("SMTP_TLS_MODE", names.email, "tlsMode"),
      ],
    });
  }

  if (nats !== undefined) {
    const literals = { subject: nats.subject, consumer: nats.consumer };
    env.push(...mapEnv(nats.env, names.nats, NATS_KEYS, literals, "nats", problems));
    checks.push({
      name: "wait-for-nats",
      image: images.natsBox,
      command: ["sh", "-c", NATS_CHECK],
      env: [
        secretEnv("NATS_URL", names.nats, "url"),
        secretEnv("NATS_USERNAME", names.nats, "username"),
        secretEnv("NATS_PASSWORD", names.nats, "password"),
        secretEnv("NATS_STREAM", names.nats, "stream"),
        { name: "NATS_CONSUMER", value: nats.consumer },
      ],
    });
  }

  return { env, checks, problems };
}
