# Implementation Plan

Complete this before implementation and update it when the plan changes.

## Approach

I will implement the base `TaskProcessor` API first and leave the optional retry extension until the base implementation and
tests pass.

1. Validate inputs before starting work - the initializer will reject a `maximumConcurrency` of zero or less. At the start of `process`, I will scan job IDs from left to right with a `Set<String>`. I will throw `duplicateID` for the first repeated ID before creating any worker tasks. Empty input will return empty array
2. Use bounded structured concurrency - I will use a `withTaskGroup` to run up to `min(maximumConcurrency, jobs.count)` child tasks initially. Each child task will run the injected worker for one job and return its original array index together with its outcome. When one task finishes, I will schedule the next unstarted job in input order, provided cancellation has not been observed
3. Preserve input ordering - I will maintain indexed result storage instead of appending results in completion order. After all started children have finished, I will produce exactly one `JobResult` per input job in its original position.
4. Convert worker outcomes - successful integer returns become `.succeeded(value)`. Ordinary thrown errors become `.failed`. A thrown `CancellationError` becomes `.cancelled`. An individual worker's cancellation doesnt stop other jobs unless the caller's task has been cancelled.
5. Handle cancellation cooperatively - at each scheduling decision I will check `Task.isCancelled`. If cancellation is observed, I will call `group.cancelAll()`, refrain from starting any further workers, and mark all never-started jobs `.cancelled`. I will still collect outcomes from already-started child tasks

## Milestones

- [x] Validate configuration and all job IDs before starting work.
- [x] Schedule jobs within the concurrency limit and preserve input order.
- [x] Map success, ordinary errors, and cancellation outcomes.
- [ ] Handle caller cancellation and never-started jobs.
- [ ] Add at least six distinct student-authored tests and run `swift test`.
- [ ] Review the final diff and document AI assistance in `AGENT_WORKLOG.md`.

## Risks and checks

- **Invalid configuration:** test both zero and negative concurrency limits
- **Duplicate IDs:** verify that the first repeated ID is reported and no worker runs, even if earlier jobs were valid
- **Bounded scheduling:** use an actor-based test probe or explicit continuation gates to prove that no more than the configured number of workers are active and that a new job starts when a slot is freed
- **Unpredictable completion order:** deliberately release jobs in a different order and verify that IDs and outcomes are returned in input order
- **Error mapping:** test ordinary errors and `CancellationError` separately; verify that other jobs continue
- **Caller cancellation:** use deterministic gates to cancel while workers are active, confirm that no queued job starts, and verify that never-started jobs are `.cancelled`
- **Race conditions and deadlocks:** keep mutable scheduling state local to the `process` invocation and avoid shared mutable state, blocking waits, locks, and timing-based assertions. Use structured concurrency for child-task lifetime and cancellation
