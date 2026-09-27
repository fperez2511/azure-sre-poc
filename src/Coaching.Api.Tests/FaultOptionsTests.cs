using Coaching.Api.Chaos;
using Coaching.Api.Resilience;
using Microsoft.Extensions.Configuration;
using Polly.CircuitBreaker;
using Polly.Timeout;

namespace Coaching.Api.Tests;

public class FaultOptionsTests
{
    private static IConfiguration Config(params (string Key, string Value)[] values) =>
        new ConfigurationBuilder()
            .AddInMemoryCollection(values.Select(v => new KeyValuePair<string, string?>(v.Key, v.Value)))
            .Build();

    [Fact]
    public void Defaults_are_off()
    {
        var options = FaultOptions.FromConfiguration(Config());
        Assert.False(options.Enabled);
        Assert.False(options.CrashOnStartup);
    }

    [Fact]
    public void Values_are_parsed_and_clamped()
    {
        var options = FaultOptions.FromConfiguration(Config(
            ("FAULT_LATENCY_MS", "999999"),
            ("FAULT_ERROR_RATE", "1.5"),
            ("FAULT_CRASH_ON_STARTUP", "true")));

        Assert.Equal(30_000, options.LatencyMs);
        Assert.Equal(1.0, options.ErrorRate);
        Assert.True(options.CrashOnStartup);
        Assert.True(options.Enabled);
    }

    [Fact]
    public void Dependency_failures_map_to_503_but_bugs_do_not()
    {
        Assert.True(DependencyResilience.IsTransientFailure(new TimeoutRejectedException()));
        Assert.True(DependencyResilience.IsTransientFailure(new BrokenCircuitException()));
        Assert.True(DependencyResilience.IsTransientFailure(new HttpRequestException("connect timeout")));
        Assert.False(DependencyResilience.IsTransientFailure(new PricingEngineException("bug")));
        Assert.False(DependencyResilience.IsTransientFailure(new InvalidOperationException()));
    }
}
