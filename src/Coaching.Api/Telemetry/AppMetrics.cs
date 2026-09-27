using System.Diagnostics.Metrics;

namespace Coaching.Api.Telemetry;

/// <summary>
/// Business-level metrics. Infrastructure metrics tell you the servers are fine;
/// these tell you whether customers are actually able to book (the critical user flow).
/// They appear in Application Insights under customMetrics.
/// </summary>
public static class AppMetrics
{
    public const string MeterName = "Coaching.Api";

    private static readonly Meter Meter = new(MeterName);

    public static readonly Counter<long> BookingsCreated =
        Meter.CreateCounter<long>("bookings.created", description: "Bookings successfully created");

    public static readonly Counter<long> BookingsRejected =
        Meter.CreateCounter<long>("bookings.rejected", description: "Booking attempts that failed (validation or dependency)");

    public static readonly Counter<long> StaleCatalogServed =
        Meter.CreateCounter<long>("catalog.stale_served", description: "Catalog responses served from the stale cache (graceful degradation)");
}
