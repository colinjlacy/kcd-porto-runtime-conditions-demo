import { loadConfig } from "./config.js";
import { errorMessage, logger } from "./log.js";
import { startWorker } from "./worker.js";

async function main(): Promise<void> {
  const worker = await startWorker(loadConfig(), logger);

  let stopRequested = false;
  const requestStop = (signal: string): void => {
    if (stopRequested) {
      return;
    }
    stopRequested = true;
    logger.info("Stopping", { signal });
    worker.stop().catch((error: unknown) => logger.error("Shutdown failed", { reason: errorMessage(error) }));
  };
  process.on("SIGTERM", () => requestStop("SIGTERM"));
  process.on("SIGINT", () => requestStop("SIGINT"));

  await worker.done;
  logger.info("Stopped");
}

main().catch((error: unknown) => {
  logger.error("Worker failed", { reason: errorMessage(error) });
  process.exitCode = 1;
});
