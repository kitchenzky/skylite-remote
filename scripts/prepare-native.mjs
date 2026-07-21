import { cp, mkdir, rm } from "node:fs/promises";
import { resolve } from "node:path";

const projectRoot = resolve(import.meta.dirname, "..");
const outputDirectory = resolve(projectRoot, "native-web");
const bundledFiles = ["index.html", "manifest.json", "icon.svg"];

await rm(outputDirectory, { recursive: true, force: true });
await mkdir(outputDirectory, { recursive: true });

for (const file of bundledFiles) {
  await cp(resolve(projectRoot, file), resolve(outputDirectory, file));
}

console.log(`Prepared ${bundledFiles.length} native web assets in ${outputDirectory}`);
