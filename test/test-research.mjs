#!/usr/bin/env node
// Research notes: org-ref citation links, BibTeX resolution, quote checks
// against cited sources, the distillation queue, the concept index, and related
// notes.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { parseInlinesFromText } from "../dist/parser.js";
import { citationFromLinkTarget } from "../dist/citationSyntax.js";
import { parseBibtex, quoteAppearsInSource, describeBibEntry } from "../dist/research.js";
import { renderAppHTML } from "../dist/appHtmlRenderer.js";

const repo = process.cwd();
const root = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-research-"));
const corpus = path.join(root, "corpus");

function write(relative, content, base = corpus) {
  const file = path.join(base, relative);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, content);
  return file;
}
function cli(args, options = {}) {
  const child = spawnSync("node", ["dist/cli.js", ...args], { cwd: options.cwd ?? repo, encoding: "utf8", maxBuffer: 8 * 1024 * 1024 });
  if (!options.allowFailure && child.status !== 0) throw new Error(`celorga ${args.join(" ")} failed (${child.status}):\n${child.stdout}\n${child.stderr}`);
  return child;
}
const json = (args, options) => JSON.parse(cli([...args, "--format", "json"], options).stdout);

// Syntax: bare org-ref links are plain links; brackets stay bracket links.
{
  const nodes = parseInlinesFromText("As citep:doe2024,roe2025 showed (citet:&roe2025). Not excite:x or cite: none.");
  const links = nodes.filter((node) => node.type === "Link");
  assert.deepEqual(links.map((link) => link.raw), ["citep:doe2024,roe2025", "citet:&roe2025"]);
  assert.deepEqual(citationFromLinkTarget("citep:doe2024,roe2025").references.map((r) => r.key), ["doe2024", "roe2025"]);
  assert.deepEqual(citationFromLinkTarget("cite:See &doe2024 p. 3;&roe2025"), {
    syntax: "org-ref", style: "cite",
    references: [{ key: "doe2024", prefix: "See", suffix: "p. 3" }, { key: "roe2025" }],
  });
  assert.equal(citationFromLinkTarget("parencite:doe2024").references[0].key, "doe2024");
  assert.equal(citationFromLinkTarget("file:notes.org"), null);
  assert.equal(citationFromLinkTarget("https://example.com"), null);
}

// BibTeX: braces, quotes, @string macros, # joins, and JabRef file fields.
{
  const entries = parseBibtex(`
@string{jn = "Journal of Tests"}
@comment{ignored}
@article{doe2024,
  author = {Doe, Jane and Roe, Rick},
  title = {Measuring {CO} Oxidation},
  journal = jn # " Letters",
  year = 2024,
  file = {:sources/doe2024.pdf:PDF}
}
@misc(roe2025, title = "Quoted, with comma", author = "Rick Roe and Ann Poe and Sam Low")
`, "/tmp/refs.bib");
  assert.deepEqual(entries.map((entry) => entry.key), ["doe2024", "roe2025"]);
  assert.equal(entries[0].fields.journal, "Journal of Tests Letters");
  assert.equal(entries[0].fields.title, "Measuring {CO} Oxidation");
  assert.equal(entries[0].line, 4);
  assert.equal(describeBibEntry(entries[0]), "Doe and Roe (2024). Measuring CO Oxidation.");
  assert.equal(describeBibEntry(entries[1]), "Roe et al. Quoted, with comma.");
}

// Quote matching ignores case, punctuation, line breaks, and markup, and
// accepts ellipses and bracketed insertions.
{
  const source = "The rate was linear across the range.\nIt suggests a single, rate-limiting step!";
  assert.ok(quoteAppearsInSource("the rate was LINEAR across the range", source));
  assert.ok(quoteAppearsInSource("The rate was linear ... a single rate-limiting step", source));
  assert.ok(quoteAppearsInSource("It suggests [only] a single, rate-limiting step", source));
  assert.ok(!quoteAppearsInSource("The rate was exponential across the range", source));
  assert.ok(!quoteAppearsInSource("a single rate-limiting step ... The rate was linear", source), "parts must appear in order");
  // A truncating ellipsis may cut a word.
  assert.ok(quoteAppearsInSource("The rate was linear across the ra...", source));
  assert.ok(quoteAppearsInSource("...ggests a single", source));
  assert.ok(!quoteAppearsInSource("The rate was linear across the ro...", source));
  // A bracketed letter alters part of a word (#595).
  const seasons = "When the earth turns seasons change over time and the oceans move.";
  assert.ok(quoteAppearsInSource("[W]hen the earth turns seasons change over time and the oceans move", seasons));
  assert.ok(quoteAppearsInSource("the earth turn[s] seasons change", seasons));
  assert.ok(!quoteAppearsInSource("[W]hen the earth turns seasons change over time and the rivers move", seasons));
  assert.ok(!quoteAppearsInSource("[W]hen the moon turns seasons change", seasons));
}

// A small research corpus.
write("celorga.json", JSON.stringify({ corpus: { id: "research-test", name: "Research test", kind: "personal" } }));
write("references.bib", `@article{doe2024,
  author = {Doe, Jane},
  title = {Platinum Kinetics},
  year = {2024},
  file = {sources/papers/doe2024.pdf}
}
@book{roe2025,
  author = {Roe, Rick},
  title = {Rates},
  year = {2025}
}
@misc{poe2026,
  author = {Poe, Ann},
  title = {Unread Preprint},
  year = {2026}
}
@misc{low2023,
  title = {Lab notebook},
  file = {sources/notebooks/run-12.org}
}
`);
write("sources/papers/doe2024.pdf", "%PDF-1.4 binary");
write("sources/papers/doe2024.txt", "Abstract. The activation energy on Pt(111) was 1.05 eV,\nconsistent with prior DFT calculations of the barrier.\n");
write("sources/papers/smith2022.pdf", "%PDF-1.4 binary");
write("sources/notebooks/run-12.org", "#+TITLE: Run 12\n\nThe Arrhenius plot was linear from 300 K to 600 K.\n");
write("sources/web/blog.html", "<html><body><p>Catalysts &amp; surfaces matter a great deal here.</p></body></html>");
write("raw/meeting.org", "#+TITLE: Meeting\n\nWe agreed to measure the barrier again next month.\n");
const summary = write("wiki/summaries/doe2024.org", `#+TITLE: Doe 2024 summary
#+FILETAGS: :summary:catalysis:platinum:

* Findings
The paper reports "the activation energy on Pt(111) was 1.05 eV" citep:doe2024.
It also claims "the barrier was measured at room temperature only" [cite:@doe2024].
A book says "kinetics is the study of reaction rates over time" citet:roe2025.
Missing key: cite:nobody2020.

#+begin_quote
The Arrhenius plot was linear from 300 K to 600 K.
#+end_quote
-- [[file:../../sources/notebooks/run-12.org::3][Run 12, line 3]]

The log reads "The Arrhenius plot was linear from 300 K" ([[file:../../sources/notebooks/run-12.org::1][run 12]]).

She said "the plot looked completely flat this morning" before lunch, and for an unrelated claim see [[file:../../sources/notebooks/run-12.org][run 12]].
`);
write("wiki/concepts/activation-energy.org", `#+TITLE: Activation Energy
#+FILETAGS: :concept:catalysis:kinetics:
:PROPERTIES:
:ID: 0b8e1f3a-1111-4111-8111-111111111111
:END:

Measured on platinum citep:doe2024. See [[file:../summaries/doe2024.org][the summary]].
`);
write("wiki/comparisons/rates.org", `#+TITLE: Rates compared
#+FILETAGS: :comparison:kinetics:
:PROPERTIES:
:SOURCE_KEYS: roe2025 blog
:END:

Short note.
`);
write("notes/untagged.org", "#+TITLE: Untagged\n\nNothing cited here.\n");

// citations and check
{
  const report = json(["research", "citations", "--dir", corpus]);
  assert.deepEqual(report.bibliography, [path.join(corpus, "references.bib")]);
  const byKey = new Map(report.citations.flatMap((citation) => citation.keys.map((key) => [key, citation])));
  assert.equal(byKey.get("doe2024").file, summary);
  assert.equal(byKey.get("nobody2020").line, 8);
  assert.deepEqual(byKey.get("nobody2020").unresolvedKeys, ["nobody2020"]);
  const quotes = new Map(report.quotes.map((quote) => [quote.text, quote]));
  assert.equal(quotes.get("the activation energy on Pt(111) was 1.05 eV").status, "verified");
  assert.deepEqual(quotes.get("the activation energy on Pt(111) was 1.05 eV").checkedSources, ["sources/papers/doe2024.txt"]);
  assert.equal(quotes.get("the barrier was measured at room temperature only").status, "mismatch");
  assert.equal(quotes.get("kinetics is the study of reaction rates over time").status, "unverifiable");
  const block = quotes.get("The Arrhenius plot was linear from 300 K to 600 K.");
  assert.equal(block.kind, "block");
  assert.equal(block.status, "verified");
  assert.deepEqual(block.checkedSources, ["sources/notebooks/run-12.org::3"]);
  // A cited line range that no longer holds the quote names the line that does.
  const moved = quotes.get("The Arrhenius plot was linear from 300 K");
  assert.equal(moved.status, "mismatch");
  assert.equal(moved.message, "Quoted text not found in sources/notebooks/run-12.org::1; it is at sources/notebooks/run-12.org:3");
  // A link several words after a quote supports something else.
  assert.equal(quotes.has("the plot looked completely flat this morning"), false);

  const check = cli(["research", "check", "--dir", corpus], { allowFailure: true });
  assert.equal(check.status, 1);
  assert.match(check.stdout, /wiki\/summaries\/doe2024\.org:8: unresolved citation @nobody2020/);
  assert.match(check.stdout, /wiki\/summaries\/doe2024\.org:6: Quoted text not found in sources\/papers\/doe2024\.txt/);
  assert.match(check.stdout, /not checked: No readable source: @roe2025 \(no file field\)/);

  const lint = JSON.parse(cli(["lint", "--dir", corpus, "--recursive", "--format", "json"]).stdout);
  const rules = lint.issues.filter((issue) => issue.file === summary).map((issue) => `${issue.rule}:${issue.line}`).sort();
  assert.deepEqual(rules, ["quote-not-in-source:15", "quote-not-in-source:6", "unresolved-citation:8"]);
}

// A :SOURCE_KEYS: property is a citation: listed, resolved, and checked (#596).
{
  const rates = path.join(corpus, "wiki/comparisons/rates.org");
  const listed = json(["research", "citations", "--dir", corpus, "--file", rates]).citations;
  assert.deepEqual(listed.map(({ line, syntax, style, keys, unresolvedKeys }) => ({ line, syntax, style, keys, unresolvedKeys })), [
    // "blog" names sources/web/blog.html, as in the queue.
    { line: 4, syntax: "property", style: "SOURCE_KEYS", keys: ["roe2025", "blog"], unresolvedKeys: [] },
  ]);
  const only = write("wiki/property-only.org", "#+TITLE: Property only\n* Property only\n:PROPERTIES:\n:SOURCE_KEYS: missing-source doe2024\n:END:\n\nSynthetic note.\n");
  const check = cli(["research", "check", "--dir", corpus, "--file", only], { allowFailure: true });
  assert.equal(check.status, 1);
  assert.match(check.stdout, /wiki\/property-only\.org:4: unresolved citation @missing-source\n/);
  assert.match(check.stdout, /1 citations, 1 unresolved keys/);
  const lint = JSON.parse(cli(["lint", "--dir", corpus, "--recursive", "--format", "json"]).stdout);
  assert.deepEqual(lint.issues.filter((issue) => issue.file === only).map((issue) => `${issue.rule}:${issue.line}:${issue.message}`),
    ["unresolved-citation:4:Citation key 'missing-source' is not in references.bib."]);
  assert.ok(!lint.issues.some((issue) => issue.file === rates), "a source file name in :SOURCE_KEYS: resolves");
  fs.rmSync(only);
}

// Rendering: resolved keys carry the entry and link to the source; unknown keys are marked.
{
  const html = renderAppHTML(fs.readFileSync(summary, "utf8"), { sourcePath: summary, corpusRoot: corpus });
  assert.match(html, /<a class="org2-citation-key" data-org2-citation-key="doe2024" href="org2-workspace:\/\/open-link\?target=file%3A[^"]+doe2024\.pdf" title="Doe \(2024\)\. Platinum Kinetics\.">@doe2024<\/a>/);
  assert.match(html, /<span class="org2-citation-key" data-org2-citation-key="roe2025" title="Roe \(2025\)\. Rates\.">@roe2025<\/span>/);
  assert.match(html, /org2-citation-unresolved" data-org2-citation-key="nobody2020"/);
  assert.match(html, /data-org2-citation-style="citep"/);
  assert.doesNotMatch(html, /href="citep:/);
  // Without a bibliography, citations still render as citations, not links.
  const bare = renderAppHTML("Text citep:doe2024 and [[citet:roe2025][Roe]].\n", { sourcePath: path.join(root, "loose.org") });
  assert.match(bare, /<cite class="org2-citation" data-org2-citation-style="citep">@doe2024<\/cite>/);
  assert.match(bare, /<cite class="org2-citation" data-org2-citation-style="citet" title="roe2025">Roe<\/cite>/);
  // Export to HTML resolves too, with a tooltip and no app link.
  const out = path.join(root, "summary.html");
  cli(["export", "html", "--file", summary, "--out", out, "--apply"]);
  assert.match(fs.readFileSync(out, "utf8"), /<span class="org2-citation-key" data-org2-citation-key="doe2024" title="Doe \(2024\)\. Platinum Kinetics\.">@doe2024<\/span>/);
}

// Document-local #+BIBLIOGRAPHY: takes part, relative to the note.
{
  write("drafts/refs/local.bib", "@misc{local2026, title = {Local Only}, year = {2026}}\n");
  write("drafts/draft.org", "#+BIBLIOGRAPHY: refs/local.bib\n\nSee [cite:@local2026] and citep:doe2024.\n");
  const report = json(["research", "citations", "--dir", corpus, "--file", path.join(corpus, "drafts/draft.org")]);
  assert.deepEqual(report.citations[0].unresolvedKeys, []);
  assert.deepEqual(report.citations[1].unresolvedKeys, []);
  fs.rmSync(path.join(corpus, "drafts"), { recursive: true });
}

// The distillation queue: sources no note cites, links, or names.
{
  const queue = json(["research", "queue", "--dir", corpus, "--all"]);
  const pending = queue.pending.map((source) => source.source).sort();
  assert.deepEqual(pending, ["poe2026", "raw/meeting.org", "sources/papers/smith2022.pdf"]);
  const distilled = new Map(queue.distilled.map((source) => [source.source, source]));
  // A PDF and its text export are one source.
  assert.deepEqual(distilled.get("sources/papers/doe2024.pdf").files.sort(), ["sources/papers/doe2024.pdf", "sources/papers/doe2024.txt"]);
  assert.deepEqual(distilled.get("sources/papers/doe2024.pdf").keys, ["doe2024"]);
  assert.ok(distilled.get("sources/notebooks/run-12.org").notes.includes("wiki/summaries/doe2024.org"), "a file: link distills a source");
  assert.deepEqual(distilled.get("sources/web/blog.html").notes, ["wiki/comparisons/rates.org"], ":SOURCE_KEYS: names a source by basename");
  assert.deepEqual(distilled.get("roe2025").notes, ["wiki/comparisons/rates.org", "wiki/summaries/doe2024.org"]);
  const text = cli(["research", "queue", "--dir", corpus]).stdout;
  assert.match(text, /^3 sources awaiting distillation \(4 distilled\)\./);
}

// Concepts preview, then write views/concepts.org; related notes.
{
  const preview = cli(["research", "concepts", "--dir", corpus]).stdout;
  assert.match(preview, /^#\+TITLE: Concepts/);
  assert.match(preview, /Preview only; pass --apply to write views\/concepts\.org\./);
  assert.ok(!fs.existsSync(path.join(corpus, "views/concepts.org")));
  const applied = json(["research", "concepts", "--dir", corpus, "--apply"]);
  assert.equal(applied.applied, true);
  const index = fs.readFileSync(path.join(corpus, "views/concepts.org"), "utf8");
  assert.match(index, /^\* catalysis \(2\)\nRelated: =concept= \(1\), =kinetics= \(1\), =platinum= \(1\), =summary= \(1\)\n\n- \[\[id:0b8e1f3a-1111-4111-8111-111111111111\]\[Activation Energy\]\]\n- \[\[file:\.\.\/wiki\/summaries\/doe2024\.org\]\[Doe 2024 summary\]\]$/m);
  assert.match(index, /^\* kinetics \(2\)$/m);
  assert.equal(applied.untagged, 1);
  // The generated index is not itself indexed on the next run.
  const again = json(["research", "concepts", "--dir", corpus]);
  assert.equal(again.untagged, 1);

  const related = json(["research", "related", "--dir", corpus, "--file", path.join(corpus, "wiki/concepts/activation-energy.org")]);
  assert.deepEqual(related.related.map((note) => [note.file, note.score, note.linked]), [
    ["wiki/summaries/doe2024.org", 6, true],
    ["wiki/comparisons/rates.org", 1, false],
  ]);
}

// A file field whose path does not exist is reported as a missing file, not a missing field (#597).
{
  const missing = path.join(root, "missing-file");
  write("references.bib", "@misc{source, title = {Synthetic source}, file = {sources/source.txt}}\n", missing);
  write("wiki/note.org", "#+TITLE: Synthetic\n\n\"This fabricated quotation is absent from the source document\" citep:source\n", missing);
  const check = cli(["research", "check", "--dir", missing], { allowFailure: true });
  assert.equal(check.status, 0, check.stdout + check.stderr);
  assert.match(check.stdout, /not checked: No readable source: @source \(file not found: sources\/source\.txt\)/);
  assert.doesNotMatch(check.stdout, /no file field/);
}

fs.rmSync(root, { recursive: true, force: true });
console.log("research notes: citations, quotes, queue, concepts, related passed");
