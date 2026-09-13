# Clarify: an agent that lives inside Apple Reminders

## The problem

Everyone captures tasks. Almost no one processes them. Getting Things Done
works only if every captured item is clarified into a concrete next action,
filed by context, calendared when dated, and reviewed weekly. That processing
step is exactly where the method collapses, because it is tedious judgment
work that nobody wants to do at the end of the day. A chatbot cannot help with
this, because the tasks do not live in the chat. They live in Reminders, on
your phone, your watch, and your Mac.

## The environment, and why it matters

Clarify is a resident macOS menu bar agent whose home is Apple Reminders. You
capture the way you already do: "Hey Siri, remind me to text Sam I'm running
late" on your wrist, a line typed on the Mac, a shared link. The agent needs no
new input surface, because Apple built the capture layer and iCloud syncs it
everywhere. Within seconds of an item landing, Clarify has decided whether it
is actionable, written the next physical action, filed it into Next Actions,
Projects, Waiting For, Someday/Maybe, or Reference, put dated items on your
Calendar, and written its reasoning into the reminder's notes.

The environment gives the agent context no chatbot has: your calendar, your
contacts, your files, your open commitments. And it gives the agent a way to
act inside the apps you already use rather than pasting text back at you.

## The core workflow and the innovation

**Consent is a reminder.** Whenever the agent prepares something outward, a
text or an email with an attachment, it never sends. It files a question in an
Approve list: "Text Sam: 'running ten minutes late'?" Checking that reminder,
from any device, is the send button. There is no dialog, no chat turn, and no
new app to open; the approval syncs to your watch. When the agent cannot
proceed without you, it asks the same way: a question reminder whose notes you
fill in, and completing it resumes the agent with your answer.

**The model proposes and deterministic code disposes.** Every decision arrives
as a typed, schema-validated form, never free text, and Swift performs every
move. The model never touches your data directly and never sends anything.

## The agent loop

For any action that needs preparation, Clarify runs a bounded tool-calling
loop. The model chains tools across apps: look up a person in Contacts, find a
file with Spotlight, check a day on the Calendar, search your reminders, search
the web, then draft an email or text, create an event, or save a fact to the
reminder. Read tools run directly; every send waits in Approve; six steps is
the cap.

In a live run, "call the Apple Store to check MacBook stock" searched the web
through Exa, found the store's number with sources, and saved it onto the
reminder ready to tap. "Text Dana I'm running late" looked Dana up, drafted the
text to her number, and queued it for approval, seven seconds end to end.

The rest of GTD runs on timers inside the same app: a tickler that surfaces
start-dated items, a weekly review checklist of stale actions, projects with no
next action, and overdue Waiting Fors, a morning briefing with today's events
and top three actions, and Engage, which takes "twenty minutes, low energy" and
returns the actions that fit using the four-criteria model. A Mail watcher
closes Waiting For items when the person replies.

## Technical execution

- **Platform.** Swift 6 and SwiftUI on macOS 26, a MenuBarExtra app over a
  fully testable Swift package. XcodeGen builds the project. The Release build
  is hardened-runtime and Developer ID signed, with the entitlements Calendar
  and Apple Events require.
- **Integration.** EventKit for Reminders and Calendar, using change
  notifications rather than polling, plus a once-a-minute fallback pass and a
  file log. Contacts through the Contacts framework. Mail and Messages through
  Apple Events. Spotlight for files. A `clarify://` URL scheme lets Shortcuts
  drive the review, sweep, and Engage.
- **Models.** Two paths behind one protocol: Apple Intelligence on-device using
  Foundation Models guided generation with `@Generable` structs, and any
  OpenAI-compatible endpoint with strict JSON Schema output.
- **OpenRouter.** The agentic loop needs native tool calling, so it runs through
  OpenRouter, defaulting to `anthropic/claude-sonnet-5`, with app attribution
  headers on every request.
- **Exa.** Web search is Exa's answer endpoint, which returns grounded answers
  with citations instead of a page of links.
- **Safety.** Keys live in the keychain. Nothing is ever deleted; Trash is a
  list. Every processed item carries a one-line reason.
- **Tests.** 54 unit tests over an in-memory store and fake bridges;
  environment-gated integration tests against the real Reminders store, the
  on-device model, OpenRouter, Exa, and Mail; and an XCUITest that drives the
  real Engage window.
- **Measured.** A sixty-item gold set measures clarification. OpenRouter with
  claude-sonnet-5 files 97 percent of items into the right GTD bucket at 3.5
  seconds median; on-device scores 68 percent at 2.4 seconds.

## Value

Capture stays effortless and the trusted system stays trustworthy, because
every decision is explained in the notes, nothing is ever deleted, and nothing
leaves the Mac without a checked box. The agent is invisible when there is
nothing to do and precise when there is. It is the half of Getting Things Done
that people never do, done for them, inside the app they already have open.
