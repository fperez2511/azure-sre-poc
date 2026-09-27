using Coaching.Api.Resilience;
using Coaching.Api.Telemetry;
using Microsoft.Azure.Cosmos;
using Polly;

namespace Coaching.Api.Data;

/// <summary>
/// Read path for the service catalog with graceful degradation (WAF: "design for resilience").
///
/// The catalog changes rarely, so we keep the last good copy in memory. If Cosmos DB is
/// unavailable we keep serving that copy and flag it as stale, instead of failing the
/// "browse offerings" flow. Bookings (the write path) cannot be served from a cache, so
/// they fail fast with 503 instead – see <see cref="BookingStore"/>.
/// </summary>
public sealed class OfferingCatalog
{
    private static readonly TimeSpan FreshFor = TimeSpan.FromMinutes(2);

    private readonly Container _container;
    private readonly ResiliencePipeline _pipeline;
    private readonly TimeProvider _time;
    private readonly ILogger<OfferingCatalog> _logger;
    private volatile Snapshot? _snapshot;

    private sealed record Snapshot(IReadOnlyList<Offering> Items, DateTimeOffset FetchedAtUtc);

    public OfferingCatalog(
        CosmosClient client,
        CosmosSettings settings,
        ResiliencePipeline pipeline,
        TimeProvider time,
        ILogger<OfferingCatalog> logger)
    {
        _container = client.GetContainer(settings.DatabaseName, CosmosSettings.OfferingsContainer);
        _pipeline = pipeline;
        _time = time;
        _logger = logger;
    }

    /// <summary>Returns the catalog; falls back to the last good copy when Cosmos DB is failing.</summary>
    public async Task<CatalogResponse> GetAsync(CancellationToken cancellationToken)
    {
        var snapshot = _snapshot;
        var now = _time.GetUtcNow();

        if (snapshot is not null && now - snapshot.FetchedAtUtc < FreshFor)
        {
            return new CatalogResponse(snapshot.Items, Stale: false, snapshot.FetchedAtUtc);
        }

        try
        {
            snapshot = await RefreshAsync(cancellationToken);
            return new CatalogResponse(snapshot.Items, Stale: false, snapshot.FetchedAtUtc);
        }
        catch (Exception ex) when (DependencyResilience.IsTransientFailure(ex) && _snapshot is { } stale)
        {
            _logger.LogWarning(ex,
                "Cosmos DB unavailable; serving STALE catalog fetched at {FetchedAtUtc}", stale.FetchedAtUtc);
            AppMetrics.StaleCatalogServed.Add(1);
            return new CatalogResponse(stale.Items, Stale: true, stale.FetchedAtUtc);
        }
    }

    public async Task<Offering?> FindAsync(string offeringId, CancellationToken cancellationToken)
    {
        var catalog = await GetAsync(cancellationToken);
        return catalog.Offerings.FirstOrDefault(o => string.Equals(o.Id, offeringId, StringComparison.Ordinal));
    }

    /// <summary>Loads the full catalog from Cosmos DB and replaces the cached copy.</summary>
    public async Task<IReadOnlyList<Offering>> RefreshNowAsync(CancellationToken cancellationToken) =>
        (await RefreshAsync(cancellationToken)).Items;

    private async Task<Snapshot> RefreshAsync(CancellationToken cancellationToken)
    {
        var items = await _pipeline.ExecuteAsync(
            async token => await QueryAllAsync(token),
            cancellationToken);

        var snapshot = new Snapshot(items, _time.GetUtcNow());
        _snapshot = snapshot;
        return snapshot;
    }

    private async Task<IReadOnlyList<Offering>> QueryAllAsync(CancellationToken cancellationToken)
    {
        // Small catalog: a cross-partition query is fine. For large containers, always
        // prefer point reads or single-partition queries (see data/README.md).
        var query = new QueryDefinition("SELECT * FROM c WHERE c.active = true");
        using var iterator = _container.GetItemQueryIterator<Offering>(query);

        var results = new List<Offering>();
        while (iterator.HasMoreResults)
        {
            var page = await iterator.ReadNextAsync(cancellationToken);
            results.AddRange(page);
        }

        return results
            .OrderBy(o => o.Category, StringComparer.Ordinal)
            .ThenBy(o => o.PriceUsd)
            .ToList();
    }
}

/// <summary>
/// Keeps the catalog cache warm in the background so a Cosmos DB blip does not reach users
/// and so new replicas have a copy to fall back on as early as possible.
/// </summary>
public sealed class CatalogRefresher(OfferingCatalog catalog, ILogger<CatalogRefresher> logger) : BackgroundService
{
    private static readonly TimeSpan Interval = TimeSpan.FromSeconds(30);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                var items = await catalog.RefreshNowAsync(stoppingToken);
                logger.LogDebug("Catalog refreshed: {Count} offerings", items.Count);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                // Never crash the process because a dependency is down: that would turn a
                // degraded service into a crash loop.
                logger.LogWarning(ex, "Background catalog refresh failed; will retry in {Seconds}s", Interval.TotalSeconds);
            }

            try
            {
                await Task.Delay(Interval, stoppingToken);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }
    }
}
