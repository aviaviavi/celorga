import fs from "node:fs";
import path from "node:path";
import { findConfigFile } from "./config.js";
import {
  citationReport,
  conceptIndex,
  distillationQueue,
  relatedNotes,
  renderConceptIndexOrg,
  researchSettings,
} from "./research.js";
import { reportHiddenOrgDirectories } from "./corpusFiles.js";

const HELP = `celorga research

Research notes over plain Org files: citations resolved against BibTeX,
quoted passages checked against their sources, sources that no note distills
yet, and a concept index from note tags.

Usage:
  celorga research citations [--dir CORPUS] [--file NOTE.org]... [--format text|json]
  celorga research check [--dir CORPUS] [--file NOTE.org]... [--format text|json]
  celorga research queue [--dir CORPUS] [--all] [--format text|json]
  celorga research concepts [--dir CORPUS] [--out views/concepts.org] [--apply] [--format text|json]
  celorga research related --file NOTE.org [--dir CORPUS] [--limit N] [--format text|json]

Citations are org-cite ([cite:@key]) and org-ref links (cite:key, citep:key,
citet:key, [[citep:&key]]). Keys resolve against #+BIBLIOGRAPHY: files in the
note, then research.bibliography in celorga.json, then references.bib or
bibliography.bib at the corpus root. A BibTeX file field links the key to its
source.

check lists unresolved keys and quotes that do not appear in their source,
and exits 1 when it finds any. A quote is a #+begin_quote block cited inside
it or in the paragraph right after it, or a passage of five or more words in
double quotes with a citation or file: link right after (or before) it, at
most four words away. Sources are the cited
key's file (or a .txt, .md, .org or .html file beside it, such as paper.txt
for paper.pdf) or a file: link, limited to its lines when the link ends in
::N or ::N-M.

queue lists source files under research.sourceDirs (default raw/ and
sources/) and bibliography entries that no note cites, links to, or names in
a :SOURCE_KEYS: property. --all also lists the distilled ones.

concepts writes an index of notes by tag. It previews by default; --apply
writes --out (default views/concepts.org).

--dir defaults to the folder of the nearest celorga.json.`;

const VALUE_FLAGS = new Set(["--dir", "--file", "--format", "--out", "--limit"]);
const BOOLEAN_FLAGS = new Set(["--apply", "--json", "--all"]);

type Parsed = { action: string; flags: Map<string, string[]>; booleans: Set<string> };

function parse(args: string[]): Parsed {
  const values = [...args];
  const action = values.shift() || "";
  const flags = new Map<string, string[]>();
  const booleans = new Set<string>();
  while (values.length) {
    const token = values.shift()!;
    if (BOOLEAN_FLAGS.has(token)) { booleans.add(token); continue; }
    if (VALUE_FLAGS.has(token)) {
      const value = values.shift();
      if (value === undefined) throw new Error(`Missing value for ${token}`);
      flags.set(token, [...(flags.get(token) ?? []), value]);
      continue;
    }
    throw new Error(`Unknown research option: ${token}`);
  }
  return { action, flags, booleans };
}

function corpusRoot(parsed: Parsed): string {
  const dir = parsed.flags.get("--dir")?.at(-1);
  if (dir) return path.resolve(dir);
  const configPath = findConfigFile(process.cwd());
  if (configPath) return path.dirname(configPath);
  throw new Error("Required: --dir CORPUS (or run inside a corpus with celorga.json)");
}

function format(parsed: Parsed): "text" | "json" {
  if (parsed.booleans.has("--json")) return "json";
  const value = parsed.flags.get("--format")?.at(-1) ?? "text";
  if (value !== "text" && value !== "json") throw new Error("--format must be text or json");
  return value;
}

function write(value: unknown, text: string, mode: "text" | "json"): void {
  process.stdout.write(mode === "json" ? JSON.stringify(value, null, 2) + "\n" : text.replace(/\n*$/, "\n"));
}

function relative(root: string, file: string): string {
  const value = path.relative(root, file);
  return value && !value.startsWith("..") ? value : file;
}

export async function runResearchCommand(args: string[]): Promise<void> {
  if (!args.length || args.includes("--help") || args.includes("-h")) { process.stdout.write(HELP + "\n"); return; }
  const parsed = parse(args);
  const root = corpusRoot(parsed);
  const settings = researchSettings(root);
  const mode = format(parsed);
  const files = parsed.flags.get("--file")?.map((file) => path.resolve(file));
  if (!files) reportHiddenOrgDirectories(root);

  switch (parsed.action) {
    case "citations":
    case "check": {
      const report = citationReport(settings, files);
      if (parsed.action === "check") {
        const unresolved = report.citations.filter((citation) => citation.unresolvedKeys.length);
        const mismatched = report.quotes.filter((quote) => quote.status === "mismatch");
        const lines = [
          ...unresolved.map((citation) => `${relative(root, citation.file)}:${citation.line}: unresolved citation ${citation.unresolvedKeys.map((key) => `@${key}`).join(", ")}`),
          ...mismatched.map((quote) => `${relative(root, quote.file)}:${quote.line}: ${quote.message}: “${quote.text}”`),
        ];
        const unverifiable = report.quotes.filter((quote) => quote.status === "unverifiable");
        const summary = `${report.summary.citations} citations, ${report.summary.unresolvedKeys} unresolved keys; ${report.summary.quotes} quotes: ${report.summary.verified} verified, ${report.summary.mismatched} not found, ${report.summary.unverifiable} without a readable source.`;
        write({ ...report, citations: unresolved, quotes: [...mismatched, ...unverifiable] },
          [...lines, ...unverifiable.map((quote) => `${relative(root, quote.file)}:${quote.line}: not checked: ${quote.message}`), summary].join("\n"), mode);
        if (unresolved.length || mismatched.length) process.exitCode = 1;
        return;
      }
      const lines = report.citations.map((citation) => `${relative(root, citation.file)}:${citation.line}\t${citation.keys.map((key) => `@${key}`).join("; ")}${citation.unresolvedKeys.length ? `\tunresolved: ${citation.unresolvedKeys.join(", ")}` : ""}`);
      lines.push(...report.quotes.map((quote) => `${relative(root, quote.file)}:${quote.line}\tquote ${quote.status}\t${quote.message}`));
      if (!report.bibliography.length) lines.push("No bibliography found; keys are listed without resolving them.");
      write(report, lines.join("\n") || "No citations or cited quotes.", mode);
      return;
    }
    case "queue": {
      const queue = distillationQueue(settings, files);
      const all = parsed.booleans.has("--all");
      const payload = all ? queue : { ...queue, distilled: undefined, distilledCount: queue.distilled.length };
      const describe = (source: { source: string; title?: string; keys: string[] }) =>
        `${source.source}${source.keys.length ? `\t${source.keys.map((key) => `@${key}`).join(", ")}` : ""}${source.title ? `\t${source.title}` : ""}`;
      const text = [
        `${queue.pending.length} sources awaiting distillation (${queue.distilled.length} distilled).`,
        ...queue.pending.map(describe),
        ...(all ? ["", "Distilled:", ...queue.distilled.map((source) => `${describe(source)}\t← ${source.notes.join(", ")}`)] : []),
      ].join("\n");
      write(payload, text, mode);
      return;
    }
    case "concepts": {
      const out = path.resolve(root, parsed.flags.get("--out")?.at(-1) ?? "views/concepts.org");
      const index = conceptIndex(settings, files, out);
      const org = renderConceptIndexOrg(index, out);
      const apply = parsed.booleans.has("--apply");
      if (apply) {
        fs.mkdirSync(path.dirname(out), { recursive: true });
        fs.writeFileSync(out, org);
      }
      write({ ...index, out: relative(root, out), applied: apply },
        apply ? `Wrote ${relative(root, out)} (${index.concepts.length} concepts).` : `${org}\nPreview only; pass --apply to write ${relative(root, out)}.`, mode);
      return;
    }
    case "related": {
      const target = files?.[0];
      if (!target) throw new Error("research related requires --file NOTE.org");
      const limit = Number(parsed.flags.get("--limit")?.at(-1) ?? 10);
      if (!Number.isInteger(limit) || limit < 1) throw new Error("--limit must be a positive integer");
      const result = relatedNotes(settings, target, limit);
      write(result, result.related.length
        ? result.related.map((note) => `${note.score}\t${note.file}\t${note.title}${note.sharedTags.length ? `\ttags: ${note.sharedTags.join(", ")}` : ""}${note.sharedSources.length ? `\tsources: ${note.sharedSources.join(", ")}` : ""}${note.linked ? "\tlinked" : ""}`).join("\n")
        : "No related notes.", mode);
      return;
    }
    default:
      throw new Error(`Unknown research action: ${parsed.action}. Run celorga research --help.`);
  }
}
