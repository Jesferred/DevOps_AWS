// Client side of the Live infra block and /status page. Reads the JSON written
// every 5 minutes by the monitoring aggregator and fills [data-live] elements.
// DOM is built with textContent / SVG attributes only: no innerHTML, no inline
// styles, so it works under the strict CSP.

export interface Status {
  generated_at: string;
  slo: { target: number; window_days: number };
  availability: Record<'30d' | '7d' | '24h', number | null>;
  coverage_30d: number;
  error_budget: { total_min: number; consumed_min: number; remaining_min: number; remaining_ratio: number };
  burn_rate: Record<'5m' | '30m' | '1h' | '6h', number | null>;
  alerts: { fast_burn: boolean; slow_burn: boolean };
  latency_ms: Record<'24h' | '30d', Record<'p50' | 'p95' | 'p99', number | null>>;
  phases_ms_24h: Record<'dns' | 'connect' | 'tls' | 'ttfb', number | null>;
  tls_cert_days_left: number | null;
  regions: { region: string; last_ok: boolean; last_ms: number | null; last_at: string; p95_24h_ms: number | null; availability_24h: number }[];
  incidents: {
    count_30d: number;
    mttr_min: number | null;
    mtbf_h: number | null;
    recent: { start: string; end: string | null; duration_min: number }[];
  };
  daily: { date: string; availability: number | null; bad_min: number; p95_ms: number | null }[];
  cost: {
    month: string;
    month_to_date: number;
    forecast_month: number | null;
    by_service: { service: string; amount: number }[];
    updated_at: string;
  } | null;
  security: {
    checked_at: string;
    ssl_labs: { grade: string; endpoints: number; protocols: string[]; report_url: string } | null;
    observatory: { grade: string; score: number; tests_passed: number; tests_total: number; report_url: string } | null;
    hsts_preload: string | null;
    dnssec: boolean | null;
    caa: boolean | null;
    dmarc_policy: string | null;
  } | null;
  dora: {
    deployments: number;
    deploys_per_week: number;
    deploy_frequency_level: Level | null;
    lead_time_h: number | null;
    lead_time_level: Level | null;
    change_failure_rate: number | null;
    change_failure_rate_level: Level | null;
    time_to_restore_min: number | null;
    time_to_restore_level: Level | null;
    recent: { at: string; kind: string; sha: string; status: string; lead_time_h: number; run_url: string | null }[];
  };
}

export type Level = 'elite' | 'high' | 'medium' | 'low';

export type Health = 'operational' | 'degraded' | 'stale' | 'unknown';

const STALE_AFTER_MS = 15 * 60 * 1000;

let pending: Promise<Status | null> | undefined;

/** One fetch per page view, shared by every block that shows live data. */
export function loadStatus(): Promise<Status | null> {
  pending ??= fetch('/live/status.json', { cache: 'no-cache' })
    .then((res) => (res.ok ? (res.json() as Promise<Status>) : null))
    .catch(() => null);
  return pending;
}

export function health(s: Status | null): Health {
  if (!s || s.availability['24h'] === null) return 'unknown';
  if (Date.now() - Date.parse(s.generated_at) > STALE_AFTER_MS) return 'stale';
  const lastFailures = s.regions.filter((r) => !r.last_ok).length;
  if (s.alerts.fast_burn || s.alerts.slow_burn || lastFailures * 2 > s.regions.length) return 'degraded';
  return 'operational';
}

export const fmt = {
  pct: (v: number | null | undefined, digits = 3) => (v == null ? '—' : `${(v * 100).toFixed(digits)}%`),
  ms: (v: number | null | undefined) => (v == null ? '—' : `${Math.round(v)} ms`),
  usd: (v: number | null | undefined) => (v == null ? '—' : `$${v.toFixed(2)}`),
  min: (v: number | null | undefined) => (v == null ? '—' : `${v.toFixed(1)} min`),
  hours: (v: number | null | undefined) => (v == null ? '—' : v >= 48 ? `${(v / 24).toFixed(1)} d` : `${v.toFixed(1)} h`),
  rate: (v: number | null | undefined) => (v == null ? '—' : `${v.toFixed(2)}×`),
  int: (v: number | null | undefined) => (v == null ? '—' : String(v)),
  ago: (iso: string | null | undefined) => {
    if (!iso) return '—';
    const s = Math.max(0, Math.round((Date.now() - Date.parse(iso)) / 1000));
    if (s < 90) return `${s}s ago`;
    if (s < 5400) return `${Math.round(s / 60)} min ago`;
    if (s < 172800) return `${Math.round(s / 3600)} h ago`;
    return `${Math.round(s / 86400)} d ago`;
  },
  utc: (iso: string | null | undefined) => (iso ? `${iso.slice(0, 16).replace('T', ' ')} UTC` : '—'),
  text: (v: string | null | undefined) => (v == null || v === '' ? '—' : String(v)),
  duration: (h: number | null | undefined) =>
    h == null ? '—' : h < 1 ? `${Math.round(h * 60)} min` : h < 48 ? `${h.toFixed(1)} h` : `${(h / 24).toFixed(1)} d`,
  perWeek: (v: number | null | undefined) => (v == null ? '—' : `${v.toFixed(1)} / week`),
};

/** Resolve "a.b.c" against the status object. */
function pick(obj: unknown, path: string): unknown {
  return path.split('.').reduce<unknown>((o, k) => (o == null ? undefined : (o as Record<string, unknown>)[k]), obj);
}

/** Fill every <el data-live="path" data-fmt="pct|ms|..."> under root. */
export function fill(root: ParentNode, s: Status): void {
  root.querySelectorAll<HTMLElement>('[data-live]').forEach((el) => {
    const value = pick(s, el.dataset.live!);
    const f = fmt[(el.dataset.fmt ?? 'int') as keyof typeof fmt] as (v: unknown, digits?: number) => string;
    el.textContent = el.dataset.digits ? f(value, Number(el.dataset.digits)) : f(value);
  });
}

/**
 * <el data-check="security.dnssec"> gets data-state="pass|fail|unknown";
 * <el data-level="dora.lead_time_level"> gets data-state=<level> and the level as text.
 * Colors come from CSS attribute selectors, never inline styles.
 */
export function fillStates(root: ParentNode, s: Status): void {
  root.querySelectorAll<HTMLElement>('[data-check]').forEach((el) => {
    const v = pick(s, el.dataset.check!);
    const pass = el.dataset.pass ? el.dataset.pass.split(',').includes(String(v)) : v === true;
    el.dataset.state = v == null ? 'unknown' : pass ? 'pass' : 'fail';
  });
  root.querySelectorAll<HTMLElement>('[data-level]').forEach((el) => {
    const v = pick(s, el.dataset.level!) as string | null | undefined;
    el.dataset.state = v ?? 'unknown';
    el.textContent = v ?? '—';
  });
  root.querySelectorAll<HTMLAnchorElement>('a[data-href]').forEach((a) => {
    const href = pick(s, a.dataset.href!);
    if (typeof href === 'string' && href.startsWith('https://')) a.href = href;
  });
}

export function setHealth(root: ParentNode, h: Health): void {
  const labels: Record<Health, string> = {
    operational: 'Operational',
    degraded: 'Degraded',
    stale: 'Monitoring data is stale',
    unknown: 'Collecting data',
  };
  root.querySelectorAll<HTMLElement>('[data-health]').forEach((el) => {
    el.dataset.health = h;
    const text = el.querySelector('[data-health-text]');
    if (text) text.textContent = labels[h];
  });
}

export function el<K extends keyof HTMLElementTagNameMap>(tag: K, cls = '', text = ''): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  if (text) node.textContent = text;
  return node;
}

export function svg<K extends keyof SVGElementTagNameMap>(tag: K, attrs: Record<string, string | number>): SVGElementTagNameMap[K] {
  const node = document.createElementNS('http://www.w3.org/2000/svg', tag);
  for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, String(v));
  return node;
}
