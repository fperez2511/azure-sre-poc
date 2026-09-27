namespace Coaching.Api;

/// <summary>
/// Pure business rules (no I/O) so they are trivially unit-testable.
/// </summary>
public static class BookingRules
{
    public static readonly TimeSpan MinimumLeadTime = TimeSpan.FromHours(1);
    public static readonly TimeSpan MaximumHorizon = TimeSpan.FromDays(365);
    public const int MaxNotesLength = 1000;
    public const int MaxIdLength = 64;

    public static IReadOnlyList<string> Validate(CreateBookingRequest request, Offering? offering, DateTimeOffset now)
    {
        var errors = new List<string>();

        if (string.IsNullOrWhiteSpace(request.OfferingId))
        {
            errors.Add("offeringId is required.");
        }
        else if (offering is null)
        {
            errors.Add($"Offering '{request.OfferingId}' does not exist.");
        }
        else if (!offering.Active)
        {
            errors.Add($"Offering '{offering.Id}' is not currently bookable.");
        }

        if (string.IsNullOrWhiteSpace(request.CustomerId) || request.CustomerId.Length > MaxIdLength)
        {
            errors.Add($"customerId is required (max {MaxIdLength} characters).");
        }

        if (string.IsNullOrWhiteSpace(request.CustomerEmail) || !request.CustomerEmail.Contains('@'))
        {
            errors.Add("customerEmail must be a valid e-mail address.");
        }

        if (request.StartTimeUtc < now + MinimumLeadTime)
        {
            errors.Add("startTimeUtc must be at least 1 hour in the future.");
        }
        else if (request.StartTimeUtc > now + MaximumHorizon)
        {
            errors.Add("startTimeUtc must be within the next 365 days.");
        }

        if (request.Attendees < 1)
        {
            errors.Add("attendees must be at least 1.");
        }
        else if (offering is not null)
        {
            if (offering.Category == OfferingCategories.OneOnOne && request.Attendees != 1)
            {
                errors.Add("1-on-1 sessions are for exactly one attendee.");
            }
            else if (request.Attendees > offering.MaxAttendees)
            {
                errors.Add($"attendees exceeds the maximum of {offering.MaxAttendees} for this offering.");
            }
        }

        if (request.Notes is { Length: > MaxNotesLength })
        {
            errors.Add($"notes must be at most {MaxNotesLength} characters.");
        }

        return errors;
    }

    public static decimal CalculatePrice(Offering offering, int attendees) =>
        offering.PricingUnit == PricingUnits.PerAttendee
            ? offering.PriceUsd * attendees
            : offering.PriceUsd;

    /// <summary>Builds the booking document. Call only after <see cref="Validate"/> returned no errors.</summary>
    public static Booking CreateBooking(string id, CreateBookingRequest request, Offering offering, DateTimeOffset now) => new()
    {
        Id = id,
        CustomerId = request.CustomerId!.Trim(),
        CustomerEmail = request.CustomerEmail!.Trim(),
        OfferingId = offering.Id,
        OfferingName = offering.Name,
        Category = offering.Category,
        StartTimeUtc = request.StartTimeUtc.ToUniversalTime(),
        DurationMinutes = offering.DurationMinutes,
        Attendees = request.Attendees,
        TotalPriceUsd = CalculatePrice(offering, request.Attendees),
        Notes = request.Notes,
        CreatedAtUtc = now,
    };

    /// <summary>
    /// Idempotency keys become the Cosmos DB document id, so a client retry of the same
    /// request can never create a duplicate booking.
    /// </summary>
    public static bool IsValidIdempotencyKey(string? key) =>
        !string.IsNullOrEmpty(key)
        && key.Length <= MaxIdLength
        && key.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_');
}
