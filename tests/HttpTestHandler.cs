using System;
using System.Collections.Concurrent;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace LoggingToolsTests
{
    public sealed class Request
    {
        public string Uri;
        public string Body;
        public string Authorization;
        public string Metadata;
        public string IdentityHeader;
    }
    public sealed class Handler : HttpMessageHandler
    {
        public readonly ConcurrentQueue<Request> Requests = new ConcurrentQueue<Request>();
        public readonly ConcurrentQueue<int> Responses = new ConcurrentQueue<int>();
        public readonly ManualResetEventSlim Started = new ManualResetEventSlim(false);
        public readonly ManualResetEventSlim Release = new ManualResetEventSlim(false);
        public bool Block;
        public bool FailNetwork;
        public int DelayMilliseconds;
        public int TokenLifetime = 3600;
        public string RetryAfter = "0";
        public int TokenCalls;
        public int DeliveryCalls;
        public int MaximumCapturedRequests = Int32.MaxValue;

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation)
        {
            string body = request.Content == null ? "" : await request.Content.ReadAsStringAsync();
            Requests.Enqueue(new Request { Uri = request.RequestUri.AbsoluteUri, Body = body,
                Authorization = request.Headers.Authorization == null ? null : request.Headers.Authorization.ToString(),
                Metadata = request.Headers.Contains("Metadata") ? "true" : null,
                IdentityHeader = request.Headers.Contains("X-IDENTITY-HEADER") ? String.Join("", request.Headers.GetValues("X-IDENTITY-HEADER")) : null });
            Request discarded;
            while (Requests.Count > MaximumCapturedRequests) Requests.TryDequeue(out discarded);
            bool token = request.RequestUri.Host == "login.microsoftonline.com" || request.RequestUri.AbsolutePath.Contains("identity/oauth2/token");
            if (token)
            {
                Interlocked.Increment(ref TokenCalls);
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{\"access_token\":\"test-token\",\"expires_in\":" + TokenLifetime + "}") };
            }
            Interlocked.Increment(ref DeliveryCalls);
            Started.Set();
            while (Block && !Release.IsSet) await Task.Delay(5, cancellation);
            if (DelayMilliseconds > 0) await Task.Delay(DelayMilliseconds, cancellation);
            if (FailNetwork) throw new HttpRequestException("sensitive webhook URL and tokens must not escape");
            int status;
            if (!Responses.TryDequeue(out status)) status = 204;
            HttpResponseMessage response = new HttpResponseMessage((HttpStatusCode)status) { Content = new StringContent("private response content") };
            if (status == 429 || status >= 500) response.Headers.TryAddWithoutValidation("Retry-After", RetryAfter);
            return response;
        }
    }
}
