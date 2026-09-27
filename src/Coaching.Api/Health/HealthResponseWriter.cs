using System.Text.Json;
using Microsoft.Extensions.Diagnostics.HealthChecks;

namespace Coaching.Api.Health;

public static class HealthResponseWriter
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web) { WriteIndented = true };

    public static Task WriteJsonAsync(HttpContext context, HealthReport report)
    {
        context.Response.ContentType = "application/json";
        var body = new
        {
            status = report.Status.ToString(),
            totalMs = report.TotalDuration.TotalMilliseconds,
            checks = report.Entries.Select(e => new
            {
                name = e.Key,
                status = e.Value.Status.ToString(),
                description = e.Value.Description,
                error = e.Value.Exception?.Message,
                ms = e.Value.Duration.TotalMilliseconds,
            }),
        };
        return context.Response.WriteAsync(JsonSerializer.Serialize(body, Json));
    }
}
