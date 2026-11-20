import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { execFileSync } from "node:child_process";

execFileSync(process.execPath, ["tools/build-mobile-document.mjs", "--check"], { stdio: "inherit" });
const context = vm.createContext({});
vm.runInContext(readFileSync("apps/ios/Org2Mobile/Org2Mobile/Org2MobileDocument.js", "utf8"), context);
const runtime = context.Org2MobileDocument;
const source = `#+TITLE: Recipes
* Breakfast
We discussed pour over yesterday.
* Pour over
:PROPERTIES:
:ID: coffee-entry
:END:
- *Coffee:* 14 g
- *Water:* 225 g
** Grind
Fine — setting 15.
#+begin_src sh
* Not a heading
#+end_src
* Tea
Steep 3 minutes.
`;
const index = runtime.indexDocument(source, "notes/recipes.org2");
assert.equal(index.length, 5);
const coffee = index.find(e => e.title === "Pour over");
assert.equal(coffee.line, 4);
assert.equal(coffee.nodeID, "coffee-entry");
assert.equal(coffee.parent, "Recipes");
assert.match(coffee.body, /Coffee: 14 g/);
assert.equal(index.find(e => e.title === "Grind").parent, "Recipes › Pour over");
const html = runtime.renderDocument(source, coffee.path, coffee.line, coffee.nodeID).html;
assert.match(html, /225 g/);
assert.match(html, /setting 15/);
assert.doesNotMatch(html, /Steep 3 minutes|discussed pour over yesterday/);
assert.match(runtime.renderDocument(source, coffee.path).html, /Steep 3 minutes/);
assert.match(runtime.renderDocument("\n" + source, coffee.path, coffee.line, coffee.nodeID).html, /225 g/);
assert.throws(() => runtime.renderDocument(source, coffee.path, 2, "", [], "Pour over"), /entry changed/);
// App-profile link tooltips must render without node:path in JavaScriptCore.
const linked = runtime.renderDocument("* Links\nSee [[file:notes/plan.org][plan]], [[file:data/sheet.csv][sheet]], and [[id:coffee-entry][coffee]].\n", "notes/links.org").html;
assert.match(linked, /title="Org document\nfile:notes\/plan\.org"/);
assert.match(linked, /title="CSV file\nfile:data\/sheet\.csv"/);
assert.match(linked, /title="Workspace link\nid:coffee-entry"/);
const unsafe = runtime.renderDocument('#+HTML_HEAD: <script>unsafe()</script>\n* Hello\n#+begin_export html\n<script>unsafe()</script>\n#+end_export', 'test.org').html;
assert.match(unsafe, /script-src 'none'/);
assert.doesNotMatch(unsafe, /<script>unsafe\(\)<\/script>/);
assert.equal(runtime.indexDocument('#+TODO: OPEN | FINISHED\n* OPEN Coffee', 'test.org')[1].title, 'Coffee');
assert.equal(runtime.indexDocument('* READY Coffee', 'test.org', ['READY | FINISHED'])[1].title, 'Coffee');
assert.equal(runtime.indexDocument('* Coffee\n\tIndented text', 'test.org')[1].title, 'Coffee');
console.log('Mobile shared parser/renderer: entry scopes, source blocks, workflow defaults, IDs, stale results, safe HTML passed');

const table = runtime.indexDocument('* Coffee\n| Ingredient | Weight |\n|------------+--------|\n| *Water* | 225 g |', 'table.org');
assert.match(table[1].body, /Water 225 g/);
assert.doesNotMatch(table[1].body, /\*Water\*/);

const internalLinks = runtime.renderDocument("* Start\n[[*Next][Next]] [[#custom][Custom]]\n* Next\n:PROPERTIES:\n:CUSTOM_ID: custom\n:END:", "notes.org");
assert.match(internalLinks.html, /org2-workspace:\/\/open-link\?target=\*Next/);
assert.match(internalLinks.html, /org2-workspace:\/\/open-link\?target=%23custom/);

// A whole presentation reports itself as slides so the phone can ask the host for the deck PDF.
const deck = "#+TITLE: Deck\n#+BEAMER_THEME: metropolis\n#+OPTIONS: H:2\n* Intro\n** First slide\n- Point\n[[file:../images/chart.png]]\n";
assert.equal(runtime.renderDocument(deck, "talks/deck.org").kind, "slides");
assert.equal(runtime.renderDocument(deck, "talks/deck.org", 5).kind, "document");
assert.equal(runtime.renderDocument(source, coffee.path).kind, "document");
assert.match(runtime.renderDocument(deck, "talks/deck.org").html, /<img class="org2-image" src="\.\.\/images\/chart\.png"/);

// Local images resolve against the document's folder for the host to serve.
const pictures = runtime.renderDocument("* Pictures\n[[file:../images/a b.png]]\n[[./local.jpg]]\n[[file:/Users/x/c.png]]\n[[https://example.com/d.png]]\n[[file:../../outside.png]]\n[[file:../images/a b.png]]\n", "notes/talk.org");
assert.deepEqual(JSON.parse(JSON.stringify(pictures.images)).map(image => image.path), ["images/a b.png", "notes/local.jpg", "/Users/x/c.png"]);
for (const image of pictures.images) assert.ok(pictures.html.includes(`src="${image.src}"`));
console.log("Mobile slides kind and image resolution passed");
