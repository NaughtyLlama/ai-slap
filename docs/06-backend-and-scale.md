# 06 — Backend & scale

Target: **100,000 monthly active users.** The good news is that this is not a hard
scaling problem, and the reason is a single architectural decision.

## The decision that makes it cheap

**All classification happens on the device. The server never receives a window title, a
URL, or a pixel.**

The client decides what you're doing, whether to interrupt, and how. It sends home only
anonymous counters: *rule 14 fired, user accepted, 3 handoffs today.*

This is doing double duty. It's what keeps infrastructure at low four figures a month
instead of six, and it's the answer to the first question in every enterprise security
review. Those are usually opposing forces; here they're the same choice.

For contrast, the cloud-vision approach — upload frames, classify them server-side with a
vision model — would cost five to six figures a month at the same user count, before
storage, and would make you the custodian of 100,000 people's screen contents. That
decision is the whole ballgame.

## Services

```
Mac client ──┬── rulebook CDN      (pull, every 6h, signed static JSON)
             ├── ingest API        (push, every 15min, counters only)
             ├── auth              (magic link / SSO, short-lived device JWT)
             └── Sparkle appcast   (update check, signed)

Next.js dashboard ── read API ── ClickHouse (counters) + Postgres (identity)
```

### Rulebook CDN

Signed static JSON on Cloudflare or S3+CloudFront. ETag'd, so most polls are 304s.

100k clients polling every 6 hours ≈ **0.5 requests/second**. Effectively free, and the
only piece that must never go down — though a client with a stale rulebook keeps working,
which is why the baked-in default matters.

### Ingest API

One compressed batch per client per 15 minutes, ~1–3 KB of counters.

**The math:**

| | |
|---|---|
| 100k MAU, ~60% daily active | 60,000 clients/day |
| ~8 active hours → batches at 15min | ~32 batches/client/day |
| Total | **~1.9M requests/day** |
| Average | **~22 req/s** |
| Peak (US business hours, ~4× concentration) | **~90 req/s** |

That is one modest Go service behind a load balancer, on two small instances for
redundancy rather than for load. Not a scaling problem — an ordinary web service.

Design notes: accept batches idempotently (client-generated batch UUID, dedupe on
retry), respond 202 immediately and write async, and let clients queue offline batches
locally for up to 7 days.

### Storage

**Postgres** for identity and the things that need transactions: accounts, orgs,
memberships, licenses, admin policy, billing. Small — 100k users and their orgs is a
few hundred MB. One managed instance.

**ClickHouse** for counters:

| | |
|---|---|
| Client pre-aggregates to 15-min rollups | ~50 counter rows/user/day |
| 60k daily actives | **~3M rows/day** |
| Annual | ~1.1B rows |

Compressed columnar, that's tens of GB a year — trivial for ClickHouse. Materialized
views maintain per-user daily and per-org weekly rollups so the dashboard never scans raw
rows.

⚠️ **Postgres alone would strain within a year** at 3M inserts/day plus dashboard
aggregation. That said, **start on Postgres** with monthly partitions — at design-partner
scale it's fine, and it's one less system while the product is still changing. Migrate to
ClickHouse when daily rows pass ~500k, planned for Phase 4.

### Auth

- **Individuals:** email magic link, plus Sign in with Apple and Google.
- **Teams:** SAML/OIDC via **WorkOS**. Buy this. Building enterprise SSO is a quarter of
  engineering time that produces no product.
- **Devices:** short-lived JWT (24h) refreshed on heartbeat, so offboarding revokes
  within a day without a kill-switch mechanism.

### Updates and distribution

⚠️ **Not the Mac App Store.** The MAS sandbox effectively forbids the Accessibility API
this product is built on. That's a structural constraint, not a preference.

- **Developer ID signing + notarization**, stapled.
- **[Sparkle 2](https://sparkle-project.org/)** with an EdDSA-signed appcast.
- **Signed `.pkg`** for MDM deployment, plus a `.dmg` for direct download.
- Staged rollout support in the appcast — ship to 5%, watch crash rates, proceed.

### Dashboard

Next.js. Two surfaces:

1. **Personal** — your week, narrated by the goose. Shareable card export.
2. **Org admin** — aggregate adoption only, subject to the k-anonymity floor in
   [07](07-privacy-and-enterprise.md).

## Cost sketch at 100k MAU

| Item | Monthly |
|---|---|
| Ingest compute (2 small instances + LB) | ~$150 |
| CDN (rulebook + downloads) | ~$100 |
| Postgres (managed, HA) | ~$200 |
| ClickHouse (managed, small) | ~$400 |
| Auth (WorkOS, team tier only) | ~$300 |
| Error/crash reporting, logs, monitoring | ~$200 |
| Apple Developer Program | ~$8 |
| **Total** | **~$1,400/mo** |

Roughly **$0.014 per MAU per month**. At even $8/seat on a fraction of those users, infra
is a rounding error.

⚠️ **The dominant real cost is not infrastructure.** It's support, macOS version churn
(every annual release risks a TCC or windowing behavior change), and the animator. Budget
engineering time for a yearly macOS compatibility scramble as a fixed cost of being in
this category.

## What actually breaks first

Not throughput. In rough order of likelihood:

1. **Rulebook quality operations.** With hundreds of rules across locales and sites, you
   need authoring tooling, staged rollout per rule, and per-rule acceptance dashboards.
   This is the real scaling work and it's a *people and tooling* problem.
2. **Support volume.** Permission troubleshooting on macOS is genuinely confusing for
   users. At 100k MAU expect this to dominate headcount. Invest early in an in-app
   permissions diagnostic that tells people exactly what's wrong.
3. **macOS releases.** One TCC change can break detection for everyone at once. Keep a
   beta-OS test matrix from Phase 2 onward.
4. **Abuse of the ingest endpoint.** Anonymous counters invite garbage. Require a valid
   device JWT and rate-limit per device.
