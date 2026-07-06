# Findings — advice to a new taxi driver

Based on **7 months of 2023 (Jan–Jul), 21,960,301 valid trips** after cleaning.
Metric of merit is **median driver revenue = fare + tip** and **$/occupied-hour**
(excludes idle time, so it ranks opportunities rather than predicting take-home
pay). Queries + result tables: [`analysis/queries.sql`](../analysis/queries.sql);
charts: [`analysis/driver_earnings_analysis.ipynb`](../analysis/driver_earnings_analysis.ipynb).

## TL;DR playbook

1. **Work early mornings and evenings, not the midday rush.** Weekday **4–5am
   pays ~$115/occupied-hr** vs **~$76 mid-afternoon** — because median speed
   collapses from ~19 mph overnight to **~8 mph** midday. The busiest hours are
   the *worst*-paid per hour. (Q6)
2. **Prioritize card riders / expect nothing from cash.** Card trips tip **~22%
   of fare (pooled) and 95.5% leave a tip**; recorded cash tips are **$0.00**.
   Cash isn't stingy — the meter just doesn't capture cash tips. Judge "tip
   zones" on card data only. (Q1, Q7)
3. **Take the airport run.** A **JFK pickup pays a median $77** vs **$15.30** for
   a normal trip, and still holds **~$108/hr**; **LaGuardia ~$109/hr**. Even after
   a ~30–45 min empty return to Manhattan, one airport fare beats 2–3 city trips.
   Among airports, LGA tips best (~23%). (Q4)
4. **Chase quick hops or long hauls — skip the 2–5 mile "dead zone."** Earnings
   per hour is U-shaped: **<1 mi = $97/hr** (and best $/mile at $12.47),
   **2–3 mi = $76/hr (worst)**, **20+ mi = $112/hr**. Mid-distance trips are the
   least efficient use of your time. (Q5)
5. **Position in Upper/Lower Manhattan + Queens airports.** Highest $/hr
   high-volume pickup zones: East Elmhurst, LaGuardia & JFK (~$108–110), then
   Manhattan Yorkville (~$90–92), Battery Park City, Financial District, Upper
   West Side (~$88). (Q2, Q3)

## The "huh, I didn't think of that" angles

- **Peak demand is a trap.** Intuition says drive when the city is busiest;
  the data says those exact hours (8am–5pm) earn the *least* per hour because you
  spend them stuck in traffic at ~8 mph. Your enemy isn't empty streets — it's
  slow ones.
- **"Cash = no tip" is a data artifact, not rider behavior.** Any tipping
  analysis that includes cash will wrongly conclude ~40% of riders never tip.
- **The tip leaderboard can lie if you average ratios.** Averaging per-trip
  `tip/fare` makes tiny-fare outliers (a $0.01 fare with a normal tip) explode to
  thousands of percent, falsely crowning zones like "Newark 2440%." The honest
  rate is **pooled `SUM(tip)/SUM(fare)`**, which puts every zone at a sane ~16–25%.
  (This bug only surfaced once the data grew past a single clean month.)
- **Newark "pickups" don't exist.** The mart shows a few hundred Newark-Airport
  *pickups* with 0 miles and nonsensical $/hr — yellow cabs can't legally pick up
  in NJ. These are miscoded rows a naive dashboard would surface as the "best"
  zone. (Handled/flagged — see README §Data quality.)
- **Watch where you *end up*.** **~89% of dropoffs are in Manhattan**, so most
  trips self-replenish near demand. The costly trips are Staten Island / far-Bronx
  / EWR dropoffs: good fares, but you likely drive back empty. Factor the return
  leg. (Q8)

## Caveats (honest limits)

- `$/occupied-hour` ignores idle/cruising time between fares, so real take-home
  is lower; it's a ranking signal, not a wage. Trip volume is used as the
  stay-busy proxy. The very top of `best_slots` skews toward short-hop zones
  (e.g. park/attraction pickups) where a couple-minute trip inflates $/hr — read
  it alongside volume.
- Deadhead (empty return) isn't directly measured — inferred from dropoff
  geography. A shift-level simulation matching each dropoff to the next pickup
  would sharpen the airport and outer-borough advice.
- Seven months (Jan–Jul 2023). The pipeline is built to accumulate 5 years, which
  will expose the seasonality (weather, holidays, summer airport surges) this
  window can't fully show.
