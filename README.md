# AI-First — product & technical spec

A macOS menu-bar app with a desktop mascot that watches what you're doing, notices when
you're doing something by hand that AI could do, and interrupts you about it — then hands
the task to Claude in one gesture.

> "Basically my job is to look over your shoulder and slap your wrist every time you
> default to an application that's not AI."
>
> "Set a timer on your phone to remind you to use AI, and then whatever you're doing at
> that particular moment, take a screenshot of it, drop it into Claude, and just say
> 'can you help me with this.'"
>
> — the two AI trainers whose framing this product is built from

---

## Executive summary

**The product.** A lightweight Mac app, no Dock icon, one permission prompt. It reads
which app you're in and what your window is called. When it sees a pattern that means
"you're about to do this the slow way" — ninety seconds parked on a single email, two
minutes in a Slack thread, a blank document — a goose waddles into view and gets annoyed
at you. Click the goose and it captures the window and drops it into Claude with a
prompt already written.

**Why the mascot.** The failure mode of every accountability tool is that it becomes a
nag and people mute it. A notification saying "you should use AI" is a nag. A goose that
side-eyes your half-typed email is a joke people screenshot and send to their team. The
mascot is simultaneously the retention mechanic and the distribution channel — and it's
what stops the product from reading as surveillance.

**Why it can scale.** Every judgment happens on the device. The server never receives a
window title, a URL, or a pixel — only anonymous counters like "rule 14 fired, user
accepted." At 100,000 monthly actives that's roughly 35 requests per second and low four
figures a month of infrastructure. The same decision that makes it cheap is the one that
makes it survivable in an enterprise security review.

**Who pays.** Individuals install it free or cheap; companies pay per seat for an
aggregate AI-adoption dashboard. Admins see "team adoption: 34% of eligible moments,"
never "Chen wrote fourteen emails by hand." That line is a hard product guarantee, not a
setting.

---

## Read in this order

| Doc | What's in it |
|---|---|
| [01 — Product brief](docs/01-product-brief.md) | Problem, users, competitive gap, pricing, growth model |
| [02 — Detection architecture](docs/02-detection-architecture.md) | How it knows what you're doing, and the browser problem |
| [03 — Rules & nudges](docs/03-rules-and-nudges.md) | The rulebook, trigger conditions, nag-fatigue controls |
| [04 — Mascot & interruptions](docs/04-mascot-and-interruptions.md) | The goose: rendering, escalation ladder, suppression |
| [05 — Handoff](docs/05-handoff.md) | Hotkey → screenshot → Claude, in six steps |
| [06 — Backend & scale](docs/06-backend-and-scale.md) | Services, storage, the 100k MAU math, cost |
| [07 — Privacy & enterprise](docs/07-privacy-and-enterprise.md) | Data contract, admin aggregation, compliance |
| [08 — Roadmap & risks](docs/08-roadmap-and-risks.md) | Phases, decision gates, ranked risks, metrics |

## Decisions already locked

- **Detection is app + window title.** No pixel capture as a baseline signal.
- **No browser extension in the consumer path.** One app, one permission prompt. The
  extension survives only as an optional MDM-deployed enterprise upgrade.
- **Interruptions are a desktop mascot**, not notifications. The mascot is also the
  handoff button.
- **Buyer is B2B teams with consumer-grade UX** — bottom-up adoption into paid seats.
- **Native Swift, distributed outside the Mac App Store.** The sandbox forbids the
  Accessibility API this depends on.

## Open questions

Marked ⚠️ throughout. The consequential ones:

1. Are window titles accurate enough on their own? **Phase 0 answers this with data** —
   see [08](docs/08-roadmap-and-risks.md).
2. Mac-only caps the enterprise market hard. Windows client, and when?
3. Does the goose open doors or close them with real buyers? Test before Phase 3.
4. How original does the character need to be to stay clear of Desktop Goose?
