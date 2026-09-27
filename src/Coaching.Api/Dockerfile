# syntax=docker/dockerfile:1
# Built remotely in Azure Container Registry by `azd deploy` (remoteBuild: true),
# so you do not need Docker installed locally.

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY Coaching.Api.csproj ./
RUN dotnet restore Coaching.Api.csproj
COPY . .
RUN dotnet publish Coaching.Api.csproj -c Release -o /app/publish --no-restore /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
WORKDIR /app
ENV ASPNETCORE_HTTP_PORTS=8080 \
    DOTNET_gcServer=0
EXPOSE 8080
COPY --from=build /app/publish .
# Run as the non-root user that ships with the .NET images
USER $APP_UID
ENTRYPOINT ["dotnet", "Coaching.Api.dll"]
