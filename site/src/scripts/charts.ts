// Small SVG charts for the status data. No library: a few hundred bytes of
// geometry each, CSP-safe (SVG attributes + CSSOM only, never style="" or
// innerHTML), themed by CSS classes, interactive by pointer and keyboard.
// Every chart has an adjacent table view in the markup, so tooltips never gate data.

import { svg } from './live';

// --- tooltip ---------------------------------------------------------------

export interface TipRow {
  value: string;
  label: string;
}

function tooltipEl(): HTMLElement | null {
  return document.querySelector<HTMLElement>('[data-tooltip]');
}

export function showTip(x: number, y: number, title: string, rows: TipRow[]): void {
  const tip = tooltipEl();
  if (!tip) return;
  const head = document.createElement('p');
  head.className = 'tooltip-label mb-1';
  head.textContent = title;
  const body = rows.map((r) => {
    const row = document.createElement('p');
    const v = document.createElement('span');
    v.className = 'tooltip-value';
    v.textContent = r.value;
    const l = document.createElement('span');
    l.className = 'tooltip-label ml-2';
    l.textContent = r.label;
    row.append(v, l);
    return row;
  });
  tip.replaceChildren(head, ...body);
  tip.hidden = false;
  const { width, height } = tip.getBoundingClientRect();
  const left = Math.min(Math.max(8, x + 14), innerWidth - width - 8);
  const top = y - height - 12 < 8 ? y + 16 : y - height - 12;
  tip.style.setProperty('--tx', `${left}px`);
  tip.style.setProperty('--ty', `${top}px`);
}

export function hideTip(): void {
  const tip = tooltipEl();
  if (tip) tip.hidden = true;
}

/** Wire hover + keyboard focus on one mark to the shared tooltip. */
function bindTip(mark: SVGElement, content: () => [string, TipRow[]]): void {
  mark.setAttribute('tabindex', '0');
  const show = (x: number, y: number) => showTip(x, y, ...content());
  mark.addEventListener('pointermove', (e) => show(e.clientX, e.clientY));
  mark.addEventListener('pointerleave', hideTip);
  mark.addEventListener('focus', () => {
    const r = mark.getBoundingClientRect();
    show(r.left + r.width / 2, r.top);
  });
  mark.addEventListener('blur', hideTip);
}

/** Re-render on container resize so text stays at its real pixel size. */
function responsive(container: HTMLElement, draw: (width: number) => void): void {
  let last = 0;
  const run = () => {
    const w = Math.floor(container.clientWidth);
    if (w > 0 && w !== last) {
      last = w;
      draw(w);
    }
  };
  new ResizeObserver(run).observe(container);
  run();
}

function canvas(container: HTMLElement, width: number, height: number, label: string): SVGSVGElement {
  const root = svg('svg', { viewBox: `0 0 ${width} ${height}`, width, height, role: 'img', 'aria-label': label });
  container.replaceChildren(root);
  return root;
}

/** Bar with 4px rounded data-end and square baseline (dataviz mark spec). */
function barPath(x: number, y: number, w: number, h: number): string {
  const r = Math.min(4, w / 2, h);
  return `M${x},${y + h}V${y + r}Q${x},${y} ${x + r},${y}H${x + w - r}Q${x + w},${y} ${x + w},${y + r}V${y + h}Z`;
}

function niceMax(v: number): number {
  if (v <= 0) return 1;
  const p = 10 ** Math.floor(Math.log10(v));
  // Multipliers whose quarters are round numbers (ticks at max/4).
  return [1, 2, 4, 5, 8, 10].map((m) => m * p).find((c) => c >= v)!;
}

// --- sparkline (stat tiles) ------------------------------------------------

export function sparkline(el: SVGSVGElement, values: (number | null)[]): void {
  const pts = values.map((v, i) => [i, v] as const).filter((p): p is readonly [number, number] => p[1] !== null);
  el.replaceChildren();
  if (pts.length < 2) return;
  const [lo, hi] = [Math.min(...pts.map((p) => p[1])), Math.max(...pts.map((p) => p[1]))];
  const span = hi - lo || 1;
  const n = values.length - 1 || 1;
  const xy = pts.map(([i, v]) => [(i / n) * 100, 22 - ((v - lo) / span) * 20] as const);
  el.setAttribute('viewBox', '0 0 100 24');
  el.setAttribute('preserveAspectRatio', 'none');
  el.append(
    svg('path', {
      d: xy.map(([x, y], i) => `${i ? 'L' : 'M'}${x.toFixed(2)},${y.toFixed(2)}`).join(''),
      class: 'spark-line',
      'vector-effect': 'non-scaling-stroke',
    }),
  );
}

// --- uptime strip: one bar per day ----------------------------------------

export interface Day {
  date: string;
  availability: number | null;
  bad_min: number;
  p95_ms: number | null;
}

export function dayState(a: number | null, target: number): 'good' | 'warn' | 'bad' | 'none' {
  if (a === null) return 'none';
  return a >= target ? 'good' : a >= 0.99 ? 'warn' : 'bad';
}

const STATE_LABEL = { good: 'Met SLO', warn: 'Below SLO', bad: 'Outage', none: 'No data' } as const;

export function uptimeStrip(container: HTMLElement, days: Day[], target: number, nDays = 30): void {
  const byDate = new Map(days.map((d) => [d.date, d]));
  const dates = Array.from({ length: nDays }, (_, i) =>
    new Date(Date.now() - (nDays - 1 - i) * 86400000).toISOString().slice(0, 10),
  );

  responsive(container, (width) => {
    const barH = 44;
    const height = barH + 20;
    const gap = width < 480 ? 2 : 4;
    const bw = Math.min(24, (width - gap * (nDays - 1)) / nDays);
    const root = canvas(container, width, height, `Daily availability, last ${nDays} days`);

    // Axis labels sit under the first and last bar, wherever the strip ends.
    const stripEnd = bw * nDays + gap * (nDays - 1);
    for (const [x, anchor, text] of [[0, 'start', '30 days ago'], [stripEnd, 'end', 'today']] as const) {
      const t = svg('text', { x, y: height - 4, 'text-anchor': anchor, class: 'chart-axis' });
      t.textContent = text;
      root.append(t);
    }

    dates.forEach((date, i) => {
      const d = byDate.get(date);
      const a = d?.availability ?? null;
      const state = dayState(a, target);
      const bar = svg('path', { d: barPath(i * (bw + gap), 0, bw, barH), class: 'day', 'data-state': state });
      bar.setAttribute('aria-label', `${date}: ${a === null ? 'no data' : `${(a * 100).toFixed(3)}%`}`);
      bindTip(bar, () => [
        date,
        a === null
          ? [{ value: 'No data', label: '' }]
          : [
              { value: `${(a * 100).toFixed(3)}%`, label: STATE_LABEL[state] },
              { value: `${d!.bad_min} min`, label: 'bad minutes' },
              { value: d!.p95_ms === null ? '—' : `${d!.p95_ms} ms`, label: 'p95 latency' },
            ],
      ]);
      root.append(bar);
    });
  });
}

// --- line chart with crosshair (daily p95 latency) ------------------------

export interface Point {
  label: string;
  value: number | null;
}

export function lineChart(container: HTMLElement, points: Point[], opts: { unit: string; name: string }): void {
  responsive(container, (width) => {
    const height = 200;
    const pad = { top: 12, right: 12, bottom: 24, left: 44 };
    const plotW = width - pad.left - pad.right;
    const plotH = height - pad.top - pad.bottom;
    const root = canvas(container, width, height, opts.name);

    const vals = points.map((p) => p.value).filter((v): v is number => v !== null);
    const max = niceMax(vals.length ? Math.max(...vals) : 1);
    const x = (i: number) => pad.left + (points.length > 1 ? (i / (points.length - 1)) * plotW : plotW / 2);
    const y = (v: number) => pad.top + plotH - (v / max) * plotH;

    // Recessive hairline grid with clean ticks.
    for (let t = 0; t <= 4; t++) {
      const v = (max / 4) * t;
      root.append(svg('line', { x1: pad.left, x2: width - pad.right, y1: y(v), y2: y(v), class: 'chart-grid' }));
      const tick = svg('text', { x: pad.left - 8, y: y(v) + 4, 'text-anchor': 'end', class: 'chart-axis' });
      tick.textContent = `${Math.round(v)}`;
      root.append(tick);
    }

    if (points.length) {
      for (const [i, anchor] of [[0, 'start'], [points.length - 1, 'end']] as const) {
        const lbl = svg('text', { x: x(i), y: height - 6, 'text-anchor': anchor, class: 'chart-axis' });
        lbl.textContent = points[i].label;
        root.append(lbl);
      }
    }

    // Line segments skip gaps (days without data).
    let d = '';
    let pen = false;
    points.forEach((p, i) => {
      if (p.value === null) {
        pen = false;
        return;
      }
      d += `${pen ? 'L' : 'M'}${x(i).toFixed(1)},${y(p.value).toFixed(1)}`;
      pen = true;
    });
    if (d) {
      const firstIdx = points.findIndex((p) => p.value !== null);
      const lastIdx = points.length - 1 - [...points].reverse().findIndex((p) => p.value !== null);
      if (!d.slice(1).includes('M')) {
        root.append(svg('path', { d: `${d}L${x(lastIdx)},${y(0)}L${x(firstIdx)},${y(0)}Z`, class: 'chart-area' }));
      }
      root.append(svg('path', { d, class: 'chart-line' }));
      const last = points[lastIdx];
      root.append(svg('circle', { cx: x(lastIdx), cy: y(last.value!), r: 4, class: 'chart-dot' }));
    }

    // Crosshair: snaps to the nearest day; whole plot is the hit target.
    const cross = svg('line', { y1: pad.top, y2: pad.top + plotH, class: 'chart-crosshair', visibility: 'hidden' });
    const dot = svg('circle', { r: 4, class: 'chart-dot', visibility: 'hidden' });
    const hit = svg('rect', { x: pad.left, y: pad.top, width: plotW, height: plotH, fill: 'transparent', tabindex: 0 });
    hit.setAttribute('aria-label', `${opts.name}: use arrow keys to step through days`);
    root.append(cross, dot, hit);

    let focusIdx = points.length - 1;
    const select = (i: number, clientX: number, clientY: number) => {
      const p = points[i];
      cross.setAttribute('x1', String(x(i)));
      cross.setAttribute('x2', String(x(i)));
      cross.setAttribute('visibility', 'visible');
      if (p.value !== null) {
        dot.setAttribute('cx', String(x(i)));
        dot.setAttribute('cy', String(y(p.value)));
        dot.setAttribute('visibility', 'visible');
      } else {
        dot.setAttribute('visibility', 'hidden');
      }
      showTip(clientX, clientY, p.label, [{ value: p.value === null ? 'No data' : `${p.value} ${opts.unit}`, label: opts.name }]);
    };
    const clear = () => {
      cross.setAttribute('visibility', 'hidden');
      dot.setAttribute('visibility', 'hidden');
      hideTip();
    };
    hit.addEventListener('pointermove', (e) => {
      const box = root.getBoundingClientRect();
      const px = ((e.clientX - box.left) / box.width) * width;
      focusIdx = Math.round(((px - pad.left) / plotW) * (points.length - 1));
      focusIdx = Math.max(0, Math.min(points.length - 1, focusIdx));
      select(focusIdx, e.clientX, e.clientY);
    });
    hit.addEventListener('pointerleave', clear);
    hit.addEventListener('blur', clear);
    hit.addEventListener('keydown', (e) => {
      if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return;
      e.preventDefault();
      focusIdx = Math.max(0, Math.min(points.length - 1, focusIdx + (e.key === 'ArrowRight' ? 1 : -1)));
      const box = root.getBoundingClientRect();
      select(focusIdx, box.left + (x(focusIdx) / width) * box.width, box.top + pad.top);
    });
  });
}

// --- segmented bar (latency phases: parts of one request) ------------------

export interface Segment {
  label: string;
  value: number;
  cls: string;
}

export function segmentedBar(container: HTMLElement, segments: Segment[], unit: string): void {
  const total = segments.reduce((s, x) => s + Math.max(0, x.value), 0);
  responsive(container, (width) => {
    const height = 20;
    const root = canvas(container, width, height, 'Request time by phase');
    if (!total) return;
    const gap = 2;
    const usable = width - gap * (segments.length - 1);
    let x = 0;
    segments.forEach((s, i) => {
      const w = Math.max(2, (Math.max(0, s.value) / total) * usable);
      const r = i === 0 || i === segments.length - 1 ? 4 : 0;
      const rect = svg('rect', { x, y: 0, width: w, height, rx: r, class: s.cls });
      bindTip(rect, () => ['Median, last 24h', [{ value: `${s.value} ${unit}`, label: s.label }]]);
      root.append(rect);
      x += w + gap;
    });
  });
}

// --- error budget meter ----------------------------------------------------

/** Fill width goes through a CSS custom property (CSSOM), never a style attribute. */
export function budgetMeter(el: HTMLElement, remainingRatio: number): void {
  const left = Math.max(0, Math.min(1, remainingRatio));
  const fill = el.querySelector<HTMLElement>('.meter-fill');
  if (!fill) return;
  fill.style.setProperty('--w', `${(left * 100).toFixed(1)}%`);
  fill.dataset.state = left > 0.5 ? 'ok' : left > 0.2 ? 'warn' : 'bad';
}
