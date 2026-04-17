# Route pins

> This document replaces the original Russian design note. The mechanism
> described here is implemented in
> [`hg_route`](../apps/routing/src/hg_route.erl) and
> [`hg_routing`](../apps/routing/src/hg_routing.erl) (see
> `gather_pin_info/2`, `select_better_route/2`,
> `select_better_pinned_route/2`).

## The problem

Consider a payment institution with three equal-priority routes sharing the
same weight — `33 : 33 : 33`. A payer arrives, pays for some service, and the
payment ends up going through, say, the second route. We would like every
*subsequent* payment from the same payer to reach the same route, without
pinning the *other* payers to it.

Naïvely re-randomising the weight on every payment would move returning
payers around between routes. Assigning a sticky route globally per merchant
would destroy the load split the merchant chose. Pins solve the problem at a
finer granularity: the *payer* (identified by a configurable set of features)
is stuck to whichever equal-priority candidate it first ended up on.

## The mechanism

Each route candidate in the domain can declare a
`#domain_RoutingPin{features = [...]}` — a set of payer characteristics the
candidate considers "identifying". The features currently recognised by
Hellgate are:

| Feature        | Source                                            |
| -------------- | ------------------------------------------------- |
| `currency`     | payment currency                                  |
| `payment_tool` | the full payment tool (card BIN, wallet, etc.)   |
| `client_ip`    | payer's IP address (may be `undefined`)          |
| `email`        | payer's email (may be `undefined`)               |
| `card_token`   | tokenised card identifier (may be `undefined`)   |

At routing time `hg_routing:gather_pin_info/2` walks the declared features
for the candidate and extracts their current values from the routing
context. The result is a plain map `#{feature => value}` which travels
along with the candidate as its `pin` (see
[`hg_route:pin/1`](../apps/routing/src/hg_route.erl)).

During scoring, Hellgate sorts equal-priority candidates by
`#domain_PaymentRouteScores{}`. The critical hook is in
[`hg_routing:select_better_route/2`](../apps/routing/src/hg_routing.erl):

```erlang
case {LeftPin, RightPin} of
    _ when LeftPin /= ?ZERO, RightPin /= ?ZERO, RightPin == LeftPin ->
        select_better_pinned_route(Left, Right);
    _ ->
        select_better_regular_route(Left, Right)
end
```

When two candidates carry the same pin value and that value is not the
zero sentinel (meaning they saw an identical payer fingerprint), the
regular weight-based random tie-break is replaced with a deterministic
one:

```erlang
route_pin = erlang:phash2({Pin, hg_route:provider_ref(Route),
                                 hg_route:terminal_ref(Route)})
```

Because the pin value is shared, the only thing that differs between the
two hashes is `(provider_ref, terminal_ref)`. The `phash2` output is
stable across time and processes, so the *same* payer always picks the
*same* winner — exactly what the requirement asks for.

Candidates whose feature sets do not overlap participate in their own
pinning group (their pin values differ, so the `RightPin == LeftPin`
clause never fires and they fall back to the normal random tie-break).

## Worked example

Three candidates A, B, C at the same priority with weights `33 : 33 : 33`.

- If all three declare the feature set `{email}` and a payer with a fixed
  email arrives, all three end up with identical `Pin` values. The
  deterministic `phash2({Pin, P, T})` picks exactly one winner for that
  email, so the effective distribution for that payer is
  `100 : 0 : 0` — but a different email (or an unknown email) will pin
  to a potentially different candidate. The aggregate split across the
  population is still close to `33 : 33 : 33`.

- If A and B declare `{email}` while C declares `{email, client_ip}`, the
  `Pin` of C differs from that of A and B (unless by coincidence the IP
  is absent for all payers, which is rare). A and B form one pin group;
  C forms its own. For a given payer the collapse looks like `50 : 50 : ?`
  within the first group and a separate pinning decision for C — hence
  the "`66 : 0 : 33` → pin kicks in → `0 : 100 : 0` for A/B, C decided
  independently" pattern.

## Flow

```mermaid
flowchart LR
    Route[Candidate with<br/>#domain_RoutingPin{features=...}] --> GP[gather_pin_info/2]
    VS[Routing context<br/>currency, email, ip, tool, token] --> GP
    GP --> P[pin :: #{feature => value}]
    P --> SCORE[score_routes]
    SCORE --> SEL{pins equal<br/>and non-zero?}
    SEL -- yes --> DET[select_better_pinned_route<br/>phash2 Pin,P,T]
    SEL -- no --> REG[select_better_regular_route<br/>weight-based random]
    DET --> WIN([winner])
    REG --> WIN
```

## Practical notes

> [!NOTE]
> A feature that is `undefined` in the routing context still contributes
> to the pin value — two candidates that both declare `{email, ip}` with
> `ip = undefined` are considered equivalent for pinning purposes. This
> is intentional: the absence of a signal is itself a signal.

> [!IMPORTANT]
> Pins only break ties *within* an equal-priority, equal-weight group.
> They do not override fault-detector rejection, blacklist rejection,
> limit overflow or priority ordering. A dead provider is still dead even
> if the payer is "pinned" to it.

> [!TIP]
> The explanation rendered by
> [`hg_routing_explanation`](../apps/routing/src/hg_routing_explanation.erl)
> surfaces a `"Pin wasn't the same as in chosen route"` message when pins
> participated in the decision — useful when debugging why an expected
> route was not taken.
