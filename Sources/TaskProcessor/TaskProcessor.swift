public struct Job: Sendable, Equatable {
    public let id: String
    public let input: Int

    public init(id: String, input: Int) {
        self.id = id
        self.input = input
    }
}

public enum JobOutcome: Sendable, Equatable {
    case succeeded(Int)
    case failed
    case cancelled
}

public struct JobResult: Sendable, Equatable {
    public let id: String
    public let outcome: JobOutcome

    public init(id: String, outcome: JobOutcome) {
        self.id = id
        self.outcome = outcome
    }
}

public enum TaskProcessorError: Error, Equatable {
    case nonPositiveMaximumConcurrency
    case duplicateID(String)
}

public actor TaskProcessor {
    private let maximumConcurrency: Int
    
    public init(maximumConcurrency: Int) throws {
        guard maximumConcurrency > 0 else {
            throw TaskProcessorError.nonPositiveMaximumConcurrency
        }
        self.maximumConcurrency = maximumConcurrency
    }

    public func process(
        _ jobs: [Job],
        worker: @escaping @Sendable (Job) async throws -> Int
    ) async throws -> [JobResult] {
        var seenIDs = Set<String>()

        for job in jobs {
            guard seenIDs.insert(job.id).inserted else {
                throw TaskProcessorError.duplicateID(job.id)
            }
        }
        guard !jobs.isEmpty else {
            return []
        }
        
        let perform: @Sendable (Job, Int) async -> (Int, JobOutcome) = { job, index in
            do {
                let value = try await worker(job)
                return (index, .succeeded(value))
            } catch is CancellationError {
                return (index, .cancelled)
            } catch {
                return (index, .failed)
            }
        }

        return await withTaskGroup(of: (Int, JobOutcome).self) { group in
            var outcomes = Array<JobOutcome?>(
                repeating: nil,
                count: jobs.count
            )
            var nextIndex = 0
            
            while nextIndex < min(maximumConcurrency, jobs.count) && !Task.isCancelled {
                let index = nextIndex
                let job = jobs[index]
                nextIndex += 1
                
                group.addTask {
                    await perform(job, index)
                }
            }
            
            if Task.isCancelled {
                group.cancelAll()
            }
            
            while let (index, outcome) = await group.next() {
                outcomes[index] = outcome
                
                if Task.isCancelled {
                    group.cancelAll()
                } else if nextIndex < jobs.count {
                    let newIndex = nextIndex
                    let newJob = jobs[newIndex]
                    nextIndex += 1
                    
                    group.addTask {
                        await perform(newJob, newIndex)
                    }
                }
            }
            
            return jobs.enumerated().map { index, job in
                JobResult(
                    id: job.id,
                    outcome: outcomes[index] ?? .cancelled
                )
            }
        }
    }
}
