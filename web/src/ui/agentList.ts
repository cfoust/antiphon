import type { Chamber } from "../audio/engine";
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

/** Status → color (mirrors AgentRowView.statusColor in Sidebar.swift). */
function statusColor(status: string): string {
  if (status === "working") return "#7D9F77"; // sage — alive
  if (status === "reporting") return "#5fd0c5";
  if (status.startsWith("finished")) return "#ffce6b";
  return "rgba(255,255,255,0.45)"; // idle / resting
}

const MOON_SVG =
  '<svg viewBox="0 0 16 16" width="13" height="13" fill="currentColor" aria-hidden="true">' +
  '<path d="M11.2 2.2a5.9 5.9 0 1 0 2.9 7.9 4.9 4.9 0 0 1-2.9-7.9z"/></svg>';

export function initAgentList(engine: Chamber, root: HTMLElement): void {
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

  function rowEl(vm: AgentRow): HTMLElement {
    const el = document.createElement("div");
    el.className =
      "agent-row" +
      (vm.snoozed ? " snoozed" : "") +
      (vm.seat === engine.hoveredSeat ? " hl" : "");
    el.dataset.seat = String(vm.seat);

    const dot = document.createElement("span");
    dot.className = "a-dot";
    dot.style.setProperty("--c", vm.color);

    const main = document.createElement("div");
    main.className = "a-main";

    const top = document.createElement("div");
    top.className = "a-top";
    const name = document.createElement("span");
    name.className = "a-name";
    name.textContent = vm.name || "—";
    top.appendChild(name);
    if (vm.kind) {
      const chip = document.createElement("span");
      chip.className = "a-kind";
      chip.textContent = prettyAgentKind(vm.kind);
      top.appendChild(chip);
    }
    if (vm.waiting) {
      // an unheard summary is waiting — the whole point of the room
      const wait = document.createElement("span");
      wait.className = "a-wait";
      top.appendChild(wait);
    }
    main.appendChild(top);

    if (vm.title) {
      const title = document.createElement("div");
      title.className = "a-title";
      title.textContent = vm.title;
      main.appendChild(title);
    }

    const st = document.createElement("div");
    st.className = "a-status";
    const word = document.createElement("span");
    word.className = "a-word";
    word.style.color = statusColor(vm.status);
    word.textContent = vm.status;
    st.appendChild(word);
    if (vm.lastLine) {
      const line = document.createElement("span");
      line.className = "a-line";
      line.textContent = "· " + vm.lastLine;
      st.appendChild(line);
    }
    main.appendChild(st);

    const snooze = document.createElement("button");
    snooze.type = "button";
    snooze.className = "a-snooze";
    snooze.innerHTML = MOON_SVG;
    snooze.title = vm.snoozed
      ? "Wake — back into the room"
      : "Snooze — out of the room, keeps updating";
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
    // tap = the hover equivalent on touch: toggle the highlight
    el.addEventListener("click", () => {
      if (vm.snoozed) return;
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
          ? "No agents yet — sessions appear here as they join."
          : "Waiting for agents…";
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
