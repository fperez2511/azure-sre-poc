using Coaching.Api.Data;
using Coaching.Api.Resilience;
using Coaching.Api.Telemetry;

namespace Coaching.Api.Endpoints;

public static class ApiEndpoints
{
    private const int RetryAfterSeconds = 15;

    public static void MapCoachingApi(this WebApplication app)
    {
        var api = app.MapGroup("/api");

        // ---------- Critical flow 1: browse offerings (can degrade to stale data) ----------
        api.MapGet("/offerings", async (OfferingCatalog catalog, HttpContext http, CancellationToken ct) =>
            await Guard(http, "browse-offerings", async () =>
            {
                var result = await catalog.GetAsync(ct);
                if (result.Stale)
                {
                    http.Response.Headers["X-Data-Stale"] = "true";
                }
                return Results.Ok(result);
            }));

        api.MapGet("/offerings/{id}", async (string id, OfferingCatalog catalog, HttpContext http, CancellationToken ct) =>
            await Guard(http, "browse-offerings", async () =>
            {
                var offering = await catalog.FindAsync(id, ct);
                return offering is null ? Results.NotFound() : Results.Ok(offering);
            }));

        // ---------- Critical flow 2: create a booking (must not degrade silently) ----------
        api.MapPost("/bookings", async (
            CreateBookingRequest request,
            OfferingCatalog catalog,
            BookingStore store,
            TimeProvider time,
            HttpContext http,
            ILoggerFactory loggerFactory,
            CancellationToken ct) =>
            await Guard(http, "create-booking", async () =>
            {
                var logger = loggerFactory.CreateLogger("Bookings");

                string bookingId;
                var idempotencyKey = http.Request.Headers["Idempotency-Key"].ToString();
                if (string.IsNullOrEmpty(idempotencyKey))
                {
                    bookingId = Guid.NewGuid().ToString("n");
                }
                else if (BookingRules.IsValidIdempotencyKey(idempotencyKey))
                {
                    bookingId = idempotencyKey;
                }
                else
                {
                    return Results.ValidationProblem(new Dictionary<string, string[]>
                    {
                        ["Idempotency-Key"] = ["Use up to 64 letters, digits, '-' or '_'."],
                    });
                }

                var offering = string.IsNullOrWhiteSpace(request.OfferingId)
                    ? null
                    : await catalog.FindAsync(request.OfferingId, ct);

                var now = time.GetUtcNow();
                var errors = BookingRules.Validate(request, offering, now);
                if (errors.Count > 0)
                {
                    AppMetrics.BookingsRejected.Add(1, new KeyValuePair<string, object?>("reason", "validation"));
                    return Results.ValidationProblem(new Dictionary<string, string[]> { ["request"] = errors.ToArray() });
                }

                var booking = BookingRules.CreateBooking(bookingId, request, offering!, now);
                var (saved, created) = await store.CreateAsync(booking, ct);

                if (created)
                {
                    AppMetrics.BookingsCreated.Add(1, new KeyValuePair<string, object?>("category", saved.Category));
                    logger.LogInformation(
                        "Booking {BookingId} created for customer {CustomerId}: {OfferingId} x{Attendees} = {TotalPriceUsd} USD",
                        saved.Id, saved.CustomerId, saved.OfferingId, saved.Attendees, saved.TotalPriceUsd);
                    return Results.Created($"/api/customers/{Uri.EscapeDataString(saved.CustomerId)}/bookings/{saved.Id}", saved);
                }

                // Same idempotency key seen before: return the original booking, do not double-book.
                return Results.Ok(saved);
            }));

        api.MapGet("/customers/{customerId}/bookings", async (string customerId, BookingStore store, HttpContext http, CancellationToken ct) =>
            await Guard(http, "view-bookings", async () =>
                Results.Ok(await store.ListForCustomerAsync(customerId, ct))));

        api.MapGet("/customers/{customerId}/bookings/{bookingId}", async (string customerId, string bookingId, BookingStore store, HttpContext http, CancellationToken ct) =>
            await Guard(http, "view-bookings", async () =>
            {
                var booking = await store.GetAsync(bookingId, customerId, ct);
                return booking is null ? Results.NotFound() : Results.Ok(booking);
            }));
    }

    /// <summary>
    /// Translates dependency failures into an honest, fast "503 Service Unavailable" with a
    /// Retry-After header (instead of a slow 500). Clients and load balancers understand 503
    /// as "try again later"; SLO queries still count it as a failed request.
    /// </summary>
    private static async Task<IResult> Guard(HttpContext http, string flow, Func<Task<IResult>> action)
    {
        try
        {
            return await action();
        }
        catch (Exception ex) when (DependencyResilience.IsTransientFailure(ex))
        {
            var logger = http.RequestServices.GetRequiredService<ILoggerFactory>().CreateLogger("Dependencies");
            logger.LogError(ex, "Flow {Flow} failed because a dependency is unavailable ({ExceptionType})", flow, ex.GetType().Name);
            if (flow == "create-booking")
            {
                AppMetrics.BookingsRejected.Add(1, new KeyValuePair<string, object?>("reason", "dependency"));
            }

            http.Response.Headers.RetryAfter = RetryAfterSeconds.ToString();
            return Results.Problem(
                title: "Temporarily unavailable",
                detail: "We could not reach the booking database. Nothing was charged or booked. Please retry shortly.",
                statusCode: StatusCodes.Status503ServiceUnavailable);
        }
        catch (OperationCanceledException) when (http.RequestAborted.IsCancellationRequested)
        {
            // The client went away; there is nobody to answer.
            return Results.StatusCode(499);
        }
    }
}
