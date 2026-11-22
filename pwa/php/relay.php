<?php

declare(strict_types=1);

const RELAY_LIMIT = 1048576;
const FORWARDED_HEADERS = ['accept', 'content-type', 'content-encoding', 'user-agent', 'y'];
const RESPONSE_HEADERS = ['content-type', 'content-range', 'retry-after', 'location', 'y', 'c'];
const SIGNATURE_HEADERS = [
    'x-argus', 'x-gorgon', 'x-khronos', 'x-ladon', 'x-ss-stub',
    'x-ss-req-ticket', 'x-helios', 'x-medusa',
];

function rejectRelay(int $status, string $message): never
{
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode(['error' => $message]);
    exit;
}

function matchRelayRoute(string $method, string $url, array $routes): ?array
{
    if (!in_array($method, ['GET', 'HEAD', 'POST'], true)
        || preg_match('/[\x00-\x20\x7f\\\\]/', $url)) {
        return null;
    }
    $target = parse_url($url);
    if (!$target || ($target['scheme'] ?? '') !== 'https' || !isset($target['host'])
        || isset($target['user']) || isset($target['pass']) || isset($target['fragment'])
        || ($target['port'] ?? 443) !== 443) {
        return null;
    }
    $path = $target['path'] ?? '/';
    $decodedPath = rawurldecode($path);
    if (preg_match('~(?:^|/)\.{1,2}(?:/|$)|[\x00-\x1f\x7f\\\\]~', $decodedPath)) {
        return null;
    }

    $address = 'https://' . strtolower($target['host']) . $path;
    foreach ($routes as $route) {
        if (($route['method'] ?? '') !== $method) {
            continue;
        }
        $prefix = $route['prefix'] ?? '';
        if (($route['url'] ?? '') === $address) {
            return $route;
        }
        if ($prefix === '' || !str_ends_with($prefix, '/') || !str_starts_with($address, $prefix)) {
            continue;
        }
        $suffix = $route['numeric_id_suffix'] ?? '';
        if ($suffix === '') {
            return $route;
        }
        $tail = substr($address, strlen($prefix));
        if (str_ends_with($tail, $suffix) && preg_match('/^[0-9]+$/D', substr($tail, 0, -strlen($suffix)))) {
            return $route;
        }
    }
    return null;
}

function sendUpstreamHeaders(int $status, array $headers): void
{
    http_response_code(200);
    header('Content-Type: application/octet-stream');
    header("X-Relay-Upstream-Status: $status");
    $exposed = ['X-Relay-Upstream-Status'];
    foreach ($headers as $name => $value) {
        $relayHeader = "X-Relay-Upstream-$name";
        header("$relayHeader: $value");
        $exposed[] = $relayHeader;
    }
    header('Access-Control-Expose-Headers: ' . implode(', ', $exposed));
}

header('Cache-Control: no-store');
header('X-Accel-Buffering: no');
$config = json_decode((string) file_get_contents(__DIR__ . '/relay-config.json'), true);
$routes = json_decode((string) file_get_contents(dirname(__DIR__) . '/relay-routes.json'), true);
if (!is_array($config) || !isset($config['origin']) || !is_array($routes)) {
    rejectRelay(500, 'relay configuration unavailable');
}

$origin = $_SERVER['HTTP_ORIGIN'] ?? '';
if ($origin !== '') {
    if ($origin !== $config['origin']) {
        rejectRelay(403, 'origin denied');
    }
    header("Access-Control-Allow-Origin: $origin");
    header('Access-Control-Allow-Headers: content-type');
    header('Access-Control-Allow-Methods: POST, OPTIONS');
    header('Vary: Origin');
}

$incomingMethod = $_SERVER['REQUEST_METHOD'] ?? '';
if ($incomingMethod === 'OPTIONS') {
    http_response_code(204);
    exit;
}
if ($incomingMethod !== 'POST') {
    rejectRelay(405, 'POST required');
}

$input = file_get_contents('php://input', false, null, 0, RELAY_LIMIT + 1);
if ($input === false || $input === '') {
    rejectRelay(400, 'request body required');
}
if (strlen($input) > RELAY_LIMIT) {
    rejectRelay(413, 'request too large');
}
$payload = json_decode($input, true);
if (!is_array($payload) || !is_string($payload['method'] ?? null) || !is_string($payload['url'] ?? null)) {
    rejectRelay(400, 'invalid request');
}

$method = $payload['method'];
$url = $payload['url'];
$route = matchRelayRoute($method, $url, $routes);
if ($route === null) {
    rejectRelay(403, 'target denied');
}

$requestedHeaders = $payload['headers'] ?? [];
if (!is_array($requestedHeaders)) {
    rejectRelay(400, 'invalid headers');
}
$headers = [];
$forwardedHeaders = [...FORWARDED_HEADERS, ...SIGNATURE_HEADERS, ...($route['request_headers'] ?? [])];
foreach ($requestedHeaders as $pair) {
    if (!is_array($pair) || !is_string($pair[0] ?? null) || !is_string($pair[1] ?? null)) {
        rejectRelay(400, 'invalid headers');
    }
    $name = strtolower($pair[0]);
    if (in_array($name, $forwardedHeaders, true)) {
        if (preg_match('/[\x00-\x1f\x7f]/', $pair[1])) {
            rejectRelay(400, 'invalid header value');
        }
        $headers[] = "$name: {$pair[1]}";
    }
}

$curl = curl_init($url);
$upstreamStatus = 0;
$upstreamHeaders = [];
$streamStarted = false;
ini_set('zlib.output_compression', '0');
while (ob_get_level() > 0) {
    ob_end_clean();
}

$options = [
    CURLOPT_CUSTOMREQUEST => $method,
    CURLOPT_NOBODY => $method === 'HEAD',
    CURLOPT_HTTPHEADER => $headers,
    CURLOPT_FOLLOWLOCATION => false,
    CURLOPT_PROTOCOLS => CURLPROTO_HTTPS,
    CURLOPT_CONNECTTIMEOUT => 6,
    CURLOPT_TIMEOUT => 20,
    CURLOPT_ENCODING => '',
    CURLOPT_HEADERFUNCTION => function ($handle, string $line) use (&$upstreamStatus, &$upstreamHeaders): int {
        if (preg_match('~^HTTP/\S+\s+(\d{3})\b~i', $line, $match)) {
            $upstreamStatus = (int) $match[1];
            $upstreamHeaders = [];
        } elseif (str_contains($line, ':')) {
            [$name, $value] = explode(':', rtrim($line, "\r\n"), 2);
            $name = strtolower($name);
            if (in_array($name, RESPONSE_HEADERS, true)) {
                $upstreamHeaders[$name] = trim($value);
            }
        }
        return strlen($line);
    },
    CURLOPT_WRITEFUNCTION => function ($handle, string $chunk) use (&$streamStarted, &$upstreamStatus, &$upstreamHeaders): int {
        if (!$streamStarted) {
            sendUpstreamHeaders($upstreamStatus, $upstreamHeaders);
            $streamStarted = true;
        }
        echo $chunk;
        flush();
        return strlen($chunk);
    },
];

if ($method === 'POST') {
    $body = $payload['body'] ?? '';
    if (!is_string($body) || ($decoded = base64_decode($body, true)) === false) {
        rejectRelay(400, 'invalid request body');
    }
    $options[CURLOPT_POSTFIELDS] = $decoded;
}
curl_setopt_array($curl, $options);
$success = curl_exec($curl);
if ($success === false) {
    error_log('PWA relay cURL error ' . curl_errno($curl));
    if (!$streamStarted) {
        rejectRelay(502, 'relay failed');
    }
} elseif (!$streamStarted) {
    sendUpstreamHeaders($upstreamStatus, $upstreamHeaders);
}
