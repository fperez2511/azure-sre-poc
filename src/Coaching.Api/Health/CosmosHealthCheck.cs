using Coaching.Api.Data;
using Microsoft.Azure.Cosmos;
using Microsoft.Extensions.Diagnostics.HealthChecks;

namespace Coaching.Api.Health;

/// <summary>
/// Dependency check exposed at /healthz/deps for humans, dashboards and SRE Agent.
///
/// It is NOT wired to the readiness or liveness probe on purpose: if Cosmos DB is down,
/// restarting or de-routing every replica cannot fix it, and doing so would also take
/// down the parts of the API that still work (the cached catalog).
/// </summary>
public sealed class CosmosHealthCheck(CosmosClient client, CosmosSettings settings) : IHealthCheck
{
    public async Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken cancellationToken = default)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(3));

        try
        {
            var response = await client.GetDatabase(settings.DatabaseName).ReadAsync(cancellationToken: timeout.Token);
            return HealthCheckResult.Healthy(
                $"Cosmos DB reachable ({response.Diagnostics.GetClientElapsedTime().TotalMilliseconds:F0} ms)");
        }
        catch (Exception ex)
        {
            return HealthCheckResult.Unhealthy("Cosmos DB unreachable", ex);
        }
    }
}
