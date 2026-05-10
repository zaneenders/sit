import CollectionsBenchmark
import Foundation
import Sit

// MARK: - Entry point

var benchmark = Benchmark(title: "Sit Benchmarks")
benchmark.registerSitBenchmarks()
benchmark.main()
