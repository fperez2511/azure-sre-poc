namespace Coaching.Api;

/// <summary>Kinds of services Summit Coaching sells. Also the partition key of the offerings container.</summary>
public static class OfferingCategories
{
    public const string OneOnOne = "one-on-one";
    public const string Group = "group";
    public const string BusinessPresentation = "business-presentation";
    public const string Workshop = "workshop";

    public static readonly IReadOnlySet<string> All =
        new HashSet<string>(StringComparer.Ordinal) { OneOnOne, Group, BusinessPresentation, Workshop };
}

/// <summary>How the price of an offering is applied.</summary>
public static class PricingUnits
{
    /// <summary>Fixed price for the whole session regardless of attendees.</summary>
    public const string PerSession = "per-session";

    /// <summary>Price multiplied by the number of attendees.</summary>
    public const string PerAttendee = "per-attendee";
}

/// <summary>A bookable service (document in the <c>offerings</c> container, partitioned by <c>/category</c>).</summary>
public sealed record Offering(
    string Id,
    string Category,
    string Name,
    string Description,
    int DurationMinutes,
    int MaxAttendees,
    decimal PriceUsd,
    string PricingUnit,
    bool Active);

/// <summary>A confirmed booking (document in the <c>bookings</c> container, partitioned by <c>/customerId</c>).</summary>
public sealed record Booking
{
    public required string Id { get; init; }
    public required string CustomerId { get; init; }
    public required string CustomerEmail { get; init; }
    public required string OfferingId { get; init; }
    public required string OfferingName { get; init; }
    public required string Category { get; init; }
    public required DateTimeOffset StartTimeUtc { get; init; }
    public required int DurationMinutes { get; init; }
    public required int Attendees { get; init; }
    public required decimal TotalPriceUsd { get; init; }
    public string Status { get; init; } = "confirmed";
    public string? Notes { get; init; }
    public required DateTimeOffset CreatedAtUtc { get; init; }
}

/// <summary>Request body for <c>POST /api/bookings</c>.</summary>
public sealed record CreateBookingRequest(
    string? OfferingId,
    string? CustomerId,
    string? CustomerEmail,
    DateTimeOffset StartTimeUtc,
    int Attendees,
    string? Notes);

/// <summary>Response for the catalog, including whether it came from the stale cache.</summary>
public sealed record CatalogResponse(IReadOnlyList<Offering> Offerings, bool Stale, DateTimeOffset AsOfUtc);
