-- =====================================================================
-- NYC Yellow Taxi — Driver Earnings Analysis
-- =====================================================================
-- Standalone, copy-paste-runnable BigQuery queries. Replace `PROJECT` with
-- your project id. The gold.* tables are built by Dataform; these queries
-- either read those marts directly or run equivalent ad-hoc logic on silver.
--
-- All result snippets below are REAL output from 7 months of 2023 (Jan-Jul,
-- 21,960,301 valid trips). "$/hr" = median driver revenue (fare + tip) per
-- OCCUPIED hour — it excludes idle/cruising time, so treat it as an
-- upper-bound ranking signal, not a take-home wage.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Q1. The single biggest tipping insight: cash tips are invisible.
--     -> Tell the driver: card riders tip; "cash trip" ~= "no recorded tip".
-- ---------------------------------------------------------------------
SELECT payment_method, trips, pct_of_trips, avg_tip_amount,
       avg_tip_pct_of_fare, pct_trips_with_tip
FROM `PROJECT.taxi_gold.tipping_by_payment`
ORDER BY trips DESC;
/* Result (avg_tip_pct_of_fare = pooled SUM(tip)/SUM(fare), robust to tiny fares):
 payment_method | trips      | pct_of_trips | avg_tip_amount | avg_tip_pct_of_fare | pct_trips_with_tip
 Credit card    | 17,452,823 | 79.5         | 4.312          | 22.28               | 95.5
 Cash           |  3,697,427 | 16.8         | 0.000          | 0.00                | 0.0
 Unrecorded(0)  |    606,921 |  2.8         | 3.545          | 15.92               | 80.1
 Dispute        |    126,452 |  0.6         | 0.027          | 0.14                | 0.2
 No charge      |     76,676 |  0.3         | 0.009          | 0.05                | 0.2
*/


-- ---------------------------------------------------------------------
-- Q2. Best pickup zones by median $/occupied-hour (high-volume only).
--     -> Airports + Lower/Upper Manhattan dominate.
-- ---------------------------------------------------------------------
SELECT pu_zone, pu_borough,
       SUM(trips) AS trips,
       ROUND(APPROX_QUANTILES(median_earnings_per_hour, 100)[OFFSET(50)], 2) AS approx_med_eph
FROM `PROJECT.taxi_gold.zone_hour_earnings`
GROUP BY pu_zone, pu_borough
HAVING trips >= 5000
ORDER BY approx_med_eph DESC
LIMIT 12;
/* Result top rows (7 months):
 East Elmhurst (Queens)              95,151   ~110
 LaGuardia Airport (Queens)         741,620   ~109
 JFK Airport (Queens)             1,120,840   ~108
 Yorkville West/East (Manhattan)             ~90-92
 Battery Park City (Manhattan)      125,748    ~90
 Financial District N/S (Manhattan)          ~88
 Upper West Side North (Manhattan)  425,459    ~88
*/


-- ---------------------------------------------------------------------
-- Q3. Driver playbook: the highest-earning (zone, hour) slots.
-- ---------------------------------------------------------------------
SELECT eph_rank, pu_zone, pu_borough, pickup_hour, trips,
       median_earnings_per_hour, median_driver_revenue
FROM `PROJECT.taxi_gold.best_slots`
ORDER BY eph_rank
LIMIT 15;
/* Result (top, 7 months): short-hop zones lead on $/occupied-hr — Flushing
   Meadows-Corona Park hours 6/9/23 at ~$220-235/hr median (a few-minute trip
   inflates $/hr; read alongside volume). Airport hours + Manhattan cores follow. */


-- ---------------------------------------------------------------------
-- Q4. Airport economics: per-trip vs per-hour, with the deadhead caveat.
-- ---------------------------------------------------------------------
SELECT segment, trips, avg_driver_revenue, median_driver_revenue,
       median_earnings_per_hour, median_trip_minutes, median_trip_miles,
       avg_card_tip_pct
FROM `PROJECT.taxi_gold.airport_economics`
ORDER BY median_driver_revenue DESC;
/* Result (7 months; card_tip% = pooled SUM(tip)/SUM(fare)):
 segment              trips        med_rev  med_eph   card_tip%
 Newark pickup             488     105.25   264.90    16.4     <- DATA ARTIFACT (see README DQ)
 JFK pickup          1,120,840      77.00   107.65    18.5
 LaGuardia pickup      741,620      50.80   109.00    23.4
 Non-airport        20,097,353      15.30    82.66    23.0
 -> A JFK trip pays ~5x a normal trip AND holds ~$108/hr. Even after a ~30-45 min
    empty return to Manhattan, one airport run beats ~2-3 normal trips. */


-- ---------------------------------------------------------------------
-- Q5. Short vs long trips: the U-shaped earnings curve.
-- ---------------------------------------------------------------------
SELECT distance_band, trips, pct_of_trips, median_driver_revenue,
       median_earnings_per_hour, median_dollars_per_mile, median_dollars_per_minute
FROM `PROJECT.taxi_gold.trip_length_economics`
ORDER BY median_earnings_per_hour;
/* Result (7 months, ordered by $/hr):
 band     trips      med_eph  $/mile
 2-3 mi   3,531,747   76.00    7.73   <- WORST per hour
 3-5 mi   2,566,033   77.14    6.70
 1-2 mi   7,152,862   80.61    9.24
 5-10 mi  1,926,545   94.04    5.46
 0-1 mi   4,719,287   96.63   12.47   <- best $/mile
 10-20 mi 1,670,814  106.51    4.78
 20+ mi     244,413  112.07    4.07   <- best $/hour
 -> Quick hops (<1 mi) and long hauls (10+ mi) both beat the 2-5 mi "dead zone". */


-- ---------------------------------------------------------------------
-- Q6. Rush-hour paradox: most demand != most money (traffic kills $/hr).
-- ---------------------------------------------------------------------
SELECT pickup_hour, trips, median_earnings_per_hour, median_mph, median_driver_revenue
FROM `PROJECT.taxi_gold.hourly_pulse`
WHERE is_weekend = FALSE
ORDER BY pickup_hour;
/* Result highlights (weekday):
 hour  trips     med_eph  med_mph
 04     50,692   115.20   18.8   <- best $/hr, empty roads
 05     94,859   114.19   17.4
 09    755,426    79.07    8.6   <- high demand, low $/hr (crawl)
 15    997,383    75.64    8.2   <- peak demand, WORST $/hr
 23    640,972    92.79   12.6
 -> 8am-5pm has the most trips but the lowest $/hr because median speed
    collapses to ~8 mph. Early morning is the sweet spot. */


-- ---------------------------------------------------------------------
-- Q7. Best-tipping pickup zones (CARD ONLY — cash would bias this).
-- ---------------------------------------------------------------------
SELECT pu_zone, pu_borough, card_trips, avg_tip_pct_of_fare, median_tip_amount
FROM `PROJECT.taxi_gold.top_tip_zones`
ORDER BY avg_tip_pct_of_fare DESC
LIMIT 10;
/* Result (pooled tip rate, card only, 7 months): Upper East Side South 24.7%,
   Upper West Side South 24.5%, Lincoln Square East 24.3%, Upper East Side North
   24.1%, Greenwich Village North 24.0%, Midtown Center 23.9%. (The single-month
   "LaGuardia 43.6%" was an average-of-ratios artifact — see README DQ.) */


-- ---------------------------------------------------------------------
-- Q8. Ad-hoc "surprise" angle: the empty-return risk by dropoff borough.
--     Where do rides END up? Dropoffs far from demand = dead miles home.
--     (Runs directly on silver.)
-- ---------------------------------------------------------------------
SELECT z.borough AS do_borough,
       COUNT(*) AS dropoffs,
       ROUND(COUNT(*) / SUM(COUNT(*)) OVER () * 100, 1) AS pct,
       ROUND(APPROX_QUANTILES(f.driver_revenue, 100)[OFFSET(50)], 2) AS median_revenue
FROM `PROJECT.taxi_gold.fact_trip` f
LEFT JOIN `PROJECT.taxi_gold.dim_zone` z ON f.do_location_id = z.location_id
GROUP BY do_borough
ORDER BY dropoffs DESC;
/* -> ~89% of dropoffs are in Manhattan (5% Queens, 4% Brooklyn), so most trips
   self-replenish. Watch Staten Island / far Bronx / EWR dropoffs: high fare,
   but you likely drive back empty. Factor the return leg into "is it worth it". */
