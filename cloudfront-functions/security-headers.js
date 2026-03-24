/**
 * CloudFront Function: security-headers.js
 *
 * Injects HTTP security response headers at the CloudFront edge on every
 * viewer response. Running at the edge (rather than in Lambda@Edge or on
 * the origin) means:
 *   - Latency overhead is sub-millisecond (no cold start, no Lambda pricing)
 *   - Headers are added even on CloudFront-generated responses (errors, redirects)
 *   - Runtime: cloudfront-js-2.0 (ES2021 subset — no Node.js built-ins)
 *
 * Event type: viewer-response
 *
 * To test locally:
 *   const event = { response: { headers: {} } };
 *   handler(event);
 *   console.log(event.response.headers);
 */

function handler(event) {
  var response = event.response;
  var headers  = response.headers;

  // ── HTTP Strict Transport Security (HSTS) ──────────────────────────────
  // Instructs browsers to only connect over HTTPS for the next 2 years.
  // 'preload' makes the domain eligible for browser HSTS preload lists.
  // WARNING: Only set 'includeSubDomains' if ALL subdomains serve HTTPS.
  // WARNING: Set this policy and test thoroughly before enabling 'preload';
  //          it is very difficult to reverse once browsers have cached it.
  headers['strict-transport-security'] = {
    value: 'max-age=63072000; includeSubDomains; preload'
  };

  // ── X-Content-Type-Options ────────────────────────────────────────────
  // Prevents MIME-type sniffing. Stops browsers from interpreting files as
  // a different MIME type than declared (e.g. a .txt file as executable JS).
  headers['x-content-type-options'] = { value: 'nosniff' };

  // ── X-Frame-Options ───────────────────────────────────────────────────
  // Prevents the page from being embedded in an <iframe>, blocking
  // clickjacking attacks. 'DENY' is stricter than 'SAMEORIGIN'.
  // Note: CSP frame-ancestors is the modern replacement, but this header
  // is kept for legacy browser compatibility.
  headers['x-frame-options'] = { value: 'DENY' };

  // ── X-XSS-Protection ─────────────────────────────────────────────────
  // Legacy XSS filter for older browsers (IE, early Chrome/Safari).
  // Modern browsers rely on CSP instead. Kept for defence in depth.
  headers['x-xss-protection'] = { value: '1; mode=block' };

  // ── Referrer-Policy ───────────────────────────────────────────────────
  // Controls how much referrer information is sent with requests.
  // 'strict-origin-when-cross-origin': sends full URL for same-origin,
  // only the origin (no path/query) for cross-origin HTTPS requests,
  // and nothing for cross-origin HTTP requests.
  headers['referrer-policy'] = {
    value: 'strict-origin-when-cross-origin'
  };

  // ── Permissions-Policy ────────────────────────────────────────────────
  // Explicitly disables browser features this site does not use.
  // Prevents malicious scripts from accessing these APIs even if injected.
  headers['permissions-policy'] = {
    value: 'camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()'
  };

  // ── Content-Security-Policy ───────────────────────────────────────────
  // The most important header. Restricts which resources the browser
  // may load and from where.
  //
  // Directive breakdown:
  //   default-src 'self'       → fallback: only load from same origin
  //   script-src 'self'        → JS only from same origin (no inline scripts)
  //   style-src 'self' 'unsafe-inline' → CSS from same origin + inline styles
  //                              (remove 'unsafe-inline' and use nonces/hashes
  //                               if you want a stricter CSP score)
  //   img-src 'self' data:     → images from same origin + data: URIs
  //   font-src 'self'          → web fonts from same origin only
  //   connect-src 'self'       → fetch/XHR only to same origin
  //   object-src 'none'        → block Flash, Java applets, etc.
  //   base-uri 'self'          → restrict <base> tag to same origin
  //   form-action 'self'       → forms can only submit to same origin
  //   frame-ancestors 'none'   → no iframing (modern replacement for X-Frame-Options)
  //   upgrade-insecure-requests → auto-upgrade HTTP asset requests to HTTPS
  //
  // If you add a third-party library (e.g. Google Fonts, CDN), add its origin
  // to the relevant directive. Use a CSP evaluator (https://csp-evaluator.withgoogle.com)
  // to check your policy.
  headers['content-security-policy'] = {
    value: [
      "default-src 'self'",
      "script-src 'self'",
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data:",
      "font-src 'self'",
      "connect-src 'self'",
      "object-src 'none'",
      "base-uri 'self'",
      "form-action 'self'",
      "frame-ancestors 'none'",
      "upgrade-insecure-requests"
    ].join('; ')
  };

  return response;
}
