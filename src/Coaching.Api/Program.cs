using Azure.Monitor.OpenTelemetry.AspNetCore;
using Coaching.Api.Chaos;
using Coaching.Api.Data;
using Coaching.Api.Endpoints;
using Coaching.Api.Health;
using Coaching.Api.Resilience;
using Coaching.Api.Telemetry;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;

var builder = WebApplication.CreateBuilder(args);

// ---------------------------------------------------------------------------
// Fault injection (see Chaos/FaultInjection.cs). A "broken release" dies here, before it
// can ever receive traffic – Container Apps keeps the previous healthy revision serving.
// ---------------------------------------------------------------------------
var faults = FaultOptions.FromConfiguration(builder.Configuration);
if (faults.CrashOnStartup)
{
    Console.Error.WriteLine(
        "FATAL: required setting 'PAYMENTS__RATECARD_URL' is missing. Refusing to start. (FAULT_CRASH_ON_STARTUP)");
    return 1;
}
builder.Services.AddSingleton(faults);

// ---------------------------------------------------------------------------
// Telemetry: OpenTelemetry -> Azure Monitor (Application Insights).
// service.name becomes cloud_RoleName / AppRoleName, which every KQL query filters on.
// ---------------------------------------------------------------------------
AppContext.SetSwitch("Azure.Experimental.EnableActivitySource", true); // Azure SDK (incl. Cosmos DB) spans
var revision = builder.Configuration["CONTAINER_APP_REVISION"] ?? "local";

var otel = builder.Services.AddOpenTelemetry()
    .ConfigureResource(resource => resource.AddService(serviceName: "coaching-api", serviceVersion: revision))
    .WithTracing(tracing => tracing.AddSource("Azure.Cosmos.Operation"))
    .WithMetrics(metrics => metrics.AddMeter(AppMetrics.MeterName));

if (!string.IsNullOrWhiteSpace(builder.Configuration["APPLICATIONINSIGHTS_CONNECTION_STRING"]))
{
    otel.UseAzureMonitor();
}

// ---------------------------------------------------------------------------
// Data access + resilience
// ---------------------------------------------------------------------------
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddSingleton(sp => CosmosSettings.FromConfiguration(sp.GetRequiredService<IConfiguration>()));
builder.Services.AddSingleton(sp => CosmosClientFactory.Create(
    sp.GetRequiredService<CosmosSettings>(),
    sp.GetRequiredService<IConfiguration>()));
builder.Services.AddSingleton(sp => DependencyResilience.Build(
    sp.GetRequiredService<ILoggerFactory>().CreateLogger("Coaching.Api.Resilience")));
builder.Services.AddSingleton<OfferingCatalog>();
builder.Services.AddSingleton<BookingStore>();
builder.Services.AddHostedService<CatalogRefresher>();

// ---------------------------------------------------------------------------
// Health endpoints – three different questions, three different answers:
//   /healthz/live   "is the process alive?"        -> liveness + startup probes (restart if not)
//   /healthz/ready  "can this replica take traffic?" -> readiness probe (stop routing if not)
//   /healthz/deps   "are my dependencies OK?"      -> for humans, dashboards and SRE Agent only
// ---------------------------------------------------------------------------
builder.Services.AddHealthChecks()
    .AddCheck("self", () => HealthCheckResult.Healthy(), tags: ["live", "ready"])
    .AddCheck<CosmosHealthCheck>("cosmos", tags: ["deps"]);

builder.Services.AddProblemDetails();

var app = builder.Build();

app.UseExceptionHandler(); // unhandled exceptions -> RFC 7807 problem+json 500, logged with stack trace
app.Use(async (context, next) =>
{
    // Lets you (and traffic.sh) see which revision served each request during rollouts.
    context.Response.Headers["X-Revision"] = revision;
    await next(context);
});
app.UseMiddleware<FaultInjectionMiddleware>();

app.MapGet("/", () => Results.Ok(new
{
    service = "Summit Coaching booking API",
    revision,
    endpoints = new[] { "/api/offerings", "/api/bookings", "/api/customers/{customerId}/bookings", "/healthz/deps" },
}));

app.MapHealthChecks("/healthz/live", new HealthCheckOptions { Predicate = check => check.Tags.Contains("live") });
app.MapHealthChecks("/healthz/ready", new HealthCheckOptions { Predicate = check => check.Tags.Contains("ready") });
app.MapHealthChecks("/healthz/deps", new HealthCheckOptions
{
    Predicate = check => check.Tags.Contains("deps"),
    ResponseWriter = HealthResponseWriter.WriteJsonAsync,
});

app.MapCoachingApi();

app.Run();
return 0;
