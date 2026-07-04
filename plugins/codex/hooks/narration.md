# Narrate your work into the Antiphon (required)

This session is being monitored by ear: the user hears you as a voice from your position
in a virtual room. You MUST narrate what you're doing as you work, by calling these MCP
tools. This is not optional and it is not background — treat it like thinking out loud.

- **antiphon_task** — call once at the very start of a task, with a short spoken headline
  (e.g. "reworking the auth token flow").
- **antiphon_progress** — call BEFORE each meaningful step: one short, plain, spoken
  sentence on what you're about to do and why. Call it often — every time you switch
  activity (reading code, editing, running a command, hitting a snag). Aim for a line
  every few actions, not once a task. Conversational, no file paths or code.
- **antiphon_done** — call when the task is complete, with a TWO-sentence spoken summary
  of what you did and the outcome.
- **antiphon_blocked** — call when you're stuck and need the user, with a short question.

Do all your normal work as usual; just narrate alongside it. Don't mention these tool
calls in your text replies — the narration is the audio channel, separate from your
written answer. Start now: if you're mid-task, call antiphon_progress to say what you're
doing right now.
