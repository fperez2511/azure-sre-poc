using System.Net;
using Microsoft.Azure.Cosmos;
using Polly;
using Polly.CircuitBreaker;
using Polly.Timeout;

namespace Coaching.Api.Resilience;

/// <summary>
/// Self-preservation around the Cosmos DB dependency (WAF RE:07):
///
///   request ──► [circuit breaker] ──► [3 s timeout] ──► Cosmos DB SDK (its own retries for 429/transient)
///
/// - Timeout: a user should get an answer (even "try again later") within a few seconds.
/// - Circuit breaker: when most recent calls fail, stop calling for 15 s. This protects the
///   dependency while it recovers, frees threads/sockets in the app, and turns 5-second
///   timeouts into instant 503s. Watch it open and close in the logs during Lab 5.
/// </summary>
public static class DependencyResilience
{
    public static readonly TimeSpan OperationTimeout = TimeSpan.FromSeconds(3);

    public static ResiliencePipeline Build(ILogger logger) =>
        new ResiliencePipelineBuilder()
            .AddCircuitBreaker(new CircuitBreakerStrategyOptions
            {
                FailureRatio = 0.5,
                MinimumThroughput = 8,
                SamplingDuration = TimeSpan.FromSeconds(30),
                BreakDuration = TimeSpan.FromSeconds(15),
                ShouldHandle = new PredicateBuilder()
                    .Handle<TimeoutRejectedException>()
                    .Handle<HttpRequestException>()
                    .Handle<CosmosException>(IsDependencyFault),
                OnOpened = args =>
                {
                    logger.LogError(
                        "Circuit OPENED for Cosmos DB for {BreakSeconds}s after repeated failures: {Reason}",
                        args.BreakDuration.TotalSeconds,
                        args.Outcome.Exception?.GetType().Name ?? "unknown");
                    return default;
                },
                OnHalfOpened = _ =>
                {
                    logger.LogWarning("Circuit HALF-OPEN for Cosmos DB: sending a trial request");
                    return default;
                },
                OnClosed = _ =>
                {
                    logger.LogInformation("Circuit CLOSED for Cosmos DB: dependency healthy again");
                    return default;
                },
            })
            .AddTimeout(OperationTimeout)
            .Build();

    /// <summary>Errors that mean "the dependency is unhealthy" (as opposed to "your request was wrong").</summary>
    public static bool IsDependencyFault(CosmosException ex) =>
        (int)ex.StatusCode >= 500
        || ex.StatusCode == HttpStatusCode.RequestTimeout
        || ex.StatusCode == HttpStatusCode.TooManyRequests;

    /// <summary>True when an exception should surface to the client as 503 + Retry-After.</summary>
    public static bool IsTransientFailure(Exception ex) => ex switch
    {
        BrokenCircuitException => true,
        TimeoutRejectedException => true,
        HttpRequestException => true,
        CosmosException cosmos => IsDependencyFault(cosmos),
        _ => false,
    };
}
