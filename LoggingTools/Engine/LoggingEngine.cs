// SPDX-License-Identifier: GPL-3.0-or-later
// Background workers deliberately contain no PowerShell scriptblocks or runspace dependencies.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace LoggingTools
{
    public sealed class SinkOptions
    {
        public string Name;
        public string Kind;
        public string MinimumLevel = "INFO";
        public int Capacity = 10000;
        public long CapacityBytes = 32L * 1024 * 1024;
        public int BatchCount = 500;
        public int BatchBytes = 512 * 1024;
        public int IntervalMilliseconds = 1000;
        public string Path;
        public long MaximumFileBytes = 10L * 1024 * 1024;
        public int RetainedFiles = 5;
        public string Endpoint;
        public string RuleId;
        public string Stream;
        public string WebhookUrl;
        public int MinimumSendIntervalMilliseconds = 1000;
        public int TimeoutSeconds = 30;
        public int MaximumRetries = 3;
        public int RetryBaseMilliseconds = 500;
        public string Authentication;
        public string TenantId;
        public string ClientId;
        public string ClientSecret;
        public X509Certificate2 Certificate;
        public string CliPath;
        // Only the .NET test harness supplies a client. The public configuration does not expose this.
        public HttpClient TestClient;
    }

    public sealed class SinkStatus
    {
        public string Name { get; set; }
        public string Kind { get; set; }
        public string State { get; set; }
        public long Accepted { get; set; }
        public long Delivered { get; set; }
        public long Failed { get; set; }
        public long Dropped { get; set; }
        public long Pending { get; set; }
        public int QueueDepth { get; set; }
        public long PendingBytes { get; set; }
        public string LastError { get; set; }
        public Dictionary<string, long> DroppedByLevel { get; set; }
    }

    public sealed class FlushResult
    {
        public bool TimedOut { get; set; }
        public bool Success { get; set; }
        public SinkStatus[] Destinations { get; set; }
    }

    internal sealed class LogEvent
    {
        public string Json;
        public int Bytes;
        public string Level;
        public long EnqueuedTicks;
    }

    internal sealed class DeliveryException : Exception
    {
        public DeliveryException(string message) : base(message) { }
    }

    public sealed class Logger : IDisposable
    {
        private static readonly string[] Levels = { "DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL" };
        private readonly List<Sink> sinks = new List<Sink>();
        private readonly HashSet<string> redactFields;
        private readonly string[] redactValues;
        private readonly string application;
        private readonly string hostName = Environment.MachineName;
        private readonly int processId = Process.GetCurrentProcess().Id;
        private volatile bool accepting = true;
        public bool IsClosed { get { return !accepting; } }

        public Logger(string applicationName, SinkOptions[] destinations, string[] fields, string[] values)
        {
            application = applicationName;
            redactFields = new HashSet<string>(fields ?? new string[0], StringComparer.OrdinalIgnoreCase);
            redactValues = (values ?? new string[0]).Where(v => !String.IsNullOrEmpty(v)).Distinct().OrderByDescending(v => v.Length).ToArray();
            try
            {
                foreach (SinkOptions options in destinations)
                    sinks.Add(options.Kind == "File" ? (Sink)new FileSink(options) : new NetworkSink(options));
                foreach (Sink sink in sinks) sink.Start();
            }
            catch
            {
                foreach (Sink sink in sinks) sink.Abort();
                throw new InvalidOperationException("Logger initialization failed. Check file permissions and destination settings.");
            }
        }

        internal static int Rank(string level) { return Array.IndexOf(Levels, level.ToUpperInvariant()); }

        public bool IsEnabled(string level)
        {
            if (!accepting) throw new InvalidOperationException("Logger is closed. Initialize a new logger first.");
            return sinks.Any(s => Rank(level) >= Rank(s.Options.MinimumLevel));
        }

        private string Redact(string value)
        {
            if (value == null) return null;
            foreach (string secret in redactValues) value = value.Replace(secret, "[REDACTED]");
            return value;
        }

        private void WriteValue(Utf8JsonWriter writer, JsonElement element)
        {
            switch (element.ValueKind)
            {
                case JsonValueKind.Object:
                    writer.WriteStartObject();
                    foreach (JsonProperty property in element.EnumerateObject())
                    {
                        writer.WritePropertyName(Redact(property.Name));
                        if (redactFields.Contains(property.Name)) writer.WriteStringValue("[REDACTED]");
                        else WriteValue(writer, property.Value);
                    }
                    writer.WriteEndObject(); break;
                case JsonValueKind.Array:
                    writer.WriteStartArray();
                    foreach (JsonElement item in element.EnumerateArray()) WriteValue(writer, item);
                    writer.WriteEndArray(); break;
                case JsonValueKind.String: writer.WriteStringValue(Redact(element.GetString())); break;
                default: element.WriteTo(writer); break;
            }
        }

        private void WriteJson(Utf8JsonWriter writer, string name, string json)
        {
            writer.WritePropertyName(name);
            if (String.IsNullOrEmpty(json)) { writer.WriteNullValue(); return; }
            using (JsonDocument document = JsonDocument.Parse(json)) WriteValue(writer, document.RootElement);
        }

        public string[] Write(string level, string message, string dataJson, string exceptionJson, string correlationId)
        {
            level = level.ToUpperInvariant();
            if (Rank(level) < 0) throw new ArgumentException("Unknown log level.");
            if (!IsEnabled(level)) return new string[0];
            string json;
            int byteCount;
            using (MemoryStream buffer = new MemoryStream())
            {
                using (Utf8JsonWriter writer = new Utf8JsonWriter(buffer))
                {
                    writer.WriteStartObject();
                    writer.WriteString("TimeGenerated", DateTimeOffset.UtcNow.ToString("O", CultureInfo.InvariantCulture));
                    writer.WriteString("EventId", Guid.NewGuid().ToString());
                    writer.WriteString("Level", level);
                    writer.WriteString("Message", Redact(message));
                    writer.WriteString("Application", Redact(application));
                    writer.WriteString("HostName", Redact(hostName));
                    writer.WriteNumber("ProcessId", processId);
                    writer.WriteString("CorrelationId", Redact(correlationId));
                    WriteJson(writer, "Data", dataJson);
                    WriteJson(writer, "Exception", exceptionJson);
                    writer.WriteEndObject();
                }
                byteCount = checked((int)buffer.Length);
                json = Encoding.UTF8.GetString(buffer.ToArray());
            }
            LogEvent entry = new LogEvent { Json = json, Bytes = byteCount, Level = level, EnqueuedTicks = Stopwatch.GetTimestamp() };
            List<string> warnings = new List<string>();
            foreach (Sink sink in sinks)
                if (Rank(level) >= Rank(sink.Options.MinimumLevel) && sink.Enqueue(entry)) warnings.Add(sink.Options.Name);
            return warnings.ToArray();
        }

        public SinkStatus[] GetStatus() { return sinks.Select(s => s.Status()).ToArray(); }

        public FlushResult Flush(int timeoutMilliseconds)
        {
            long[] targets = sinks.Select(s => s.RequestFlush()).ToArray();
            Stopwatch timer = Stopwatch.StartNew();
            while (sinks.Where((s, i) => !s.Reached(targets[i])).Any() && timer.ElapsedMilliseconds < timeoutMilliseconds)
                Thread.Sleep(5);
            SinkStatus[] status = GetStatus();
            bool timedOut = sinks.Where((s, i) => !s.Reached(targets[i])).Any();
            return new FlushResult { TimedOut = timedOut, Destinations = status,
                Success = !timedOut && status.All(s => s.Failed == 0 && s.Dropped == 0 && s.LastError == null) };
        }

        public FlushResult Close(int timeoutMilliseconds)
        {
            accepting = false;
            Stopwatch timer = Stopwatch.StartNew();
            FlushResult result = Flush(timeoutMilliseconds);
            foreach (Sink sink in sinks) sink.Abort();
            foreach (Sink sink in sinks) sink.Wait((int)Math.Max(0, timeoutMilliseconds - timer.ElapsedMilliseconds));
            result.Destinations = GetStatus();
            return result;
        }

        public void Dispose() { Close(2000); }
    }

    internal abstract class Sink
    {
        internal readonly SinkOptions Options;
        protected readonly CancellationTokenSource stop = new CancellationTokenSource();
        private readonly Queue<LogEvent> queue = new Queue<LogEvent>();
        private readonly object gate = new object();
        private readonly SemaphoreSlim signal = new SemaphoreSlim(0);
        private readonly Dictionary<string, long> drops = new Dictionary<string, long>();
        private long accepted, delivered, failed, dropped, pendingBytes, flushTarget, lastWarning;
        private string lastError;
        private Task worker;
        private bool broken;

        protected Sink(SinkOptions options) { Options = options; }
        public void Start() { worker = Task.Run(RunAsync); }

        // Returns true only when a rate-limited warning should be emitted by the caller.
        public bool Enqueue(LogEvent entry)
        {
            lock (gate)
            {
                if (broken || stop.IsCancellationRequested || accepted - delivered - failed >= Options.Capacity || entry.Bytes > Options.CapacityBytes - pendingBytes)
                {
                    dropped++;
                    if (!drops.ContainsKey(entry.Level)) drops[entry.Level] = 0;
                    drops[entry.Level]++;
                    long now = Stopwatch.GetTimestamp();
                    if (lastWarning == 0 || (now - lastWarning) / (double)Stopwatch.Frequency >= 30)
                    { lastWarning = now; return true; }
                    return false;
                }
                bool wake = queue.Count == 0;
                queue.Enqueue(entry); accepted++; pendingBytes += entry.Bytes;
                if (wake) signal.Release();
                return false;
            }
        }

        public SinkStatus Status()
        {
            lock (gate) return new SinkStatus { Name = Options.Name, Kind = Options.Kind,
                State = broken ? "Faulted" : (worker != null && worker.IsCompleted ? "Closed" : (stop.IsCancellationRequested ? "Stopping" : "Running")),
                Accepted = accepted, Delivered = delivered, Failed = failed, Dropped = dropped,
                Pending = accepted - delivered - failed, QueueDepth = queue.Count, PendingBytes = pendingBytes,
                LastError = lastError, DroppedByLevel = new Dictionary<string, long>(drops) };
        }

        public long RequestFlush() { lock (gate) { flushTarget = accepted; signal.Release(); return accepted; } }
        public bool Reached(long target) { lock (gate) return delivered + failed >= target; }
        public void Abort() { stop.Cancel(); if (worker == null) Cleanup(); }
        public void Wait(int milliseconds) { if (worker != null) { try { worker.Wait(milliseconds); } catch (AggregateException) { } } }

        private void Complete(List<LogEvent> batch, string error)
        {
            lock (gate)
            {
                if (error == null) delivered += batch.Count;
                else { failed += batch.Count; lastError = error; }
                foreach (LogEvent entry in batch) pendingBytes -= entry.Bytes;
            }
        }

        private async Task RunAsync()
        {
            try
            {
                while (true)
                {
                    await signal.WaitAsync(stop.Token).ConfigureAwait(false);
                    while (!stop.IsCancellationRequested)
                    {
                        List<LogEvent> batch = new List<LogEvent>();
                        int wait = 0;
                        lock (gate)
                        {
                            if (queue.Count == 0) break;
                            double age = (Stopwatch.GetTimestamp() - queue.Peek().EnqueuedTicks) * 1000.0 / Stopwatch.Frequency;
                            if (flushTarget <= delivered + failed && queue.Count < Options.BatchCount && pendingBytes < Options.BatchBytes && age < Options.IntervalMilliseconds)
                                wait = Math.Max(1, Math.Min(25, Options.IntervalMilliseconds - (int)age));
                            else
                            {
                                int bytes = 2;
                                while (queue.Count > 0 && batch.Count < Options.BatchCount)
                                {
                                    LogEvent next = queue.Peek();
                                    if (batch.Count > 0 && bytes + next.Bytes + 1 > Options.BatchBytes) break;
                                    // Isolate large Azure records so a field-size rejection cannot fail neighboring valid events.
                                    if (Options.Kind == "LogAnalytics" && next.Bytes > 64 * 1024 && batch.Count > 0) break;
                                    batch.Add(queue.Dequeue()); bytes += next.Bytes + 1;
                                    if (Options.Kind == "LogAnalytics" && next.Bytes > 64 * 1024) break;
                                }
                            }
                        }
                        if (wait > 0) { await Task.Delay(wait, stop.Token).ConfigureAwait(false); continue; }
                        try { await DeliverAsync(batch, stop.Token).ConfigureAwait(false); Complete(batch, null); }
                        catch (OperationCanceledException) { Complete(batch, "Delivery cancelled before completion."); throw; }
                        catch (DeliveryException error) { Complete(batch, error.Message); }
                        catch (Exception error) { Complete(batch, "Delivery failed (" + error.GetType().Name + "). Check destination configuration and access."); }
                    }
                    stop.Token.ThrowIfCancellationRequested();
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception error)
            {
                lock (gate) { broken = true; lastError = "Worker stopped (" + error.GetType().Name + ")."; }
            }
            finally
            {
                lock (gate)
                {
                    if (queue.Count > 0)
                    {
                        failed += queue.Count; queue.Clear(); pendingBytes = 0;
                        lastError = "Worker closed with undelivered events.";
                    }
                }
                Cleanup();
            }
        }

        protected abstract Task DeliverAsync(List<LogEvent> batch, CancellationToken cancellation);
        protected virtual void Cleanup() { }
    }

    internal sealed class FileSink : Sink
    {
        private StreamWriter writer;
        private long size;
        public FileSink(SinkOptions options) : base(options) { Open(); }
        private void Open()
        {
            FileStream stream = new FileStream(Options.Path, FileMode.Append, FileAccess.Write, FileShare.Read, 65536);
            size = stream.Length;
            writer = new StreamWriter(stream, new UTF8Encoding(false), 65536);
            writer.NewLine = "\n";
        }
        protected override Task DeliverAsync(List<LogEvent> batch, CancellationToken cancellation)
        {
            foreach (LogEvent entry in batch)
            {
                cancellation.ThrowIfCancellationRequested();
                if (Options.MaximumFileBytes > 0 && size > 0 && size + entry.Bytes + 1 > Options.MaximumFileBytes)
                {
                    writer.Dispose(); writer = null;
                    string oldest = Options.Path + "." + Options.RetainedFiles;
                    if (File.Exists(oldest)) File.Delete(oldest);
                    for (int index = Options.RetainedFiles - 1; index >= 1; index--)
                        if (File.Exists(Options.Path + "." + index)) File.Move(Options.Path + "." + index, Options.Path + "." + (index + 1));
                    File.Move(Options.Path, Options.Path + ".1");
                    Open();
                }
                writer.WriteLine(entry.Json); size += entry.Bytes + 1;
            }
            writer.Flush();
            return Task.CompletedTask;
        }
        protected override void Cleanup() { if (writer != null) { writer.Dispose(); writer = null; } }
    }

    internal sealed class NetworkSink : Sink
    {
        private readonly HttpClient client;
        private readonly TokenProvider tokens;
        private long lastSend;
        public NetworkSink(SinkOptions options) : base(options)
        {
            client = options.TestClient ?? new HttpClient(new HttpClientHandler { SslProtocols = SslProtocols.Tls12 }) { Timeout = Timeout.InfiniteTimeSpan };
            if (options.Kind == "LogAnalytics") tokens = new TokenProvider(options, client);
        }
        protected override async Task DeliverAsync(List<LogEvent> batch, CancellationToken cancellation)
        {
            if (Options.Kind == "LogAnalytics")
            {
                string body = "[" + String.Join(",", batch.Select(e => e.Json)) + "]";
                if (Encoding.UTF8.GetByteCount(body) > Options.BatchBytes) throw new DeliveryException("Event exceeds Azure batch byte limit; reduce the event size or increase BatchBytes within the API limit.");
                foreach (LogEvent entry in batch)
                {
                    using (JsonDocument document = JsonDocument.Parse(entry.Json))
                        foreach (JsonProperty field in document.RootElement.EnumerateObject())
                        {
                            string value = field.Value.ValueKind == JsonValueKind.String ? field.Value.GetString() : field.Value.GetRawText();
                            if (Encoding.UTF8.GetByteCount(value) > 64 * 1024)
                                throw new DeliveryException("Event contains a field over the Azure 64 KiB limit; reduce the event size to avoid service-side truncation.");
                        }
                }
                string url = Options.Endpoint.TrimEnd('/') + "/dataCollectionRules/" + Uri.EscapeDataString(Options.RuleId) + "/streams/" + Uri.EscapeDataString(Options.Stream) + "?api-version=2023-01-01";
                string token = await tokens.GetAsync(cancellation).ConfigureAwait(false);
                try
                {
                    await HttpTransport.SendAsync(client, () =>
                    {
                        HttpRequestMessage request = new HttpRequestMessage(HttpMethod.Post, url);
                        request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);
                        request.Headers.Add("x-ms-client-request-id", Guid.NewGuid().ToString());
                        request.Content = new StringContent(body, Encoding.UTF8, "application/json");
                        return request;
                    }, Options, cancellation).ConfigureAwait(false);
                }
                catch (DeliveryException) { tokens.Invalidate(); throw; }
            }
            else
            {
                LogEvent entry = batch[0];
                string body = JsonSerializer.Serialize(new { type = "message", attachments = new[] { new {
                    contentType = "application/vnd.microsoft.card.adaptive", contentUrl = (string)null,
                    content = new { type = "AdaptiveCard", version = "1.2", body = new[] { new { type = "TextBlock", text = entry.Json, wrap = true } } }
                } } });
                if (Encoding.UTF8.GetByteCount(body) > 28 * 1024) throw new DeliveryException("Event exceeds the Teams 28 KiB payload limit.");
                if (lastSend != 0)
                {
                    int delay = Options.MinimumSendIntervalMilliseconds - (int)((Stopwatch.GetTimestamp() - lastSend) * 1000.0 / Stopwatch.Frequency);
                    if (delay > 0) await Task.Delay(delay, cancellation).ConfigureAwait(false);
                }
                lastSend = Stopwatch.GetTimestamp();
                await HttpTransport.SendAsync(client, () => new HttpRequestMessage(HttpMethod.Post, Options.WebhookUrl) {
                    Content = new StringContent(body, Encoding.UTF8, "application/json") }, Options, cancellation).ConfigureAwait(false);
            }
        }
        protected override void Cleanup() { if (tokens != null) tokens.Dispose(); if (Options.TestClient == null) client.Dispose(); }
    }

    internal static class HttpTransport
    {
        internal static async Task<string> SendAsync(HttpClient client, Func<HttpRequestMessage> requestFactory, SinkOptions options, CancellationToken cancellation)
        {
            for (int attempt = 0; ; attempt++)
            {
                double delay = Math.Min(30000, options.RetryBaseMilliseconds * Math.Pow(2, attempt));
                try
                {
                    using (CancellationTokenSource timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation))
                    using (HttpRequestMessage request = requestFactory())
                    {
                        timeout.CancelAfter(TimeSpan.FromSeconds(options.TimeoutSeconds));
                        using (HttpResponseMessage response = await client.SendAsync(request, timeout.Token).ConfigureAwait(false))
                        {
                            if (response.IsSuccessStatusCode) return await response.Content.ReadAsStringAsync().ConfigureAwait(false);
                            int status = (int)response.StatusCode;
                            if ((status != 429 && status < 500) || attempt >= options.MaximumRetries)
                                throw new DeliveryException("HTTP " + status + ". Verify authentication, permissions, schema, and destination availability.");
                            if (response.Headers.RetryAfter != null)
                            {
                                if (response.Headers.RetryAfter.Delta.HasValue) delay = Math.Max(0, response.Headers.RetryAfter.Delta.Value.TotalMilliseconds);
                                else if (response.Headers.RetryAfter.Date.HasValue) delay = Math.Max(0, (response.Headers.RetryAfter.Date.Value - DateTimeOffset.UtcNow).TotalMilliseconds);
                            }
                        }
                    }
                }
                catch (HttpRequestException)
                { if (attempt >= options.MaximumRetries) throw new DeliveryException("Network delivery failed after bounded retries."); }
                catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
                { if (attempt >= options.MaximumRetries) throw new DeliveryException("Network request timed out after bounded retries."); }
                await Task.Delay(TimeSpan.FromMilliseconds(delay), cancellation).ConfigureAwait(false);
            }
        }
    }

    internal sealed class TokenProvider : IDisposable
    {
        private readonly SinkOptions options;
        private readonly HttpClient client;
        private string token;
        private DateTimeOffset expires;
        private HttpClient metadataClient;
        internal TokenProvider(SinkOptions options, HttpClient client) { this.options = options; this.client = client; }
        public void Invalidate() { token = null; }
        private static string Base64Url(byte[] bytes) { return Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_'); }

        internal async Task<string> GetAsync(CancellationToken cancellation)
        {
            if (token != null && expires > DateTimeOffset.UtcNow.AddMinutes(2)) return token;
            string response;
            if (options.Authentication == "AzureCli") response = await GetCliAsync(cancellation).ConfigureAwait(false);
            else if (options.Authentication == "ManagedIdentity")
            {
                string endpoint = Environment.GetEnvironmentVariable("IDENTITY_ENDPOINT");
                string header = Environment.GetEnvironmentVariable("IDENTITY_HEADER");
                bool appService = !String.IsNullOrEmpty(endpoint) && !String.IsNullOrEmpty(header);
                string url = appService ? endpoint + (endpoint.Contains("?") ? "&" : "?") + "api-version=2019-08-01&resource=https%3A%2F%2Fmonitor.azure.com" :
                    "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmonitor.azure.com";
                if (!String.IsNullOrEmpty(options.ClientId)) url += "&client_id=" + Uri.EscapeDataString(options.ClientId);
                if (metadataClient == null) metadataClient = options.TestClient ?? new HttpClient(new HttpClientHandler { UseProxy = false }) { Timeout = Timeout.InfiniteTimeSpan };
                response = await HttpTransport.SendAsync(metadataClient, () => {
                    HttpRequestMessage request = new HttpRequestMessage(HttpMethod.Get, url);
                    request.Headers.Add(appService ? "X-IDENTITY-HEADER" : "Metadata", appService ? header : "true");
                    return request;
                }, options, cancellation).ConfigureAwait(false);
            }
            else
            {
                string url = "https://login.microsoftonline.com/" + options.TenantId + "/oauth2/v2.0/token";
                Dictionary<string, string> form = new Dictionary<string, string> {
                    { "client_id", options.ClientId }, { "scope", "https://monitor.azure.com/.default" }, { "grant_type", "client_credentials" }
                };
                if (options.Authentication == "ClientSecret") form["client_secret"] = options.ClientSecret;
                else
                {
                    X509Certificate2 certificate = options.Certificate;
                    string thumbprint;
                    using (SHA256 hash = SHA256.Create()) thumbprint = Base64Url(hash.ComputeHash(certificate.RawData));
                    string jwtHeader = JsonSerializer.Serialize(new Dictionary<string, string> { { "alg", "PS256" }, { "typ", "JWT" }, { "x5t#S256", thumbprint } });
                    string claims = JsonSerializer.Serialize(new { aud = url, iss = options.ClientId, sub = options.ClientId,
                        jti = Guid.NewGuid().ToString(), nbf = DateTimeOffset.UtcNow.AddSeconds(-30).ToUnixTimeSeconds(), exp = DateTimeOffset.UtcNow.AddMinutes(5).ToUnixTimeSeconds() });
                    string unsigned = Base64Url(Encoding.UTF8.GetBytes(jwtHeader)) + "." + Base64Url(Encoding.UTF8.GetBytes(claims));
                    using (RSA key = certificate.GetRSAPrivateKey())
                        form["client_assertion"] = unsigned + "." + Base64Url(key.SignData(Encoding.UTF8.GetBytes(unsigned), HashAlgorithmName.SHA256, RSASignaturePadding.Pss));
                    form["client_assertion_type"] = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer";
                }
                response = await HttpTransport.SendAsync(client, () => new HttpRequestMessage(HttpMethod.Post, url) {
                    Content = new FormUrlEncodedContent(form) }, options, cancellation).ConfigureAwait(false);
            }
            try
            {
                using (JsonDocument document = JsonDocument.Parse(response))
                {
                    JsonElement root = document.RootElement;
                    JsonElement value;
                    token = root.TryGetProperty("access_token", out value) ? value.GetString() : root.GetProperty("accessToken").GetString();
                    if (root.TryGetProperty("expires_on", out value)) expires = DateTimeOffset.FromUnixTimeSeconds(Int64.Parse(value.ToString(), CultureInfo.InvariantCulture));
                    else if (root.TryGetProperty("expires_in", out value)) expires = DateTimeOffset.UtcNow.AddSeconds(Double.Parse(value.ToString(), CultureInfo.InvariantCulture));
                    else expires = DateTimeOffset.Parse(root.GetProperty("expiresOn").GetString(), CultureInfo.InvariantCulture);
                    if (String.IsNullOrWhiteSpace(token) || expires <= DateTimeOffset.UtcNow) throw new FormatException();
                    return token;
                }
            }
            catch { token = null; throw new DeliveryException("Authentication returned an invalid or expired token. Renew the configured identity or CLI session."); }
        }

        private async Task<string> GetCliAsync(CancellationToken cancellation)
        {
            ProcessStartInfo info = new ProcessStartInfo { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
            string[] args = { "account", "get-access-token", "--resource", "https://monitor.azure.com", "--output", "json" };
            if (Environment.OSVersion.Platform == PlatformID.Win32NT && options.CliPath.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase))
            {
                info.FileName = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe");
                info.Arguments = "/d /s /c \"\"" + options.CliPath + "\" " + String.Join(" ", args) + (String.IsNullOrEmpty(options.TenantId) ? "" : " --tenant " + options.TenantId) + "\"";
            }
            else
            {
                info.FileName = options.CliPath;
                foreach (string argument in args) info.ArgumentList.Add(argument);
                if (!String.IsNullOrEmpty(options.TenantId)) { info.ArgumentList.Add("--tenant"); info.ArgumentList.Add(options.TenantId); }
            }
            using (Process process = new Process { StartInfo = info })
            using (CancellationTokenSource timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation))
            {
                timeout.CancelAfter(TimeSpan.FromSeconds(options.TimeoutSeconds));
                try
                {
                    process.Start();
                    Task<string> output = process.StandardOutput.ReadToEndAsync();
                    Task<string> error = process.StandardError.ReadToEndAsync();
                    while (!process.HasExited) await Task.Delay(25, timeout.Token).ConfigureAwait(false);
                    await error.ConfigureAwait(false);
                    if (process.ExitCode != 0) throw new DeliveryException("Azure CLI authentication failed. Run az login outside the logger and verify the tenant.");
                    return await output.ConfigureAwait(false);
                }
                finally { try { if (!process.HasExited) process.Kill(true); } catch (InvalidOperationException) { } }
            }
        }
        public void Dispose() { token = null; if (metadataClient != null && options.TestClient == null) metadataClient.Dispose(); }
    }
}
