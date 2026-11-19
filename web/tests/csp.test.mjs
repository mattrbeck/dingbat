// web/index.html's Content-Security-Policy is the one tools/csp.mjs writes
// for the inline scripts the page has now: a script edited without it would
// be refused by the browser and the page would not start.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { problem, inlineScriptHashes } from "../../tools/csp.mjs";

const html = readFileSync(new URL("../index.html", import.meta.url), "utf8");

test("index.html carries the policy its inline scripts need", () => {
  assert.equal(problem(html), null);
});

test("an edited inline script is caught", () => {
  assert.match(problem(html.replace("<script>", "<script> ")), /run node tools\/csp\.mjs/);
});

test("the page has nothing a policy without 'unsafe-inline' refuses", () => {
  assert.equal(inlineScriptHashes(html).length, 7);
  assert.deepEqual(html.match(/\son[a-z]+="/g), null, "inline event handlers");
  assert.deepEqual(html.match(/\sstyle="/g), null, "inline style attributes");
  assert.deepEqual(html.match(/<style/g), null, "style blocks");
});

// The deploy strips HTML comments from the page: that must not move a hash.
test("the policy survives the deploy's comment strip", () => {
  assert.equal(problem(html.replace(/<!--[\s\S]*?-->/g, "")), null);
});

// Google's redirect page: its own policy, refusing all but its one script
// and one style block.
const callback = readFileSync(new URL("../oauth-callback.html", import.meta.url), "utf8");

test("oauth-callback.html carries the policy its inline code needs", () => {
  assert.equal(problem(callback, "oauth-callback.html"), null);
  assert.match(problem(callback.replace("<style>", "<style> "), "oauth-callback.html"), /run node tools\/csp\.mjs/);
});
