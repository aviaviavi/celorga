#!/usr/bin/env node

// Long-lived line-oriented search worker for the Celorga app. Each request is
// one JSON line on stdin and each response one JSON line on stdout. The worker
// keeps the corpus search index in memory and reloads it only when the index
// files on disk change, so a query does not pay for process start-up and index
// deserialization the way a one-shot `celorga search` does.
//
// A request with a `files` object searches files on this Mac instead of the
// corpus (see fileSearchService.ts); its response carries `files`.

import readline from "node:readline";
import { fileSearchServiceResponse, type FileSearchServiceRequest } from "./fileSearchService.js";
import type { FileSearchPayload } from "./fileSearch.js";
import { searchIndexServiceResponse, type SearchServiceRequest, type SearchServiceResponse } from "./searchService.js";

type WorkerRequest = SearchServiceRequest & { files?: FileSearchServiceRequest };
type WorkerResponse = SearchServiceResponse | { id: string; files?: FileSearchPayload; error?: string };

function answer(request: WorkerRequest): WorkerResponse {
  if (request && typeof request.files === "object" && request.files !== null) {
    const id = String(request.id ?? "");
    try {
      return { id, files: fileSearchServiceResponse(request.files) };
    } catch (error) {
      return { id, error: error instanceof Error ? error.message : String(error) };
    }
  }
  return searchIndexServiceResponse(request);
}

function respond(response: WorkerResponse): void {
  process.stdout.write(`${JSON.stringify(response)}\n`);
}

const input = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
  terminal: false,
});

for await (const line of input) {
  if (!line) continue;
  let request: WorkerRequest;
  try {
    request = JSON.parse(line) as WorkerRequest;
  } catch (error) {
    respond({ id: "", error: error instanceof Error ? error.message : String(error) });
    continue;
  }
  respond(answer(request));
}
