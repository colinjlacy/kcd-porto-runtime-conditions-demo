// Declarations only: the Runtime Conditions profiler reads this file statically to generate the
// profile, and nothing imports it at runtime. Keep the variable names in step with config.ts.
import { api, datastore, Relational, RelationalEngine, Smtp, SmtpOperationsItem } from "@runtimeconditions/common-integrations";
import {
  RelationalConfiguration,
  RelationalConfigurationEnvItem,
  RelationalConfigurationEnvItemProperty,
  SmtpConfiguration,
  SmtpConfigurationEnvItem,
  SmtpConfigurationEnvItemProperty,
} from "@runtimeconditions/env-configuration";
import {
  Action,
  Configuration,
  ConfigurationEnvItem,
  ConfigurationEnvItemProperty,
  natsService,
  OperationsItem,
  Resource,
  Service,
} from "@runtimeconditions/nats-service";

export const notificationDatabase = datastore(
  new Relational({ engine: RelationalEngine.Postgres }),
  new RelationalConfiguration({
    env: [
      new RelationalConfigurationEnvItem({
        name: "DATABASE_URL",
        property: RelationalConfigurationEnvItemProperty.Url,
        required: true,
        sensitive: true,
      }),
    ],
  }),
);

export const notificationEmail = api(
  new Smtp({ operations: [SmtpOperationsItem.Send] }),
  new SmtpConfiguration({
    env: [
      new SmtpConfigurationEnvItem({ name: "SMTP_HOST", property: SmtpConfigurationEnvItemProperty.Hostname, required: true }),
      new SmtpConfigurationEnvItem({ name: "SMTP_PORT", property: SmtpConfigurationEnvItemProperty.Port, required: true }),
      new SmtpConfigurationEnvItem({ name: "SMTP_USERNAME", property: SmtpConfigurationEnvItemProperty.Username, required: true }),
      new SmtpConfigurationEnvItem({
        name: "SMTP_PASSWORD",
        property: SmtpConfigurationEnvItemProperty.Password,
        required: true,
        sensitive: true,
      }),
      new SmtpConfigurationEnvItem({ name: "SMTP_TLS_MODE", property: SmtpConfigurationEnvItemProperty.TlsMode, required: true }),
      new SmtpConfigurationEnvItem({ name: "NOTIFICATION_FROM", property: SmtpConfigurationEnvItemProperty.FromAddress, required: true }),
      new SmtpConfigurationEnvItem({ name: "NOTIFICATION_TO", property: SmtpConfigurationEnvItemProperty.ToAddress, required: true }),
    ],
  }),
);

export const shipmentEvents = natsService(
  new Service({
    operations: [
      new OperationsItem({ resource: Resource.Connection, action: Action.Connect }),
      new OperationsItem({ resource: Resource.Consumer, action: Action.Consume, stream: "SHIPMENTS", name: "shipment-notifier" }),
      new OperationsItem({ resource: Resource.Subject, action: Action.Subscribe, subject: "orders.shipped" }),
    ],
  }),
  new Configuration({
    env: [
      new ConfigurationEnvItem({ name: "NATS_URL", property: ConfigurationEnvItemProperty.Url, required: true }),
      new ConfigurationEnvItem({ name: "NATS_USERNAME", property: ConfigurationEnvItemProperty.Username, required: true }),
      new ConfigurationEnvItem({
        name: "NATS_PASSWORD",
        property: ConfigurationEnvItemProperty.Password,
        required: true,
        sensitive: true,
      }),
      new ConfigurationEnvItem({ name: "NATS_TLS", property: ConfigurationEnvItemProperty.Tls }),
      new ConfigurationEnvItem({ name: "NATS_STREAM", property: ConfigurationEnvItemProperty.Stream, required: true }),
      new ConfigurationEnvItem({ name: "NATS_SUBJECT", property: ConfigurationEnvItemProperty.Subject, required: true }),
      new ConfigurationEnvItem({ name: "NATS_CONSUMER", property: ConfigurationEnvItemProperty.Consumer, required: true }),
    ],
  }),
);
