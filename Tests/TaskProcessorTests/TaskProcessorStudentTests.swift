import XCTest
@testable import TaskProcessor

private actor WorkerCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func currentCount() -> Int {
        count
    }
}

private actor ActiveWorkers {
    private var active = 0
    private var maximumObserved = 0
    private var totalStarts = 0

    func started() {
        active += 1
        totalStarts += 1
        maximumObserved = max(maximumObserved, active)
    }

    func finished() {
        active -= 1
    }

    func snapshot() -> (Int, Int) {
        (maximumObserved, totalStarts)
    }
}

@MainActor
final class TaskProcessorStudentTests: XCTestCase {

    func testNegativeMaximumConcurrencyIsRejected() {
        XCTAssertThrowsError(
            try TaskProcessor(maximumConcurrency: -2)
        ) { error in
            XCTAssertEqual(
                error as? TaskProcessorError,
                .nonPositiveMaximumConcurrency
            )
        }
    }

    func testFirstDuplicateIDRejectedBeforeWorkerStarts() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let counter = WorkerCounter()

        let jobs = [
            Job(id: "A", input: 1),
            Job(id: "B", input: 2),
            Job(id: "A", input: 3),
            Job(id: "B", input: 4)
        ]

        do {
            _ = try await processor.process(jobs) { _ in
                await counter.increment()
                return 42
            }
            XCTFail("Expected a duplicate ID error")
        } catch {
            XCTAssertEqual(
                error as? TaskProcessorError,
                .duplicateID("A")
            )
        }
        let workerCalls = await counter.currentCount()
        XCTAssertEqual(workerCalls, 0)
    }
    
    
    func testMaximumConcurrencyNeverExceededAndAllJobsRun() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let tracker = ActiveWorkers()

        let jobs = (0..<12).map {
            Job(id: "job-\($0)", input: $0)
        }

        let results = try await processor.process(jobs) { job in
            await tracker.started()
            await Task.yield()
            await tracker.finished()

            return job.input * 2
        }

        let (maximumObserved, totalStarts) = await tracker.snapshot()

        XCTAssertLessThanOrEqual(maximumObserved, 2)
        XCTAssertEqual(totalStarts, jobs.count)

        XCTAssertEqual(
            results,
            jobs.map {
                JobResult(id: $0.id, outcome: .succeeded($0.input * 2))
            }
        )
    }
    
    
    func testWorkerCancellationErrorDoesNotStopLaterJobs() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)

        let jobs = [
            Job(id: "first", input: 0),
            Job(id: "second", input: 5)
        ]

        let results = try await processor.process(jobs) { job in
            if job.input == 0 {
                throw CancellationError()
            }
            return job.input * 3
        }

        XCTAssertEqual(
            results,
            [
                JobResult(id: "first", outcome: .cancelled),
                JobResult(id: "second", outcome: .succeeded(15))
            ]
        )
    }
    
    func testCallerCancellationStopsQueuedJobs() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let jobs = (1...4).map {
            Job(id: "job-\($0)", input: $0)
        }

        let (starts, signal) = AsyncStream<String>.makeStream()

        let processing = Task {
            try await processor.process(jobs) { job in
                signal.yield(job.id)
                try await Task.sleep(for: .seconds(30))
                return job.input
            }
        }

        var iterator = starts.makeAsyncIterator()

        let first = await iterator.next()
        let second = await iterator.next()

        processing.cancel()

        let results = try await processing.value

        signal.finish()
        let extra = await iterator.next()

        XCTAssertEqual(
            Set([first, second].compactMap { $0 }),
            Set(["job-1", "job-2"])
        )
        XCTAssertNil(extra)

        XCTAssertEqual(
            results,
            jobs.map {
                JobResult(id: $0.id, outcome: .cancelled)
            }
        )
    }
    
    private enum CancellationTestError: Error {
        case expected
    }
    
    func testCancellationKeepsCompletedResults() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)

        let jobs = [
            Job(id: "success", input: 1),
            Job(id: "failure", input: 2),
            Job(id: "running", input: 3),
            Job(id: "queued", input: 4)
        ]
        let (starts, signal) = AsyncStream<String>.makeStream()

        let processing = Task {
            try await processor.process(jobs) { job in
                signal.yield(job.id)

                switch job.id {
                case "success":
                    return 99
                case "failure":
                    throw CancellationTestError.expected
                default:
                    try await Task.sleep(for: .seconds(30))
                    return job.input
                }
            }
        }
        var iterator = starts.makeAsyncIterator()

        let first = await iterator.next()
        let second = await iterator.next()
        let third = await iterator.next()

        XCTAssertEqual(
            [first, second, third].compactMap { $0 },
            ["success", "failure", "running"]
        )
        processing.cancel()

        let results = try await processing.value

        signal.finish()
        let extra = await iterator.next()

        XCTAssertNil(extra)

        XCTAssertEqual(results, [
            JobResult(id: "success", outcome: .succeeded(99)),
            JobResult(id: "failure", outcome: .failed),
            JobResult(id: "running", outcome: .cancelled),
            JobResult(id: "queued", outcome: .cancelled)
        ])
    }
}
