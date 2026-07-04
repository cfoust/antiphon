// The "close your eyes" workflow demo — the site's key moment. Mounted into
// the listening-room section (#listen-panel). NOT a video: a DOM-rendered
// imaginary desktop → eyelids close → the radar world (like the real app) →
// gaze sweeps two done agents' summaries → eyes open → the talk-back letter →
// a typed reply. Synchronized to a pre-baked soundtrack rendered offline by
// the real engine (tools/gen-hero-audio.py + chamber-render scenario), with
// an unmute control. Owned by the hero build — the sections port must not
// edit this file.

export function mountHero(el: HTMLElement | null): void {
  if (!el) return;
  el.innerHTML = `<div style="display:flex;align-items:center;justify-content:center;height:100%;color:#A39684;font-size:14px">listening room — under construction</div>`;
}
