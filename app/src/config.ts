export type SmtpTlsMode = "disabled" | "starttls" | "implicit";

export interface Config {
  readonly databaseUrl: string;
  readonly smtp: {
    readonly host: string;
    readonly port: number;
    readonly username: string;
    readonly password: string;
    readonly tlsMode: SmtpTlsMode;
  };
  readonly notification: {
    readonly from: string;
    readonly to: string;
  };
  readonly nats: {
    readonly url: string;
    readonly username: string | undefined;
    readonly password: string | undefined;
    readonly tls: boolean;
    readonly stream: string;
    readonly subject: string;
    readonly consumer: string;
  };
}

export class ConfigError extends Error {
  constructor(readonly problems: readonly string[]) {
    super(`Invalid configuration:\n${problems.map((problem) => `- ${problem}`).join("\n")}`);
    this.name = "ConfigError";
  }
}

const TLS_MODES: readonly SmtpTlsMode[] = ["disabled", "starttls", "implicit"];
const ADDRESS_PATTERN = /^[^\s@<>,;]+@[^\s@<>,;]+$/;

interface Reader {
  readonly problems: string[];
  optional(name: string): string | undefined;
  required(name: string): string;
  address(name: string): string;
}

function createReader(env: NodeJS.ProcessEnv): Reader {
  const problems: string[] = [];
  const optional = (name: string): string | undefined => {
    const value = env[name]?.trim();
    return value === undefined || value === "" ? undefined : value;
  };
  const required = (name: string): string => {
    const value = optional(name);
    if (value === undefined) {
      problems.push(`${name} is required`);
      return "";
    }
    return value;
  };
  const address = (name: string): string => {
    const value = required(name);
    if (value !== "" && !ADDRESS_PATTERN.test(value)) {
      problems.push(`${name} must be a single email address`);
    }
    return value;
  };
  return { problems, optional, required, address };
}

function readNats(reader: Reader): Config["nats"] {
  const { problems, optional, required } = reader;
  const url = required("NATS_URL");
  if (url !== "") {
    const protocol = URL.canParse(url) ? new URL(url).protocol : "";
    if (protocol !== "nats:" && protocol !== "tls:") {
      problems.push("NATS_URL must be a nats:// or tls:// URL");
    }
  }

  const username = optional("NATS_USERNAME");
  const password = optional("NATS_PASSWORD");
  if ((username === undefined) !== (password === undefined)) {
    problems.push("NATS_USERNAME and NATS_PASSWORD must be set together");
  }

  const rawTls = optional("NATS_TLS")?.toLowerCase() ?? "false";
  if (rawTls !== "true" && rawTls !== "false") {
    problems.push("NATS_TLS must be true or false");
  }

  return {
    url,
    username,
    password,
    tls: rawTls === "true",
    stream: required("NATS_STREAM"),
    subject: required("NATS_SUBJECT"),
    consumer: required("NATS_CONSUMER"),
  };
}

/**
 * Reads and validates the process environment. Every problem is reported at once,
 * and values (which may be credentials) are never included in messages.
 */
export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const reader = createReader(env);
  const { problems, required, address } = reader;

  const databaseUrl = required("DATABASE_URL");
  if (databaseUrl !== "" && !URL.canParse(databaseUrl)) {
    problems.push("DATABASE_URL must be a PostgreSQL connection URL");
  }

  const rawPort = required("SMTP_PORT");
  const port = Number(rawPort);
  if (rawPort !== "" && !(Number.isInteger(port) && port >= 1 && port <= 65535)) {
    problems.push("SMTP_PORT must be an integer from 1 to 65535");
  }

  const rawTlsMode = required("SMTP_TLS_MODE");
  const tlsMode = TLS_MODES.find((mode) => mode === rawTlsMode);
  if (rawTlsMode !== "" && tlsMode === undefined) {
    problems.push(`SMTP_TLS_MODE must be one of: ${TLS_MODES.join(", ")}`);
  }

  const smtp = {
    host: required("SMTP_HOST"),
    port,
    username: required("SMTP_USERNAME"),
    password: required("SMTP_PASSWORD"),
    tlsMode: tlsMode ?? "disabled",
  };
  const notification = { from: address("NOTIFICATION_FROM"), to: address("NOTIFICATION_TO") };
  const nats = readNats(reader);

  if (problems.length > 0) {
    throw new ConfigError(problems);
  }
  return { databaseUrl, smtp, notification, nats };
}

/** The NATS settings alone, for tools that only talk to the broker. */
export function loadNatsConfig(env: NodeJS.ProcessEnv = process.env): Config["nats"] {
  const reader = createReader(env);
  const nats = readNats(reader);
  if (reader.problems.length > 0) {
    throw new ConfigError(reader.problems);
  }
  return nats;
}
