namespace Coaching.Api.Chaos;

/// <summary>
/// Application-level fault injection, driven by environment variables.
///
/// Azure Chaos Studio has no native faults for Container Apps, so these switches let us
/// reproduce the most common real-world incident of all: a bad release. Changing an
/// environment variable on a container app creates a NEW REVISION, which is exactly what a
/// real deployment looks like to Azure Monitor, the Activity Log and Azure SRE Agent.
///
///   FAULT_LATENCY_MS        extra delay on every /api request (e.g. 2500)
///   FAULT_ERROR_RATE        fraction of /api requests that throw (0.0 – 1.0)
///   FAULT_CRASH_ON_STARTUP  true = the process exits during startup (broken release)
///
/// Use scripts/inject-fault.sh instead of setting these by hand.
/// </summary>
public sealed record FaultOptions
{
    public int LatencyMs { get; init; }
    public double ErrorRate { get; init; }
    public bool CrashOnStartup { get; init; }

    public bool Enabled => LatencyMs > 0 || ErrorRate > 0;

    public static FaultOptions FromConfiguration(IConfiguration config) => new()
    {
        LatencyMs = Math.Clamp(config.GetValue("FAULT_LATENCY_MS", 0), 0, 30_000),
        ErrorRate = Math.Clamp(config.GetValue("FAULT_ERROR_RATE", 0.0), 0.0, 1.0),
        CrashOnStartup = config.GetValue("FAULT_CRASH_ON_STARTUP", false),
    };
}

/// <summary>
/// The exception thrown by the error-rate fault. It is intentionally written like a real
/// defect so the investigation (by you or by SRE Agent) has to rely on evidence – which
/// revision started failing and what changed in it – rather than on a log line saying "chaos".
/// </summary>
public sealed class PricingEngineException(string message) : Exception(message);

public sealed class FaultInjectionMiddleware(RequestDelegate next, FaultOptions options)
{
    public async Task InvokeAsync(HttpContext context)
    {
        if (options.Enabled && context.Request.Path.StartsWithSegments("/api"))
        {
            if (options.LatencyMs > 0)
            {
                await Task.Delay(options.LatencyMs, context.RequestAborted);
            }

            if (options.ErrorRate > 0 && Random.Shared.NextDouble() < options.ErrorRate)
            {
                throw new PricingEngineException(
                    "Pricing rules engine returned no rate card for the requested market (rateCard == null).");
            }
        }

        await next(context);
    }
}
