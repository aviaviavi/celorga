#!/usr/bin/env node
// Chart tooltips must work on touch screens, not only with a mouse: a tap or a
// sideways drag inspects the nearest mark, lifting the finger keeps the tooltip
// readable, and tapping elsewhere dismisses it. Runs the shared chart script
// against a minimal DOM stub.
import assert from "node:assert/strict";
import { CHART_INTERACTION_SCRIPT, CHART_INTERACTION_STYLE } from "../dist/chartInteraction.js";

class Node {
  constructor(tag = "div") {
    this.tagName = tag;
    this.children = [];
    this.parent = null;
    this.dataset = {};
    this.attributes = {};
    this.style = {};
    this.listeners = {};
    this.hidden = false;
    this.textContent = "";
    const classes = new Set();
    this.classList = {
      add: (name) => classes.add(name),
      remove: (name) => classes.delete(name),
      toggle: (name, force) => (force ?? !classes.has(name)) ? classes.add(name) : classes.delete(name),
      contains: (name) => classes.has(name),
    };
    this.rect = { left: 0, top: 0, width: 0, height: 0 };
  }
  set className(value) { value.split(/\s+/).forEach((name) => name && this.classList.add(name)); }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  getAttribute(name) { return this.attributes[name] ?? null; }
  append(...nodes) { nodes.forEach((node) => this.appendChild(node)); }
  appendChild(node) { node.parent = this; this.children.push(node); return node; }
  addEventListener(type, handler) { (this.listeners[type] ||= []).push(handler); }
  dispatch(type, event = {}) {
    const full = { target: this, preventDefault() {}, ...event };
    for (let node = full.target; node; node = node.parent) (node.listeners[type] || []).forEach((handler) => handler(full));
  }
  contains(node) { for (let current = node; current; current = current.parent) if (current === this) return true; return false; }
  closest() { return null; }
  getBoundingClientRect() { return this.rect; }
  get offsetWidth() { return 80; }
  get offsetHeight() { return 30; }
  get clientWidth() { return 400; }
  querySelector() { return null; }
  querySelectorAll() { return []; }
}

const documentNode = new Node("document");
const figure = new Node("figure");
figure.dataset.org2ChartInteractive = "true";
figure.rect = { left: 0, top: 0, width: 400, height: 200 };
const svg = new Node("svg");
svg.dataset.org2ChartInteractive = "true";
svg.dataset.org2ChartYLabel = "rps";
figure.appendChild(svg);
documentNode.appendChild(figure);
const marks = ["Mon", "Tue", "Wed"].map((label, index) => {
  const mark = new Node("circle");
  mark.dataset.label = label;
  mark.dataset.value = String(10 + index);
  mark.dataset.chartX = String(100 + index * 100);
  mark.rect = { left: 95 + index * 100, top: 95, width: 10, height: 10 };
  svg.appendChild(mark);
  return mark;
});
svg.querySelectorAll = (selector) => selector.includes("data-org2-chart-mark") ? marks : [];
documentNode.querySelectorAll = () => [figure];
documentNode.createElement = (tag) => new Node(tag);
documentNode.readyState = "complete";
documentNode.activeElement = null;
figure.querySelector = (selector) => selector === "svg.org2-chart-svg" ? svg : null;

globalThis.document = documentNode;
globalThis.window = globalThis;
new Function(CHART_INTERACTION_SCRIPT)();

const tooltip = figure.children.find((node) => node.classList.contains("org2-chart-tooltip"));
assert.ok(tooltip, "the chart gets a tooltip");
assert.equal(tooltip.hidden, true);

// A tap near the second point shows its tooltip.
figure.dispatch("pointerdown", { pointerType: "touch", clientX: 205, clientY: 120 });
assert.equal(tooltip.hidden, false, "a tap shows the tooltip");
assert.ok(marks[1].classList.contains("org2-chart-mark-active"));
assert.equal(tooltip.children[0].textContent, "Tue");

// Dragging sideways scrubs to the next point.
figure.dispatch("pointermove", { pointerType: "touch", clientX: 300, clientY: 120 });
assert.ok(marks[2].classList.contains("org2-chart-mark-active"), "a drag scrubs between points");

// Lifting the finger fires pointerleave on touch; the tooltip stays readable.
figure.dispatch("pointerleave", { pointerType: "touch" });
assert.equal(tooltip.hidden, false, "lifting a finger keeps the tooltip up");

// Tapping outside the chart dismisses it.
const outside = new Node("p");
documentNode.appendChild(outside);
outside.dispatch("pointerdown", { pointerType: "touch" });
assert.equal(tooltip.hidden, true, "tapping elsewhere hides the tooltip");

// A mouse still hides the tooltip when it leaves the chart.
figure.dispatch("pointermove", { pointerType: "mouse", clientX: 100, clientY: 100 });
assert.equal(tooltip.hidden, false);
figure.dispatch("pointerleave", { pointerType: "mouse" });
assert.equal(tooltip.hidden, true, "a mouse leaving hides the tooltip");

// Vertical swipes keep scrolling the page; horizontal drags reach the chart.
assert.match(CHART_INTERACTION_STYLE, /touch-action: pan-y/);

console.log("✓ chart touch interaction");
