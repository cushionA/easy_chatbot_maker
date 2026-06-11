FROM mcr.microsoft.com/dotnet/sdk:9.0.315 AS build
WORKDIR /src

COPY Portfolio.sln ./
COPY Portfolio.Web/Portfolio.Web.csproj Portfolio.Web/
COPY Portfolio.Web.Tests/Portfolio.Web.Tests.csproj Portfolio.Web.Tests/
RUN dotnet restore Portfolio.Web/Portfolio.Web.csproj

COPY Portfolio.Web/ Portfolio.Web/
RUN dotnet publish Portfolio.Web/Portfolio.Web.csproj -c Release -o /app /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS runtime
WORKDIR /app
COPY --from=build /app ./
USER app
EXPOSE 8080
ENV ASPNETCORE_URLS=http://+:8080
ENTRYPOINT ["dotnet", "Portfolio.Web.dll"]
