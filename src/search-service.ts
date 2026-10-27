#!/usr/bin/env node

// Long-lived line-oriented search worker for the Celorga app. Each request is
// one JSON line on stdin and each response one JSON line on stdout. The worker
// keeps the corpus search index in memory and reloads it only when the index
// files on disk change, so a query does not pay for process start-up and index
// deserialization the way a one-shot `celorga search` does.

import readline from "node:readline";
import { searchIndexServiceResponse, type SearchServiceRequest, type SearchServiceResponse } from "./searchService.js";

function respond(response: SearchServiceResponse): void {
  process.stdout.write(`${JSON.stringify(response)}\n`);
}

const input = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
  terminal: false,
});

for await (const line of input) {
  if (!line) continue;
  let request: SearchServiceRequest;
  try {
    request = JSON.parse(line) as SearchServiceRequest;
  } catch (error) {
    respond({ id: "", error: error instanceof Error ? error.message : String(error) });
    continue;
  }
  respond(searchIndexServiceResponse(request));
}
