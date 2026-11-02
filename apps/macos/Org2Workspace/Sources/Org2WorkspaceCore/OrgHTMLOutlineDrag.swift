import Foundation

/// Drag handles for headings and list items in the rendered document.
///
/// Hovering a heading or list item shows a grip at its left. Dragging the
/// grip moves the entry (with its subtree or nested items); a line shows
/// where it will land. Dragging right nests it one level deeper, dragging
/// left lifts it out, so the same gesture reorders, indents and outdents.
/// The page only proposes the move; the app rewrites the source and
/// re-renders.
enum OrgHTMLOutlineDrag {
  static let messageHandlerName = "org2OutlineMove"

  /// Pointer travel, in CSS pixels, that changes the level by one.
  static let indentStep = 26

  static var installationScript: String {
    #"""
    (() => {
      if (window.__org2OutlineDragInstalled) return;
      window.__org2OutlineDragInstalled = true;

      const INDENT_STEP = \#(indentStep);
      const DRAG_THRESHOLD = 4;
      const EDGE = 56;
      let enabled = false;
      let subtreeScope = false;
      let pending = null;
      let drag = null;
      let hovered = null;
      let lastMove = null;

      const style = document.createElement('style');
      style.id = 'org2-outline-drag-style';
      style.textContent = `
        html.org2-outline-drag li[data-org2-start-line] { position: relative; }
        .org2-drag-grip {
          position: absolute;
          display: none;
          align-items: center;
          justify-content: center;
          width: 16px;
          height: 22px;
          border-radius: 4px;
          color: var(--org2-muted, #8a8a8a);
          cursor: grab;
          opacity: 0;
          transition: opacity 90ms ease-out, background-color 90ms ease-out, color 90ms ease-out;
          z-index: 2;
          touch-action: none;
          -webkit-user-select: none;
          user-select: none;
        }
        html.org2-outline-drag .org2-drag-grip { display: inline-flex; }
        .org2-drag-grip svg { width: 10px; height: 14px; fill: currentColor; pointer-events: none; }
        .org2-headline-summary > .org2-drag-grip { left: -20px; top: 0.12em; }
        li[data-org2-start-line] > .org2-drag-grip { left: calc(-1.35em - 18px); top: 0.05em; }
        ol > li[data-org2-start-line] > .org2-drag-grip { left: calc(-1.9em - 18px); }
        .org2-drag-hover > .org2-drag-grip,
        .org2-drag-grip:focus-visible { opacity: 1; }
        .org2-drag-grip:hover {
          color: var(--org2-text, inherit);
          background: color-mix(in srgb, var(--org2-muted, #8a8a8a) 16%, transparent);
        }
        html.org2-outline-dragging, html.org2-outline-dragging * { cursor: grabbing !important; }
        html.org2-outline-dragging body { -webkit-user-select: none; user-select: none; }
        html.org2-outline-dragging .org2-drag-grip { opacity: 0 !important; }
        .org2-drag-source { opacity: 0.35; transition: opacity 120ms ease-out; }
        .org2-drag-pending { opacity: 0.6; }
        .org2-drag-indicator {
          position: fixed;
          height: 2px;
          border-radius: 1px;
          background: var(--org2-accent, #2f6fde);
          pointer-events: none;
          z-index: 1000;
          transition: left 70ms ease-out, width 70ms ease-out, top 40ms linear;
        }
        .org2-drag-indicator::before {
          content: "";
          position: absolute;
          left: -4px;
          top: -3px;
          width: 8px;
          height: 8px;
          border-radius: 50%;
          box-sizing: border-box;
          border: 2px solid var(--org2-accent, #2f6fde);
          background: var(--org2-surface, #fff);
        }
        .org2-drag-indicator-label {
          position: absolute;
          right: 0;
          top: -9px;
          padding: 1px 7px;
          border-radius: 999px;
          background: var(--org2-accent, #2f6fde);
          color: #fff;
          font: 600 11px/16px -apple-system, BlinkMacSystemFont, sans-serif;
          white-space: nowrap;
          max-width: 320px;
          overflow: hidden;
          text-overflow: ellipsis;
        }
        .org2-drag-indicator-label:empty { display: none; }
        .org2-drag-ghost {
          position: fixed;
          z-index: 1001;
          max-width: 340px;
          padding: 4px 10px;
          border-radius: 7px;
          background: var(--org2-elevated-surface, var(--org2-surface, #fff));
          color: var(--org2-text, #222);
          border: 1px solid var(--org2-rule, rgba(127,127,127,0.3));
          box-shadow: 0 6px 18px rgba(0,0,0,0.16);
          font: 500 13px/18px -apple-system, BlinkMacSystemFont, sans-serif;
          white-space: nowrap;
          overflow: hidden;
          text-overflow: ellipsis;
          pointer-events: none;
          opacity: 0.95;
        }
      `;
      (document.head || document.documentElement).appendChild(style);

      const gripMarkup = '<svg viewBox="0 0 10 14" aria-hidden="true">'
        + '<circle cx="2.5" cy="2.5" r="1.3"/><circle cx="7.5" cy="2.5" r="1.3"/>'
        + '<circle cx="2.5" cy="7" r="1.3"/><circle cx="7.5" cy="7" r="1.3"/>'
        + '<circle cx="2.5" cy="11.5" r="1.3"/><circle cx="7.5" cy="11.5" r="1.3"/></svg>';

      const lineOf = (el, name) => Number(el?.dataset?.[name] || 0);
      const startOf = (el) => lineOf(el, 'org2StartLine');
      const endOf = (el) => lineOf(el, 'org2EndLine') || startOf(el);
      const headingLevel = (el) => {
        const match = /(?:^|\s)level-(\d+)(?:\s|$)/.exec(el.className || '');
        return match ? Number(match[1]) : 1;
      };
      const isHeading = (el) => el?.matches?.('details.org2-headline[data-org2-start-line]');
      const parentHeading = (el) => el.parentElement?.closest('details.org2-headline[data-org2-start-line]') || null;
      const isRootHeading = (el) => !parentHeading(el);
      const isListItem = (el) => el?.matches?.('li[data-org2-start-line]')
        && /^(UL|OL)$/.test(el.parentElement?.tagName || '');
      const visible = (el) => el.getClientRects().length > 0;
      const clip = (text) => {
        const value = String(text || '').replace(/\s+/g, ' ').trim();
        return value.length > 60 ? value.slice(0, 59) + '…' : value;
      };
      const headingTitle = (el) => {
        const heading = el.querySelector(':scope > summary > h1, :scope > summary > h2, :scope > summary > h3, :scope > summary > h4, :scope > summary > h5, :scope > summary > h6');
        return clip(heading?.textContent);
      };
      const itemTitle = (el) => {
        const paragraph = el.querySelector(':scope > p');
        if (paragraph) return clip(paragraph.textContent);
        let text = '';
        for (const node of el.childNodes) {
          if (node.nodeType === Node.TEXT_NODE) text += node.textContent;
          else if (node.nodeType === Node.ELEMENT_NODE && !/^(UL|OL|DL|SPAN)$/.test(node.tagName)) text += node.textContent;
        }
        return clip(text);
      };

      const draggableHeading = (el) => isHeading(el) && !(subtreeScope && isRootHeading(el));

      const installGrips = () => {
        for (const details of document.querySelectorAll('details.org2-headline[data-org2-start-line]')) {
          const summary = details.querySelector(':scope > summary');
          if (!summary || summary.querySelector(':scope > .org2-drag-grip')) continue;
          if (!draggableHeading(details)) continue;
          summary.appendChild(makeGrip('Drag to move or nest this heading'));
        }
        for (const item of document.querySelectorAll('li[data-org2-start-line]')) {
          if (!isListItem(item) || item.querySelector(':scope > .org2-drag-grip')) continue;
          item.insertBefore(makeGrip('Drag to move or nest this item'), item.firstChild);
        }
      };

      const makeGrip = (title) => {
        const grip = document.createElement('span');
        grip.className = 'org2-drag-grip';
        grip.title = title;
        grip.setAttribute('aria-hidden', 'true');
        grip.innerHTML = gripMarkup;
        return grip;
      };

      const entryForGrip = (grip) => {
        const item = grip.parentElement;
        if (isListItem(item)) return item;
        const details = item?.parentElement;
        return draggableHeading(details) ? details : null;
      };

      // Only the innermost hovered entry shows its grip.
      document.addEventListener('pointermove', (event) => {
        if (!enabled || drag) return;
        const target = event.target instanceof Element ? event.target : null;
        let next = null;
        const item = target?.closest('li[data-org2-start-line], summary.org2-headline-summary');
        if (item?.matches('summary')) {
          if (draggableHeading(item.parentElement)) next = item;
        } else if (item && isListItem(item)) {
          next = item;
        }
        if (next === hovered) return;
        hovered?.classList.remove('org2-drag-hover');
        hovered = next;
        hovered?.classList.add('org2-drag-hover');
      }, { passive: true });
      document.addEventListener('pointerleave', () => {
        hovered?.classList.remove('org2-drag-hover');
        hovered = null;
      });

      // A grip sits inside the heading summary; keep its clicks from folding.
      document.addEventListener('click', (event) => {
        const target = event.target instanceof Element ? event.target : null;
        if (target?.closest('.org2-drag-grip')) {
          event.preventDefault();
          event.stopPropagation();
        }
      }, true);

      document.addEventListener('pointerdown', (event) => {
        if (!enabled || drag || event.button !== 0) return;
        const target = event.target instanceof Element ? event.target : null;
        const grip = target?.closest('.org2-drag-grip');
        if (!grip) return;
        const entry = entryForGrip(grip);
        if (!entry) return;
        try { grip.setPointerCapture(event.pointerId); } catch (_) {}
        pending = { grip, entry, pointerId: event.pointerId, x: event.clientX, y: event.clientY };
      }, true);

      document.addEventListener('pointermove', (event) => {
        if (pending && !drag && event.pointerId === pending.pointerId) {
          if (Math.hypot(event.clientX - pending.x, event.clientY - pending.y) < DRAG_THRESHOLD) return;
          beginDrag(pending, event);
        }
        if (!drag || event.pointerId !== drag.pointerId) return;
        event.preventDefault();
        lastMove = { x: event.clientX, y: event.clientY };
        update();
      }, true);

      document.addEventListener('pointerup', (event) => {
        if (pending && event.pointerId === pending.pointerId && !drag) {
          pending = null;
          return;
        }
        if (!drag || event.pointerId !== drag.pointerId) return;
        event.preventDefault();
        event.stopPropagation();
        finishDrag(true);
      }, true);

      document.addEventListener('pointercancel', (event) => {
        if (pending && event.pointerId === pending.pointerId) pending = null;
        if (drag && event.pointerId === drag.pointerId) finishDrag(false);
      }, true);

      document.addEventListener('keydown', (event) => {
        if (drag && event.key === 'Escape') {
          event.preventDefault();
          finishDrag(false);
        }
      }, true);

      window.addEventListener('blur', () => { if (drag) finishDrag(false); });

      const pageTop = (el) => el.getBoundingClientRect().top + window.scrollY;
      const pageBottom = (el) => el.getBoundingClientRect().bottom + window.scrollY;
      const leftOf = (el) => el.getBoundingClientRect().left;

      const headingModel = (entry) => {
        const all = [...document.querySelectorAll('details.org2-headline[data-org2-start-line]')].map((el) => ({
          el,
          start: startOf(el),
          end: endOf(el),
          level: headingLevel(el),
          visible: visible(el),
          open: el.open,
          summary: el.querySelector(':scope > summary'),
        }));
        const source = all.find((node) => node.el === entry);
        const inside = (node) => node.start >= source.start && node.start <= source.end;
        const remaining = all.filter((node) => !inside(node));
        const byElement = new Map(all.map((node) => [node.el, node]));
        const roots = all.filter((node) => isRootHeading(node.el));
        const scopeRoot = subtreeScope ? roots[0] : null;
        const lastLine = Math.max(...all.map((node) => node.end));
        const endLine = scopeRoot ? scopeRoot.end + 1 : lastLine + 1;

        const gapAt = (line, y) => {
          if (scopeRoot && line <= scopeRoot.start) return null;
          let prev = null;
          let next = null;
          for (const node of remaining) {
            if (node.start < line) prev = node;
            else if (!next) next = node;
          }
          let max = 1;
          let anchor = prev;
          if (prev) {
            if (!prev.visible) {
              // Never drop into a collapsed heading: stay beside it.
              let shown = byElement.get(parentHeading(prev.el));
              while (shown && !shown.visible) shown = byElement.get(parentHeading(shown.el));
              anchor = shown || prev;
              max = anchor.level;
            } else {
              max = prev.open ? prev.level + 1 : prev.level;
            }
          }
          let min = next ? next.level : 1;
          if (scopeRoot) min = Math.max(min, scopeRoot.level + 1);
          if (min > max) return null;
          return { line, y, prev, next, min, max };
        };

        const gaps = [];
        const push = (gap) => { if (gap) gaps.push(gap); };
        for (const node of remaining) {
          if (node.visible) push(gapAt(node.start, pageTop(node.el)));
        }
        push(gapAt(source.start, pageTop(source.el)));
        const lastVisible = scopeRoot ? scopeRoot : roots.filter((node) => node.visible).at(-1);
        if (lastVisible) push(gapAt(endLine, pageBottom(lastVisible.el)));
        gaps.sort((a, b) => a.y - b.y);

        // Walking back from the gap, the first heading with a lower level
        // is the one the moved heading would sit inside.
        const parentFor = (gap, level) => {
          for (let index = remaining.length - 1; index >= 0; index -= 1) {
            const node = remaining[index];
            if (node.start < gap.line && node.level < level) return node;
          }
          return null;
        };

        const columnFor = (gap, level, parent) => {
          const parentElement = parent ? parent.el : null;
          const siblings = remaining.filter((node) => node.level === level && node.visible
            && (parentHeading(node.el) || null) === parentElement);
          const near = siblings.find((node) => node.start >= gap.line) || siblings.at(-1);
          if (near?.summary) return leftOf(near.summary);
          if (parent?.summary && parent.visible) return leftOf(parent.summary) + 18;
          const top = roots.find((node) => node.visible && node.summary);
          return top ? leftOf(top.summary) : leftOf(document.querySelector('main') || document.body) + 16;
        };

        return {
          kind: 'heading',
          source,
          level: source.level,
          gaps,
          resolve(gap, level) {
            const parent = parentFor(gap, level);
            const x = columnFor(gap, level, parent);
            const movesOut = (parent ? parent.el : null) !== parentHeading(source.el);
            const label = !movesOut ? '' : parent ? `Inside “${headingTitle(parent.el)}”` : 'Top level';
            const unchanged = (gap.line === source.start || gap.line === source.end + 1) && level === source.level;
            return {
              x,
              label,
              unchanged,
              payload: {
                kind: 'heading',
                startLine: source.start,
                endLine: source.end,
                targetLine: gap.line,
                level,
                headingLines: all.filter(inside).map((node) => node.start),
              },
              domTarget: gap.next && gap.next.level === level && level === source.level ? gap.next.el : null,
            };
          },
        };
      };

      const listModel = (entry) => {
        let root = entry.parentElement;
        while (root.parentElement?.matches?.('li[data-org2-start-line]')
          && /^(UL|OL)$/.test(root.parentElement.parentElement?.tagName || '')) {
          root = root.parentElement.parentElement;
        }
        const depthOf = (li) => {
          let depth = 0;
          let cursor = li.parentElement;
          while (cursor && cursor !== root) {
            if (cursor.matches?.('li[data-org2-start-line]')) depth += 1;
            cursor = cursor.parentElement;
          }
          return depth;
        };
        const all = [...root.querySelectorAll('li[data-org2-start-line]')]
          .filter(isListItem)
          .map((el) => ({ el, start: startOf(el), end: endOf(el), depth: depthOf(el), visible: visible(el) }));
        const source = all.find((node) => node.el === entry);
        const inside = (node) => node.start >= source.start && node.start <= source.end;
        const remaining = all.filter((node) => !inside(node));
        const byElement = new Map(all.map((node) => [node.el, node]));
        const listStart = Math.min(...all.map((node) => node.start));
        const listEnd = Math.max(...all.map((node) => node.end));
        const parentItem = (node) => byElement.get(node.el.parentElement?.closest('li[data-org2-start-line]')) || null;
        const chain = (node) => {
          const result = [];
          for (let cursor = node; cursor && root.contains(cursor.el); cursor = parentItem(cursor)) result.push(cursor);
          return result;
        };

        const gapAt = (line, y) => {
          let prev = null;
          let next = null;
          for (const node of remaining) {
            if (node.start < line) prev = node;
            else if (!next) next = node;
          }
          const min = next ? next.depth : 0;
          const max = prev ? prev.depth + 1 : 0;
          if (min > max) return null;
          return { line, y, prev, next, min, max };
        };

        const gaps = [];
        const push = (gap) => { if (gap) gaps.push(gap); };
        for (const node of remaining) if (node.visible) push(gapAt(node.start, pageTop(node.el)));
        push(gapAt(source.start, pageTop(source.el)));
        push(gapAt(listEnd + 1, pageBottom(root)));
        gaps.sort((a, b) => a.y - b.y);

        return {
          kind: 'listItem',
          source,
          level: source.depth,
          gaps,
          resolve(gap, depth) {
            const ancestors = gap.prev ? chain(gap.prev) : [];
            let reference = ancestors.find((node) => node.depth === depth) || null;
            let relation = 'sibling';
            if (!reference && gap.next && gap.next.depth === depth) reference = gap.next;
            if (!reference && gap.prev && depth === gap.prev.depth + 1) {
              reference = gap.prev;
              relation = 'child';
            }
            if (!reference) return null;
            const parent = relation === 'child' ? reference : ancestors.find((node) => node.depth === depth - 1) || null;
            const x = relation === 'child' ? leftOf(reference.el) + 24 : leftOf(reference.el);
            const unchanged = (gap.line === source.start || gap.line === source.end + 1) && depth === source.depth;
            return {
              x,
              label: (parent ? parent.el : null) === (parentItem(source)?.el || null)
                ? ''
                : parent ? `Inside “${itemTitle(parent.el)}”` : 'Top level',
              unchanged,
              payload: {
                kind: 'listItem',
                startLine: source.start,
                endLine: source.end,
                targetLine: gap.line,
                referenceLine: reference.start,
                relation,
                listStartLine: listStart,
                listEndLine: listEnd,
              },
              domTarget: gap.next && gap.next.depth === depth && depth === source.depth ? gap.next.el : null,
            };
          },
        };
      };

      const beginDrag = (start, event) => {
        const entry = start.entry;
        const model = isListItem(entry) ? listModel(entry) : headingModel(entry);
        pending = null;
        if (!model?.source || !model.gaps.length) return;
        hovered?.classList.remove('org2-drag-hover');
        hovered = null;
        const indicator = document.createElement('div');
        indicator.className = 'org2-drag-indicator';
        const label = document.createElement('div');
        label.className = 'org2-drag-indicator-label';
        indicator.appendChild(label);
        const ghost = document.createElement('div');
        ghost.className = 'org2-drag-ghost';
        ghost.textContent = model.kind === 'heading' ? headingTitle(entry) : itemTitle(entry);
        document.body.append(indicator, ghost);
        document.documentElement.classList.add('org2-outline-dragging');
        entry.classList.add('org2-drag-source');
        drag = {
          model,
          entry,
          pointerId: start.pointerId,
          startX: start.x,
          indicator,
          label,
          ghost,
          choice: null,
          frame: requestAnimationFrame(autoScroll),
        };
        lastMove = { x: event.clientX, y: event.clientY };
        update();
      };

      const update = () => {
        if (!drag || !lastMove) return;
        const { model } = drag;
        const pageY = lastMove.y + window.scrollY;
        let gap = model.gaps[0];
        for (const candidate of model.gaps) {
          if (Math.abs(candidate.y - pageY) < Math.abs(gap.y - pageY)) gap = candidate;
        }
        const desired = model.level + Math.round((lastMove.x - drag.startX) / INDENT_STEP);
        const level = Math.max(gap.min, Math.min(gap.max, desired));
        const choice = model.resolve(gap, level);
        drag.choice = choice;
        drag.ghost.style.left = `${lastMove.x + 14}px`;
        drag.ghost.style.top = `${lastMove.y + 10}px`;
        if (!choice) {
          drag.indicator.style.display = 'none';
          return;
        }
        const main = document.querySelector('main') || document.body;
        const right = main.getBoundingClientRect().right - 8;
        const x = Math.max(4, choice.x);
        drag.indicator.style.display = 'block';
        drag.indicator.style.left = `${x}px`;
        drag.indicator.style.width = `${Math.max(48, right - x)}px`;
        drag.indicator.style.top = `${gap.y - window.scrollY - (model.kind === 'heading' ? 6 : 2)}px`;
        drag.label.textContent = choice.unchanged ? '' : choice.label;
      };

      const autoScroll = () => {
        if (!drag) return;
        if (lastMove) {
          const height = window.innerHeight;
          let delta = 0;
          if (lastMove.y < EDGE) delta = -Math.ceil((EDGE - lastMove.y) / 4);
          else if (lastMove.y > height - EDGE) delta = Math.ceil((lastMove.y - (height - EDGE)) / 4);
          if (delta) {
            const before = window.scrollY;
            window.scrollBy(0, delta);
            if (window.scrollY !== before) update();
          }
        }
        drag.frame = requestAnimationFrame(autoScroll);
      };

      const finishDrag = (commit) => {
        const current = drag;
        drag = null;
        lastMove = null;
        if (!current) return;
        cancelAnimationFrame(current.frame);
        current.indicator.remove();
        current.ghost.remove();
        document.documentElement.classList.remove('org2-outline-dragging');
        current.entry.classList.remove('org2-drag-source');
        const choice = current.choice;
        if (!commit || !choice || choice.unchanged) return;
        const entry = current.entry;
        const restore = { parent: entry.parentNode, next: entry.nextSibling };
        if (choice.domTarget && choice.domTarget.parentNode) {
          choice.domTarget.parentNode.insertBefore(entry, choice.domTarget);
        }
        entry.classList.add('org2-drag-pending');
        window.__org2OutlineMoveRestore = () => {
          entry.classList.remove('org2-drag-pending');
          if (restore.parent) restore.parent.insertBefore(entry, restore.next);
        };
        window.webkit?.messageHandlers?.\#(messageHandlerName)?.postMessage(choice.payload);
      };

      window.__org2FinishOutlineMove = (persisted) => {
        const restore = window.__org2OutlineMoveRestore;
        window.__org2OutlineMoveRestore = null;
        if (!persisted) restore?.();
      };

      window.__org2SetOutlineDragEnabled = (on, subtree) => {
        enabled = Boolean(on);
        subtreeScope = Boolean(subtree);
        document.documentElement.classList.toggle('org2-outline-drag', enabled);
        if (enabled) installGrips();
        if (!enabled && drag) finishDrag(false);
      };
    })();
    """#
  }
}
