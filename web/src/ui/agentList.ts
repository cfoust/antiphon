import type { Antiphon } from "../audio/engine";
import { D } from "../demoI18n";
import type { AgentRow } from "../types";

// The agent list: everyone in the room, at a glance (mirrors Sidebar.swift).
// A right rail on desktop; a collapsible bottom sheet on phones. Hovering (or
// tapping) a row lights the agent up on the radar; snoozing sends it to the
// bottom of the list and out of the world (silent + invisible) while its
// updates keep accumulating.

/** "claude-code" → "Claude Code" (mirrors prettyAgentKind in Sidebar.swift). */
export function prettyAgentKind(kind: string): string {
  return kind
    .split("-")
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
    .join(" ");
}

/** Status → a CSS class stem (mirrors AgentRowView.statusColor in Sidebar.swift:
 *  sage = working, teal = reporting, gold = waiting, dim = idle/resting). */
function statusKind(status: string): "working" | "reporting" | "waiting" | "idle" {
  if (status === "working") return "working";
  if (status === "reporting") return "reporting";
  if (status.startsWith("finished")) return "waiting";
  return "idle"; // idle / resting
}

/** "/Users/dev/work/auth-service" → "~/auth-service" — just the folder; the
 *  full path lives in the tooltip. (mirrors AgentRowView.shortDir) */
function shortDir(cwd: string): string {
  const last = cwd.split("/").filter(Boolean).pop();
  return last ? "~/" + last : tildePath(cwd);
}

/** Home-relative path for the tooltip (mirrors tildePath in TalkbackPanel.swift). */
function tildePath(p: string): string {
  return p.replace(/^\/(?:Users|home)\/[^/]+/, "~");
}

/** The whole story on hover: kind · repo ⎇ branch · full path.
 *  (mirrors AgentRowView.fullContext) */
function fullContext(vm: AgentRow): string {
  const parts: string[] = [];
  if (vm.kind) parts.push(prettyAgentKind(vm.kind));
  if (vm.repo) parts.push(vm.branch ? `${vm.repo} ⎇ ${vm.branch}` : vm.repo);
  else if (vm.branch) parts.push(`⎇ ${vm.branch}`);
  if (vm.cwd) parts.push(tildePath(vm.cwd));
  return parts.join(" · ");
}

const MOON_SVG =
  '<svg viewBox="0 0 16 16" width="13" height="13" fill="currentColor" aria-hidden="true">' +
  '<path d="M11.2 2.2a5.9 5.9 0 1 0 2.9 7.9 4.9 4.9 0 0 1-2.9-7.9z"/></svg>';

export function initAgentList(engine: Antiphon, root: HTMLElement): void {
  root.innerHTML =
    '<button type="button" class="agents-head">' +
    '<span class="agents-title">In the room</span>' +
    '<span class="agents-count"></span>' +
    '<span class="agents-chevron" aria-hidden="true">▾</span>' +
    "</button>" +
    '<div class="agents-body"></div>';
  const head = root.querySelector<HTMLButtonElement>(".agents-head")!;
  const count = root.querySelector<HTMLSpanElement>(".agents-count")!;
  const body = root.querySelector<HTMLDivElement>(".agents-body")!;

  // the header collapses/expands the sheet on small viewports (CSS decides look)
  head.addEventListener("click", () => root.classList.toggle("open"));

  let lastKey = "";
  let tappedSeat = -1; // touch highlight (no hover on phones): tap toggles

  // Design C (mirrors AgentRowView in Sidebar.swift): the title owns the row
  // (session title, persona-name fallback, 2-line clamp); the last words appear
  // only when the agent is waiting/reporting — that's when they matter; then ONE
  // scannable chip line (status · ⎇ branch · ~/folder). The identity dot carries
  // status: glow = working, gold ring = waiting for you, dim = idle/resting.
  // The full kind · repo ⎇ branch · path story lives in the row tooltip.
  // Snoozed rows collapse to the title alone.
  function rowEl(vm: AgentRow): HTMLElement {
    const kind = statusKind(vm.status);
    const el = document.createElement("div");
    el.className =
      "agent-row st-" +
      kind +
      (vm.snoozed ? " snoozed" : "") +
      (vm.waiting && !vm.snoozed ? " waiting" : "") +
      (vm.seat === engine.hoveredSeat ? " hl" : "");
    el.dataset.seat = String(vm.seat);
    const context = fullContext(vm);
    if (context) el.title = context;

    const dot = document.createElement("span");
    dot.className = "a-dot";
    dot.style.setProperty("--c", vm.color);

    const main = document.createElement("div");
    main.className = "a-main";

    const title = document.createElement("div");
    title.className = "a-title";
    title.textContent = vm.title || vm.name || "—";
    main.appendChild(title);

    if (!vm.snoozed) {
      // the last words matter when the agent wants you (waiting) or is mid-report
      if (vm.lastLine && (vm.waiting || vm.status === "reporting")) {
        const preview = document.createElement("div");
        preview.className = "a-preview";
        preview.textContent = vm.lastLine;
        main.appendChild(preview);
      }

      const chips = document.createElement("div");
      chips.className = "a-chips";
      const status = document.createElement("span");
      status.className = "chip chip-st chip-st-" + kind;
      status.textContent = D.status[vm.status] ?? vm.status;
      chips.appendChild(status);
      if (vm.branch) {
        const branch = document.createElement("span");
        branch.className = "chip chip-branch";
        branch.textContent = "⎇ " + vm.branch;
        chips.appendChild(branch);
      }
      if (vm.cwd) {
        const dir = document.createElement("span");
        dir.className = "chip chip-dir";
        dir.textContent = shortDir(vm.cwd);
        chips.appendChild(dir);
      }
      main.appendChild(chips);
    }

    const snooze = document.createElement("button");
    snooze.type = "button";
    snooze.className = "a-snooze";
    snooze.innerHTML = MOON_SVG;
    snooze.title = vm.snoozed
      ? D.wakeTip
      : D.snoozeTip;
    snooze.addEventListener("click", (e) => {
      e.stopPropagation();
      engine.setSnoozed(vm.seat, !vm.snoozed);
      render(true);
    });

    // hover → radar highlight (snoozed agents aren't in the world)
    el.addEventListener("mouseenter", () => {
      if (!vm.snoozed) engine.setHovered(vm.seat);
      el.classList.add("hover");
    });
    el.addEventListener("mouseleave", () => {
      if (engine.hoveredSeat === vm.seat) engine.setHovered(-1);
      el.classList.remove("hover");
    });
    // tap = the hover equivalent on touch: toggle the highlight; a snoozed
    // row is one big wake button (mirrors AgentRowView.onTapGesture)
    el.addEventListener("click", () => {
      if (vm.snoozed) {
        engine.setSnoozed(vm.seat, false);
        render(true);
        return;
      }
      tappedSeat = tappedSeat === vm.seat ? -1 : vm.seat;
      engine.setHovered(tappedSeat);
      render(true);
    });

    el.appendChild(dot);
    el.appendChild(main);
    el.appendChild(snooze);
    return el;
  }

  function render(force = false): void {
    const rows = engine.buildAgentList();
    const key = JSON.stringify(rows) + "|" + engine.hoveredSeat;
    if (!force && key === lastKey) return;
    lastKey = key;

    count.textContent = rows.length ? String(rows.length) : "";
    body.textContent = "";
    if (!rows.length) {
      const empty = document.createElement("div");
      empty.className = "agents-empty";
      empty.textContent =
        engine.mode === "live"
          ? D.noAgents
          : D.waitingAgents;
      body.appendChild(empty);
      return;
    }
    const active = rows.filter((r) => !r.snoozed);
    const snoozed = rows.filter((r) => r.snoozed);
    for (const vm of active) body.appendChild(rowEl(vm));
    if (snoozed.length) {
      const div = document.createElement("div");
      div.className = "agents-divider";
      div.innerHTML = "<span></span><b>Snoozed</b><span></span>";
      body.appendChild(div);
      for (const vm of snoozed) body.appendChild(rowEl(vm));
    }
  }

  // refresh on engine events + a slow poll (status words move with the clock)
  const prev = engine.onAgents;
  engine.onAgents = () => {
    prev();
    render();
  };
  setInterval(() => render(), 500);
  render(true);
}
