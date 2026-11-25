import assert from "node:assert/strict";
import { renderAppHTML, renderCodeFileAppHTML } from "../dist/appHtmlRenderer.js";
import { parseOrgToCanonicalAst } from "../dist/parser.js";
import { renderOrgDocumentToHtml } from "../dist/export.js";

const decodeSrcdoc = (html) => {
  const encoded = /srcdoc="([^"]*)"/.exec(html)?.[1] || "";
  return encoded.replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
};

const snippet = '<style>body{background:rgb(255,0,128)}</style><div id="out">Notes → preview</div><script>document.getElementById("out").textContent = String(6 * 7)</script>';
for (const [open, close] of [["#+begin_src html", "#+end_src"], ["```html", "```"]]) {
  const text = `${open}\n${snippet}\n${close}\n`;
  const html = renderAppHTML(text, { sourcePath: "/tmp/chat-message.org" });
  assert.match(html, /class="org2-html-preview"/);
  // Scripts run, but only in an opaque origin: never same-origin, never top navigation.
  const sandbox = /<iframe title="HTML preview" sandbox="([^"]*)"/.exec(html)?.[1];
  assert.equal(sandbox, "allow-scripts allow-forms allow-popups");
  assert.doesNotMatch(sandbox, /allow-same-origin|allow-top-navigation/);
  assert.match(/<iframe title="HTML preview"[^>]*>/.exec(html)?.[0] || "", /data-org2-autosize="true"/);
  assert.match(html, /srcdoc="&lt;!doctype html&gt;/);
  const frame = decodeSrcdoc(html);
  const policy = /Content-Security-Policy" content="([^"]*)"/.exec(frame)?.[1] || "";
  assert.match(policy, /script-src 'unsafe-inline' 'unsafe-eval' https: blob:/);
  assert.match(policy, /connect-src https:/);
  assert.match(policy, /form-action 'none'/);
  assert.match(policy, /frame-src 'none'/);
  assert.match(policy, /base-uri 'none'/);
  assert.ok(frame.includes(snippet), "the snippet, including its script, reaches the frame unchanged");
  assert.match(frame, /org2-frame-size/, "auto-sized frames report their content height");
  assert.match(html, /<summary>HTML source<\/summary>/);
  assert.doesNotMatch(html, /<script>document.getElementById/, "the snippet never runs in the host document");
  assert.doesNotMatch(html, /<style>body\{background/);
  const exported = renderOrgDocumentToHtml(parseOrgToCanonicalAst(text)).html;
  assert.doesNotMatch(exported, /<figure class="org2-html-preview"/, "ordinary exports retain source semantics");
}

const previewFrame = (html) => /<iframe title="HTML preview"[^>]*>/.exec(html)?.[0] || "";
const fixed = previewFrame(renderAppHTML("#+begin_src html :height 240\n<canvas></canvas>\n#+end_src\n", { sourcePath: "/tmp/chat.org" }));
assert.match(fixed, /height:240px/);
assert.doesNotMatch(fixed, /data-org2-autosize/);
assert.doesNotMatch(decodeSrcdoc(fixed), /org2-frame-size/);
assert.match(previewFrame(renderAppHTML("#+begin_src html :height 99999\n<p>x</p>\n#+end_src\n", { sourcePath: "/tmp/chat.org" })), /height:1600px/);

assert.doesNotMatch(renderCodeFileAppHTML(snippet, "html", {sourcePath:"/tmp/example.html"}), /<figure class="org2-html-preview"/);
assert.doesNotMatch(renderAppHTML("#+begin_src html\n<div>partial", {sourcePath:"/tmp/chat.org"}), /<figure class="org2-html-preview"/, "streaming blocks wait for their closing delimiter");
console.log("✓ chat HTML previews");

// Choices blocks: an AI reply offers answers the reader can click.
{
  const { parseChoicesBlock } = await import("../dist/export.js");
  assert.deepEqual(
    parseChoicesBlock("Ship it today?\n- Yes\n- No\n- [ ] Later\n- Yes\n", ""),
    { prompt: "Ship it today?", options: ["Yes", "No", "Later"], multiple: false },
  );
  assert.equal(parseChoicesBlock("- a\n", ":multiple").multiple, true);
  assert.equal(parseChoicesBlock("- a\n", ":multiple yes").multiple, true);
  assert.equal(parseChoicesBlock("- a\n", ":multiple no").multiple, false);

  const single = renderAppHTML("#+begin_src choices\nShip it?\n- Yes\n- No & wait\n#+end_src\n", { sourcePath: "/tmp/chat.org" });
  assert.match(single, /<figure class="org2-choices" data-org2-choice-mode="single" role="group"/);
  assert.match(single, /<figcaption>Ship it\?<\/figcaption>/);
  assert.match(single, /<button type="button" class="org2-choice" data-org2-choice="No &amp; wait">No &amp; wait<\/button>/);
  assert.doesNotMatch(single, /data-org2-choice-submit/);
  assert.doesNotMatch(single, /<pre class="org2-src/, "the block renders as choices, not code");

  const multiple = renderAppHTML("#+begin_src choices :multiple\n- Summary\n- Risks\n#+end_src\n", { sourcePath: "/tmp/chat.org" });
  assert.match(multiple, /data-org2-choice-mode="multiple"/);
  assert.match(multiple, /aria-pressed="false"/);
  assert.match(multiple, /data-org2-choice-submit disabled>Send</);

  assert.doesNotMatch(renderAppHTML("#+begin_src choices\n- Yes\n- N", { sourcePath: "/tmp/chat.org" }), /org2-choices"/, "streaming blocks wait for their closing delimiter");
  assert.match(renderAppHTML("#+begin_src choices\nNo options here\n#+end_src\n", { sourcePath: "/tmp/chat.org" }), /<pre class="org2-src/, "a block without options stays code");

  const exported = renderOrgDocumentToHtml(parseOrgToCanonicalAst("#+begin_src choices\nShip it?\n- Yes\n- No\n#+end_src\n")).html;
  assert.match(exported, /<figure class="org2-choices"[^>]*><figcaption>Ship it\?<\/figcaption><ul><li>Yes<\/li><li>No<\/li><\/ul><\/figure>/);
  assert.doesNotMatch(exported, /<button/, "published HTML has nothing to answer, so it lists the options");
  console.log("✓ chat choices blocks");
}
