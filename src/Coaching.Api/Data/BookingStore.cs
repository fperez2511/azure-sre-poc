using System.Net;
using Microsoft.Azure.Cosmos;
using Polly;

namespace Coaching.Api.Data;

/// <summary>
/// Write path for bookings – the most critical user flow (it is where revenue happens).
/// Every call goes through the shared resilience pipeline (timeout + circuit breaker).
/// </summary>
public sealed class BookingStore
{
    private readonly Container _container;
    private readonly ResiliencePipeline _pipeline;

    public BookingStore(CosmosClient client, CosmosSettings settings, ResiliencePipeline pipeline)
    {
        _container = client.GetContainer(settings.DatabaseName, CosmosSettings.BookingsContainer);
        _pipeline = pipeline;
    }

    /// <summary>
    /// Creates the booking. If a document with the same id (the idempotency key) already exists
    /// for this customer, returns the existing one instead of creating a duplicate – so clients
    /// and load balancers can safely retry a POST that timed out.
    /// </summary>
    public async Task<(Booking Booking, bool Created)> CreateAsync(Booking booking, CancellationToken cancellationToken)
    {
        try
        {
            var response = await _pipeline.ExecuteAsync(
                async token => await _container.CreateItemAsync(
                    booking, new PartitionKey(booking.CustomerId), cancellationToken: token),
                cancellationToken);
            return (response.Resource, true);
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.Conflict)
        {
            var existing = await GetAsync(booking.Id, booking.CustomerId, cancellationToken);
            return (existing ?? booking, false);
        }
    }

    /// <summary>Point read: the cheapest Cosmos DB operation (1 RU for a 1 KB item).</summary>
    public async Task<Booking?> GetAsync(string id, string customerId, CancellationToken cancellationToken)
    {
        try
        {
            var response = await _pipeline.ExecuteAsync(
                async token => await _container.ReadItemAsync<Booking>(
                    id, new PartitionKey(customerId), cancellationToken: token),
                cancellationToken);
            return response.Resource;
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }
    }

    /// <summary>Single-partition query (partition key = customerId), newest first.</summary>
    public async Task<IReadOnlyList<Booking>> ListForCustomerAsync(string customerId, CancellationToken cancellationToken)
    {
        return await _pipeline.ExecuteAsync(async token =>
        {
            var query = new QueryDefinition(
                    "SELECT * FROM c WHERE c.customerId = @customerId ORDER BY c.startTimeUtc DESC")
                .WithParameter("@customerId", customerId);

            using var iterator = _container.GetItemQueryIterator<Booking>(query, requestOptions: new QueryRequestOptions
            {
                PartitionKey = new PartitionKey(customerId),
                MaxItemCount = 50,
            });

            var results = new List<Booking>();
            while (iterator.HasMoreResults && results.Count < 50)
            {
                var page = await iterator.ReadNextAsync(token);
                results.AddRange(page);
            }

            return (IReadOnlyList<Booking>)results;
        }, cancellationToken);
    }
}
