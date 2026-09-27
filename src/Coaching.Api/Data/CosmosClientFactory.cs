using System.Text.Json;
using System.Text.Json.Serialization;
using Azure.Identity;
using Microsoft.Azure.Cosmos;

namespace Coaching.Api.Data;

public sealed record CosmosSettings(string Endpoint, string DatabaseName, IReadOnlyList<string> PreferredRegions)
{
    public const string OfferingsContainer = "offerings";
    public const string BookingsContainer = "bookings";

    public static CosmosSettings FromConfiguration(IConfiguration config)
    {
        var endpoint = config["COSMOS_ENDPOINT"];
        if (string.IsNullOrWhiteSpace(endpoint))
        {
            throw new InvalidOperationException(
                "COSMOS_ENDPOINT is not configured. Locally, run `azd env get-values` and export COSMOS_ENDPOINT.");
        }

        var regions = (config["COSMOS_PREFERRED_REGIONS"] ?? string.Empty)
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

        return new CosmosSettings(endpoint, config["COSMOS_DATABASE"] ?? "coaching", regions);
    }
}

public static class CosmosClientFactory
{
    /// <summary>
    /// One CosmosClient per process (it is thread-safe and owns connection pools).
    /// The options below are deliberate reliability decisions – each one is explained
    /// because each one is exercised by a lab in the README.
    /// </summary>
    public static CosmosClient Create(CosmosSettings settings, IConfiguration config)
    {
        // Managed identity in Azure (AZURE_CLIENT_ID selects the user-assigned identity),
        // Azure CLI / VS Code credentials on a laptop. No keys: local auth is disabled on the account.
        var credential = new DefaultAzureCredential(new DefaultAzureCredentialOptions
        {
            ManagedIdentityClientId = config["AZURE_CLIENT_ID"],
        });

        var json = new JsonSerializerOptions(JsonSerializerDefaults.Web);
        json.Converters.Add(new JsonStringEnumConverter());

        var options = new CosmosClientOptions
        {
            ApplicationName = "coaching-api",

            // Gateway mode = HTTPS on port 443 only. Simpler to reason about for NSG-based chaos
            // experiments (Direct mode is faster but uses extra TCP ports).
            ConnectionMode = ConnectionMode.Gateway,

            // Recycle pooled connections every 60 s. Two reasons:
            //  - after a regional failover or DNS change, new connections go to the new endpoint;
            //  - an NSG deny rule only affects NEW flows, so without recycling a busy app would
            //    keep using its old connections and the chaos experiment would appear to "do nothing".
            HttpClientFactory = () => new HttpClient(new SocketsHttpHandler
            {
                PooledConnectionLifetime = TimeSpan.FromSeconds(60),
                ConnectTimeout = TimeSpan.FromSeconds(3),
            }),

            // Fail fast rather than hold user requests (and threads) for tens of seconds.
            RequestTimeout = TimeSpan.FromSeconds(5),
            MaxRetryAttemptsOnRateLimitedRequests = 3,
            MaxRetryWaitTimeOnRateLimitedRequests = TimeSpan.FromSeconds(5),

            UseSystemTextJsonSerializerWithOptions = json,

            // Emit Cosmos DB operations as dependency spans (visible in Application Insights).
            CosmosClientTelemetryOptions = new CosmosClientTelemetryOptions
            {
                DisableDistributedTracing = false,
            },
        };

        // Primary region first, then the secondary. Enables reads from (and automatic retry to)
        // the other region when one is unavailable.
        if (settings.PreferredRegions.Count > 0)
        {
            options.ApplicationPreferredRegions = settings.PreferredRegions;
        }

        return new CosmosClient(settings.Endpoint, credential, options);
    }
}
