import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { OUT_DIR } from "./config.js";

/** Repo path of this package (snapshot), resolved from this module. */
const HERE = dirname(fileURLToPath(import.meta.url));
export const ROOT = join(HERE, "..");

export function outPath(...parts: string[]): string {
  return join(ROOT, OUT_DIR, ...parts);
}

export function fixturePath(...parts: string[]): string {
  return join(ROOT, "fixtures", ...parts);
}

/** Serialize an object to JSON, converting bigints to decimal strings. */
export function writeJson(path: string, data: unknown): void {
  mkdirSync(dirname(path), { recursive: true });
  const json = JSON.stringify(
    data,
    (_k, v) => (typeof v === "bigint" ? v.toString() : v),
    2,
  );
  writeFileSync(path, json + "\n", "utf8");
}

export function writeText(path: string, text: string): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, text, "utf8");
}

export function readJson<T>(path: string): T {
  return JSON.parse(readFileSync(path, "utf8")) as T;
}

export function fileExists(path: string): boolean {
  return existsSync(path);
}
