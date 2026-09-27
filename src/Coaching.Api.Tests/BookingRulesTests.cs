using Coaching.Api;

namespace Coaching.Api.Tests;

public class BookingRulesTests
{
    private static readonly DateTimeOffset Now = new(2026, 10, 1, 12, 0, 0, TimeSpan.Zero);

    private static readonly Offering OneOnOne = new(
        "career-1on1-60", OfferingCategories.OneOnOne, "Career coaching", "desc", 60, 1, 150m, PricingUnits.PerSession, true);

    private static readonly Offering GroupCircle = new(
        "group-circle-90", OfferingCategories.Group, "Group circle", "desc", 90, 8, 60m, PricingUnits.PerAttendee, true);

    private static CreateBookingRequest ValidRequest(string offeringId = "career-1on1-60", int attendees = 1) =>
        new(offeringId, "cust-001", "ana@example.com", Now.AddDays(3), attendees, null);

    [Fact]
    public void Valid_request_has_no_errors()
    {
        Assert.Empty(BookingRules.Validate(ValidRequest(), OneOnOne, Now));
    }

    [Fact]
    public void Unknown_offering_is_rejected()
    {
        var errors = BookingRules.Validate(ValidRequest("nope"), offering: null, Now);
        Assert.Contains(errors, e => e.Contains("does not exist"));
    }

    [Fact]
    public void One_on_one_requires_exactly_one_attendee()
    {
        var errors = BookingRules.Validate(ValidRequest(attendees: 2), OneOnOne, Now);
        Assert.Contains(errors, e => e.Contains("exactly one attendee"));
    }

    [Fact]
    public void Group_capacity_is_enforced()
    {
        var errors = BookingRules.Validate(ValidRequest("group-circle-90", attendees: 9), GroupCircle, Now);
        Assert.Contains(errors, e => e.Contains("maximum of 8"));
    }

    [Fact]
    public void Start_time_must_respect_lead_time()
    {
        var request = ValidRequest() with { StartTimeUtc = Now.AddMinutes(30) };
        Assert.Contains(BookingRules.Validate(request, OneOnOne, Now), e => e.Contains("1 hour"));
    }

    [Theory]
    [InlineData(1, 60)]
    [InlineData(5, 300)]
    public void Per_attendee_pricing_multiplies(int attendees, int expected)
    {
        Assert.Equal((decimal)expected, BookingRules.CalculatePrice(GroupCircle, attendees));
    }

    [Fact]
    public void Per_session_pricing_is_flat()
    {
        Assert.Equal(150m, BookingRules.CalculatePrice(OneOnOne, 1));
    }

    [Theory]
    [InlineData("order-123_abc", true)]
    [InlineData("", false)]
    [InlineData("has space", false)]
    [InlineData("slash/not-allowed", false)]
    public void Idempotency_key_format(string key, bool expected)
    {
        Assert.Equal(expected, BookingRules.IsValidIdempotencyKey(key));
    }

    [Fact]
    public void Created_booking_uses_offering_data_and_utc()
    {
        var request = ValidRequest("group-circle-90", attendees: 3) with
        {
            StartTimeUtc = new DateTimeOffset(2026, 10, 5, 9, 0, 0, TimeSpan.FromHours(-5)),
        };

        var booking = BookingRules.CreateBooking("b1", request, GroupCircle, Now);

        Assert.Equal(180m, booking.TotalPriceUsd);
        Assert.Equal(TimeSpan.Zero, booking.StartTimeUtc.Offset);
        Assert.Equal(OfferingCategories.Group, booking.Category);
    }
}
