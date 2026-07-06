// Shared helpers. Files in includes/ are available in .sqlx by filename,
// e.g. constants.sourceMonthFilter().

// The month the orchestrator is loading, injected as a compile var (YYYY-MM).
// Empty string => process everything (initial full build / backfill).
const TARGET_MONTH =
  (dataform.projectConfig.vars && dataform.projectConfig.vars.target_month) || "";

// Airport LocationIDs: EWR (Newark) = 1, JFK = 132, LaGuardia = 138.
const AIRPORT_IDS = "(1, 132, 138)";

// Filter bronze to just the loaded month's partition (partition pruning).
function sourceMonthFilter() {
  return TARGET_MONTH ? `_source_month = DATE '${TARGET_MONTH}-01'` : `TRUE`;
}

// Bound the incremental MERGE to the affected silver partitions (cost control).
// Dataform prepends the target alias to ONLY the first token of this predicate,
// so it must START with the partition column and reference it exactly once —
// hence BETWEEN ... LAST_DAY (not a two-bound range, not a function-first form).
function updatePartitionFilter() {
  return TARGET_MONTH
    ? `pickup_date BETWEEN DATE '${TARGET_MONTH}-01' AND LAST_DAY(DATE '${TARGET_MONTH}-01')`
    : `pickup_date IS NOT NULL`;
}

module.exports = {
  TARGET_MONTH,
  AIRPORT_IDS,
  sourceMonthFilter,
  updatePartitionFilter,
};
